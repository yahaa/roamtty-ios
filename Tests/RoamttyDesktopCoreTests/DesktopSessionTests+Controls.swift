import XCTest
@testable import RoamttyDesktopCore

/// What the page asks of a running desktop, and network changes.
extension DesktopSessionTests {
    func testPauseAndResumeTellTheHost() throws {
        let host = FakeHost(probe: FakeHost.probe(), plugin: Self.goodPlugin)
        let s = session(host)
        s.start()
        wait(s, "connected", Self.connected)
        s.pause()
        XCTAssertEqual(s.phase, .connected(poor: false, paused: true))
        s.resume()
        XCTAssertEqual(s.phase, .connected(poor: false, paused: false))
        let stream = try XCTUnwrap(host.allStreams.first)
        XCTAssertTrue(waitUntil(2) {
            let reqs = stream.received.filter { $0.type == DesktopProtocol.REQ }.map { Int($0.payload[0]) }
            return reqs.contains(DesktopProtocol.REQ_PAUSE) && reqs.contains(DesktopProtocol.REQ_RESUME)
        })
        s.setQuality("clear"); s.setFps(30); s.setLockOnClose(true); s.setDisplay(0)
        XCTAssertEqual(s.quality, "clear"); XCTAssertEqual(s.fps, 30); XCTAssertTrue(s.lockOnClose)
    }

