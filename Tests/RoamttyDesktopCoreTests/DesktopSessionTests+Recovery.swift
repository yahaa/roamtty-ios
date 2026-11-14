import XCTest
@testable import RoamttyDesktopCore

/// State messages, drops, logins and the UDP link.
extension DesktopSessionTests {
    func testStateMessages() {
        let clip = Box<String?>(nil), notice = Box<String?>("unset")
        let host = FakeHost(probe: FakeHost.probe(), plugin: { s, _ in
            Self.goodPlugin(s, 1)
            Thread.sleep(forTimeInterval: 0.2)
            s.feed(PluginFrames.state(["clip": "from host", "locked": true, "error": "capture hiccup"]))
        })
        let s = session(host)
        s.onRemoteClipboard = { clip.value = $0 }
        s.onNotice = { notice.value = $0 }
        s.start()
        XCTAssertTrue(waitUntil(5) { clip.value == "from host" && notice.value == "请在本机解锁" })
        XCTAssertTrue(waitUntil(2) { s.log.contains("capture hiccup") })
    }

    /// The stream drops after the first frame: recovering, then serve again with the resume token.
    func testDropResumesWithTheToken() {
        let host = FakeHost(probe: FakeHost.probe(), plugin: { s, n in
            s.hello(PluginFrames.hello(session: "abc", token: "T0k+/=\"; rm -rf ~"))
            s.feed(PluginFrames.video(Int64(n)))
            if n == 1 { Thread.sleep(forTimeInterval: 0.3); s.exit(nil) }
        })
        let s = session(host)
        s.start()
        XCTAssertTrue(waitUntil(5) { host.allStreams.count == 2 })
        wait(s, "connected again", Self.connected)
        XCTAssertTrue(seen.contains { if case .recovering = $0 { return true }; return false })
        XCTAssertEqual(host.allStreams[1].command,
                       #""$HOME/.roamtty/bin/roamtty-desktop" serve --proto 1 --client 2400x1080@420 --resume abc --token T0k+/=rmrf"#)
    }

    /// A login that cannot get back in: recovering for the limit (30 s in the app), then failed.
    func testRecoveryGivesUpAfterTheLimit() {
        let up = Box(true)
        let host = FakeHost(probe: FakeHost.probe(), plugin: { s, _ in
            Self.goodPlugin(s, 1)
            Thread.sleep(forTimeInterval: 0.2)
            up.value = false
            s.exit(nil)
        })
        let s = session(nil, logins: { up.value ? .host(host) : .failed(message: "Network is unreachable", connecting: true) },
                       timings: fast(recoverLimitMs: 600))
        s.start()
        wait(s, "failed") { Self.failed($0) != nil }
        XCTAssertEqual(Self.failed(s.phase), "连接中断超过 30 秒，桌面已断开")
        XCTAssertTrue(seen.contains { if case .recovering = $0 { return true }; return false })
    }

    func testLoginFailures() {
        let a = session(nil, logins: { .noCredentials })
        a.start()
        wait(a, "credentials") { Self.failed($0) != nil }
        XCTAssertEqual(Self.failed(a.phase), "无法读取凭据，请重新导入密钥或保存密码。")
        let b = session(nil, logins: { .failed(message: nil, connecting: false) })
        b.start()
        wait(b, "server") { Self.failed($0) != nil }
        XCTAssertEqual(Self.failed(b.phase), "无法连接服务器")
        let c = session(nil, logins: { .failed(message: nil, connecting: true) })
        c.start()
        wait(c, "never connected") { Self.failed($0) != nil }
        XCTAssertEqual(Self.failed(c.phase), "无法连接桌面")
    }

    /// UDP: frames go over it while it is alive; 3 s of silence fall back to SSH; it comes back; an SSH
    /// channel that closes while UDP is alive does not end the desktop.
    func testUdpUpgradeFallbackAndBack() throws {
        let key = [UInt8](repeating: 9, count: 16)
        let udp = UdpHostStandIn(key: key)
        let host = FakeHost(probe: FakeHost.probe(), plugin: { s, _ in
            s.hello(PluginFrames.hello(udp: (60123, key)))
            s.feed(PluginFrames.video(1))
        })
        let s = session(host, udp: udp)
        s.start()
        wait(s, "connected", Self.connected)
        let stream = try XCTUnwrap(host.allStreams.first)
        // The phone told the host its UDP port over SSH.
        XCTAssertTrue(waitUntil(2) { stream.received.contains { f in
            f.type == DesktopProtocol.CONFIG && String(decoding: f.payload, as: UTF8.self).contains("\"udp_client_port\":40000")
        }
        })
        XCTAssertTrue(waitUntil(3) { s.onUdp }, "heartbeats answered")
        udp.video(PluginFrames.video(2))
        XCTAssertTrue(waitUntil(3) { s.stats.link == "UDP" })
        s.input(DesktopProtocol.key(30, down: true))
        XCTAssertTrue(waitUntil(3) { udp.frames.contains { $0.type == DesktopProtocol.INPUT } }, "input over UDP while alive")
        XCTAssertFalse(stream.received.contains { $0.type == DesktopProtocol.INPUT })

        // UDP blocked: after 3 s without a datagram the link is not alive and frames go over SSH.
        udp.blocked = true
        let blockedAt = Date()
        XCTAssertTrue(waitUntil(5) { !s.onUdp })
        let fallback = Date().timeIntervalSince(blockedAt)
        XCTAssertGreaterThan(fallback, 2.7); XCTAssertLessThan(fallback, 3.6)
        s.input(DesktopProtocol.key(31, down: true))
        XCTAssertTrue(waitUntil(2) { stream.received.contains { $0.type == DesktopProtocol.INPUT } }, "input over SSH after the fallback")
        XCTAssertTrue(waitUntil(2) { s.stats.link == "SSH" })
        stream.feed(PluginFrames.video(3, key: true))
        XCTAssertTrue(Self.connected(s.phase))

        // Unblocked: back on UDP.
        udp.blocked = false
        XCTAssertTrue(waitUntil(3) { s.onUdp })
        // A new network while on UDP: a new socket, no reconnect.
        s.networkChanged()
        XCTAssertEqual(udp.rebinds, 1)
        XCTAssertEqual(host.allStreams.count, 1)

        // The SSH channel ends; UDP still carries the desktop.
        stream.exit(nil)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(Self.connected(s.phase), "\(s.phase)")
        XCTAssertEqual(host.allStreams.count, 1, "no resume while UDP is alive")
        udp.video(PluginFrames.video(4))
        XCTAssertTrue(waitUntil(2) { s.stats.frames >= 3 })
        // Then UDP falls silent too: the loop resumes over SSH.
        udp.blocked = true
        XCTAssertTrue(waitUntil(6) { host.allStreams.count == 2 })
        XCTAssertTrue(host.allStreams[1].command.contains("--resume s1 --token tok+/="))
    }
}