    /// The small window alone: the host is asked for at most 15 fps and 1.5 Mbit/s; the page (or the user's lower
    /// rate) lifts it again. Not shown twice: the same state sends nothing.
    func testMiniCapsTheStream() throws {
        let host = FakeHost(probe: FakeHost.probe(), plugin: Self.goodPlugin)
        let s = session(host)
        s.start()
        wait(s, "connected", Self.connected)
        let stream = try XCTUnwrap(host.allStreams.first)
        func configs() -> [[String: Any]] {
            stream.received.filter { $0.type == DesktopProtocol.CONFIG }
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.payload)) as? [String: Any] }
        }
        _ = try firstConfiguration(on: stream)
        let before = configs().count
        s.setMini(true); s.setMini(true)
        XCTAssertTrue(waitUntil(2) { configs().count == before + 1 })
        XCTAssertEqual(configs().last?["fps"] as? Int, DesktopSession.miniFps)
        XCTAssertEqual(configs().last?["max_bitrate"] as? Int, DesktopSession.miniMaxBitrate)
        s.setFps(30)
        XCTAssertTrue(waitUntil(2) { configs().count == before + 2 })
        XCTAssertEqual(configs().last?["fps"] as? Int, DesktopSession.miniFps, "still capped")
        s.setMini(false)
        XCTAssertTrue(waitUntil(2) { configs().count == before + 3 })
        XCTAssertEqual(configs().last?["fps"] as? Int, 30)
        XCTAssertEqual(configs().last?["max_bitrate"] as? Int, DesktopSession.uncappedBitrate)
    }

    /// 声音: asked for in the first CONFIG when the host offers Opus; packets reach the player only while the
    /// page is shown and sound is on; switching it off tells the host; STATE `unavailable` says the host has none.
    func testAudioFollowsTheSwitchAndThePage() throws {
        let gate = Box(false)
        let host = FakeHost(probe: FakeHost.probe(), plugin: { s, _ in
            s.hello(PluginFrames.hello(audio: ["opus"]))
            s.feed(PluginFrames.video(1))
            var seq: Int64 = 0
            for _ in 0..<200 {
                Thread.sleep(forTimeInterval: 0.02)
                seq += 1
                s.feed(PluginFrames.audio(seq))
                if gate.value { s.feed(PluginFrames.state(["audio": "unavailable", "detail": "no server"])); gate.value = false }
            }
        })
        let s = session(host)
        let sound = RecordingAudio()
        s.audio = sound
        let available = Box<Bool?>(nil)
        s.onAudioAvailable = { available.value = $0 }
        s.start()
        wait(s, "connected", Self.connected)
        let stream = try XCTUnwrap(host.allStreams.first)
        let first = try firstConfiguration(on: stream)
        XCTAssertEqual(first["audio"] as? Bool, true)
        XCTAssertTrue(waitUntil(2) { available.value == true })
        XCTAssertTrue(waitUntil(2) { sound.packets >= 5 })
        XCTAssertTrue(waitUntil(2) { s.stats.audioMs == 40 })

        // Paused: nothing reaches the player.
        s.pause()
        let stops = sound.stopped
        XCTAssertGreaterThan(stops, 0)
        let paused = sound.packets
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(sound.packets, paused)
        s.resume()
        XCTAssertTrue(waitUntil(2) { sound.packets > paused })

        // Off: the host is told, the player stops and hears nothing more.
        s.setAudio(false)
        XCTAssertFalse(s.audioOn)
        XCTAssertTrue(waitUntil(2) { stream.received.contains { $0.type == DesktopProtocol.CONFIG && String(decoding: $0.payload, as: UTF8.self) == #"{"audio":false}"# } })
        let off = sound.packets
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(sound.packets, off)
        s.setAudio(true)
        XCTAssertTrue(waitUntil(2) { sound.packets > off })

        // The host has no sound after all.
        gate.value = true
        XCTAssertTrue(waitUntil(2) { available.value == false && s.audioAvailable == false })
        XCTAssertTrue(waitUntil(2) { s.log.contains { $0.contains("host audio unavailable") } })
    }

    /// A plugin before 0.9.0 offers no sound: the first CONFIG does not ask for it.
    func testOlderPluginsAreNotAskedForSound() throws {
        let host = FakeHost(probe: FakeHost.probe(), plugin: Self.goodPlugin)
        let s = session(host)
        let available = Box<Bool?>(nil)
        s.onAudioAvailable = { available.value = $0 }
        s.start()
        wait(s, "connected", Self.connected)
        let first = try firstConfiguration(on: XCTUnwrap(host.allStreams.first))
        XCTAssertNil(first["audio"])
        XCTAssertTrue(waitUntil(2) { available.value == false })
    }

    /// The first CONFIG is written asynchronously after the session becomes connected.
    private func firstConfiguration(on stream: FakeStream) throws -> [String: Any] {
        XCTAssertTrue(waitUntil(2) { !stream.received.isEmpty })
        let first = try XCTUnwrap(stream.received.first)
        XCTAssertEqual(first.type, DesktopProtocol.CONFIG)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.payload)) as? [String: Any])
    }

    /// The first report is the network in use; the same interface again is only a path update.
    func testNetworkChangeBetweenReports() {
        XCTAssertNil(NetworkChange.between(nil, "wifi:en0"))
        XCTAssertNil(NetworkChange.between(nil, nil))
        XCTAssertEqual(NetworkChange.between(.some("cellular:pdp_ip0"), "cellular:pdp_ip0"), .pathUpdate)
        XCTAssertEqual(NetworkChange.between(.some("cellular:pdp_ip0"), "wifi:en0"), .newInterface)
        XCTAssertEqual(NetworkChange.between(.some(nil), "wifi:en0"), .newInterface, "a network again after none")
        XCTAssertEqual(NetworkChange.between(.some("wifi:en0"), nil), .newInterface)
    }

    /// Path updates of the same network (iOS sends them every few seconds on mobile data with a VPN) keep a
    /// UDP socket that works; one that has gone quiet gets a new socket; SSH alone is left to its pings.
    func testPathUpdatesKeepAWorkingUdpSocket() throws {
        let key = [UInt8](repeating: 9, count: 16)
        let udp = UdpHostStandIn(key: key)
        let host = FakeHost(probe: FakeHost.probe(), plugin: { s, _ in
            s.hello(PluginFrames.hello(udp: (60123, key)))
            s.feed(PluginFrames.video(1))
        })
        let s = session(host, udp: udp)
        s.start()
        wait(s, "connected", Self.connected)
        XCTAssertTrue(waitUntil(3) { s.onUdp }, "heartbeats answered")
        for _ in 0..<3 { s.networkChanged(.pathUpdate); Thread.sleep(forTimeInterval: 0.3) }
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(udp.rebinds, 0, "a working socket was replaced")
        XCTAssertEqual(host.allStreams.count, 1)

        // The same interface but the socket no longer reaches the host (another Wi-Fi on en0).
        udp.blocked = true
        let at = Date()
        s.networkChanged(.pathUpdate)
        XCTAssertTrue(waitUntil(3) { udp.rebinds == 1 }, "a quiet socket was kept")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(at), 1.4)
        XCTAssertEqual(host.allStreams.count, 1, "UDP's trouble left SSH alone")

        // A new interface still rebinds at once.
        udp.blocked = false
        XCTAssertTrue(waitUntil(3) { s.onUdp })
        s.networkChanged(.newInterface)
        XCTAssertEqual(udp.rebinds, 2)
    }

    func testPathUpdateOnSshKeepsTheLink() {
        let host = FakeHost(probe: FakeHost.probe(), plugin: { s, n in Self.goodPlugin(s, n) })
        let s = session(host)
        s.start()
        wait(s, "connected", Self.connected)
        s.networkChanged(.pathUpdate)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(host.allStreams.count, 1)
        XCTAssertEqual(host.disconnects, 0)
        XCTAssertTrue(Self.connected(s.phase))
    }

    /// A network change without UDP drops the SSH link; the loop gets it back with the token.
    func testNetworkChangeOnSshReconnects() {
        let host = FakeHost(probe: FakeHost.probe(), plugin: { s, n in Self.goodPlugin(s, n) })
        let s = session(host)
        s.start()
        wait(s, "connected", Self.connected)
        s.networkChanged()
        XCTAssertTrue(waitUntil(5) { host.allStreams.count == 2 })
        XCTAssertTrue(host.disconnects >= 1)
        wait(s, "connected again", Self.connected)
    }

    func testServeCommandSizes() {
        let host = FakeHost(probe: FakeHost.probe(), plugin: Self.goodPlugin)
        XCTAssertEqual(session(host).serveCommand(), #""$HOME/.roamtty/bin/roamtty-desktop" serve --proto 1 --client 2400x1080@420"#)
    }
}
