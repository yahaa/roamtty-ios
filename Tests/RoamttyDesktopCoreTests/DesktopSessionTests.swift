import XCTest
@testable import RoamttyDesktopCore

/// Android `DesktopConnection`'s flow, against a scripted host: probe, install, serve and its start
/// errors, permissions, the stream, UDP and its SSH fallback, resume and the 30 s limit, take-over.
final class DesktopSessionTests: XCTestCase {
    var manifest: PluginManifest!
    var phases: [DesktopPhase] = []
    let phaseLock = NSLock()

    override func setUpWithError() throws { manifest = try PluginManifest.bundled() }

    func fast(recoverLimitMs: Int64 = 30_000) -> DesktopSession.Timings {
        var t = DesktopSession.Timings()
        t.recoverLimitMs = recoverLimitMs; t.recoverRetryMs = 50; t.needsRetryMs = 50; t.nologinRetryMs = 50
        t.notLoggedInRetryMs = 50; t.tickMs = 50; t.exitWaitMs = 300
        return t
    }

    func session(_ host: FakeHost?, logins: (() -> DesktopLogin)? = nil, timings: DesktopSession.Timings? = nil,
                 english: Bool = false, udp: UdpHostStandIn? = nil, decoder: InstantDecoder = InstantDecoder()) -> DesktopSession {
        var config = DesktopSession.Config(hostName: "box", address: "127.0.0.1", clientWidth: 1080, clientHeight: 2400, clientDpi: 420)
        config.english = english
        let s = DesktopSession(config: config, manifest: manifest, timings: timings ?? fast(),
                               login: logins ?? { .host(host!) },
                               fetch: { _ in throw URLError(.notConnectedToInternet) },
                               makeUdp: { _, _ in guard let udp else { throw URLError(.cannotConnectToHost) }; return udp })
        decoder.session = s
        s.video = decoder
        s.onPhase = { [weak self] p in self?.phaseLock.lock(); self?.phases.append(p); self?.phaseLock.unlock() }
        addTeardownBlock { s.close() }
        return s
    }

    var seen: [DesktopPhase] { phaseLock.lock(); defer { phaseLock.unlock() }; return phases }

    func wait(_ s: DesktopSession, _ what: String, seconds: Double = 5, _ cond: (DesktopPhase) -> Bool) {
        XCTAssertTrue(waitUntil(seconds) { cond(s.phase) }, "\(what): phase is \(s.phase), log \(s.log)")
    }

    static func connected(_ p: DesktopPhase) -> Bool { if case .connected = p { return true }; return false }
    static func failed(_ p: DesktopPhase) -> String? { if case .failed(let m) = p { return m }; return nil }

    /// A plugin that says hello and sends one keyframe.
    static func goodPlugin(_ s: FakeStream, _ n: Int) {
        s.hello(PluginFrames.hello())
        s.feed(PluginFrames.video(1))
    }

    func testCurrentPluginStreamsAndAcknowledgesFrames() throws {
        let host = FakeHost(probe: FakeHost.probe(), plugin: Self.goodPlugin)
        let decoder = InstantDecoder()
        let s = session(host, decoder: decoder)
        s.start()
        wait(s, "connected", Self.connected)
        XCTAssertEqual(host.allStreams.first?.command, #""$HOME/.roamtty/bin/roamtty-desktop" serve --proto 1 --client 2400x1080@420"#)
        XCTAssertFalse(host.allScripts.contains { $0.contains("mkdir -p") }, "a current plugin is not reinstalled")
        XCTAssertEqual(decoder.all, [1])
        let stream = try XCTUnwrap(host.allStreams.first)
        XCTAssertTrue(waitUntil(2) { stream.received.contains { $0.type == DesktopProtocol.ACK } })
        let config = try XCTUnwrap(stream.received.first)
        XCTAssertEqual(config.type, DesktopProtocol.CONFIG)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.payload)) as? [String: Any])
        XCTAssertEqual(json["display"] as? Int, 0); XCTAssertEqual(json["fps"] as? Int, 60)
        XCTAssertEqual(json["quality"] as? String, "auto"); XCTAssertEqual(json["lock_on_close"] as? Bool, false)
        // Pings go out every tick until answered.
        XCTAssertTrue(waitUntil(2) { stream.received.contains { $0.type == DesktopProtocol.PING } })
        XCTAssertEqual(seen.first, .connecting(step: .login))
        XCTAssertTrue(seen.contains(.connecting(step: .start)) && seen.contains(.connecting(step: .firstFrame)))
        XCTAssertEqual(s.stats.encoder, "openh264")
        XCTAssertEqual(s.hello?.session, "s1")
        // Page input goes over SSH while there is no UDP.
        s.input(DesktopProtocol.key(4, down: true))
        XCTAssertTrue(waitUntil(2) { stream.received.contains { $0.type == DesktopProtocol.INPUT } })
        s.setViewOnly(true)
        s.input(DesktopProtocol.key(5, down: true))
        XCTAssertEqual(s.inputsDropped, 1)
        s.close()
        wait(s, "idle") { $0 == .idle }
        XCTAssertTrue(stream.wasClosed)
    }

    func testStalePluginIsInstalledFirst() {
        let host = FakeHost(probe: FakeHost.probe(version: "0.7.0"), plugin: Self.goodPlugin)
        let s = session(host)
        s.start()
        wait(s, "connected", Self.connected)
        XCTAssertTrue(seen.contains(.connecting(step: .install)))
        XCTAssertTrue(host.allScripts.contains { $0.contains(#"mkdir -p "$HOME/.roamtty/bin" "$HOME/.roamtty/desktop""#) })
        XCTAssertTrue(host.allScripts.contains { $0.contains("roamtty-desktop/releases/download/v0.9.8/linux-x86_64.gz") })
        XCTAssertTrue(host.allScripts.contains { $0.contains(#""$HOME/.roamtty/bin/roamtty-desktop" install"#) }, "OpenH264")
        XCTAssertEqual(Array(s.log.prefix(4)), ["安装桌面插件 0.9.8（linux-x86_64）", "主机直接下载…", "获取 Cisco OpenH264 编码器…", "注册插件…"])
    }

    func testMissingBinaryExit127Installs() {
        let host = FakeHost(probe: FakeHost.probe(), plugin: { s, n in
            if n == 1 { s.exit(127, stderr: "sh: roamtty-desktop: not found") } else { Self.goodPlugin(s, n) }
        })
        let s = session(host)
        s.start()
        wait(s, "connected", Self.connected)
        XCTAssertEqual(host.allStreams.count, 2)
        XCTAssertTrue(s.log.contains("sh: roamtty-desktop: not found"))
        XCTAssertTrue(s.log.contains("安装桌面插件 0.9.8（linux-x86_64）"))
    }

    func testOtherExitStatusFails() {
        let host = FakeHost(probe: FakeHost.probe(), plugin: { s, _ in s.exit(1) })
        let s = session(host)
        s.start()
        wait(s, "failed") { Self.failed($0) != nil }
        XCTAssertEqual(Self.failed(s.phase), "桌面插件启动失败（退出码 1）")
        XCTAssertEqual(s.failure, .pluginStartFailedCode(1))
    }

    func testStartErrors() {
        for (code, expected) in [("no_desktop", "这台主机没有图形桌面"), ("weird", "桌面插件出错：boom")] {
            let host = FakeHost(probe: FakeHost.probe(), plugin: { s, _ in
                s.feed(Array(#"{"error":"\#(code)","detail":"boom"}"#.utf8) + [0x0A]); s.exit(1)
            })
            let s = session(host)
            s.start()
            wait(s, code) { Self.failed($0) != nil }
            XCTAssertEqual(Self.failed(s.phase), code == "no_desktop" ? expected : "桌面插件出错：boom")
        }
    }

    func testEncoderFailureReinstallsThenGivesUpAfterThreeTries() {
        let host = FakeHost(probe: FakeHost.probe(), plugin: { s, _ in s.feed(Array(#"{"error":"encoder_failed"}"#.utf8) + [0x0A]) })
        let s = session(host)
        s.start()
        wait(s, "failed") { Self.failed($0) != nil }
        XCTAssertEqual(Self.failed(s.phase), "桌面插件启动失败")
        XCTAssertEqual(host.allStreams.count, 3)
        XCTAssertEqual(host.allScripts.filter { $0.contains("mkdir -p") }.count, 3, "a forced install each time")
    }

    func testProbeAnswers() {
        let cases: [(String, String)] = [
            (FakeHost.probe("no"), "这台主机没有图形桌面"),
            (FakeHost.probe(uname: "SunOS sparc"), "暂不支持这台主机的系统"),
            ("garbage", "无法检测这台主机的桌面")
        ]
        for (probe, expected) in cases {
            let host = FakeHost(probe: probe, plugin: Self.goodPlugin)
            let s = session(host)
            s.start()
            wait(s, expected) { Self.failed($0) != nil }
            XCTAssertEqual(Self.failed(s.phase), expected)
        }
        let host = FakeHost(probe: FakeHost.probe("no"), plugin: Self.goodPlugin)
        let s = session(host, english: true)
        s.start()
        wait(s, "english") { Self.failed($0) != nil }
        XCTAssertEqual(Self.failed(s.phase), "This host has no graphical desktop")
    }

    func testNobodyLoggedInWaitsThenConnects() {
        let host = FakeHost(probe: FakeHost.probe("nologin"), plugin: Self.goodPlugin)
        host.probes = [FakeHost.probe("nologin"), FakeHost.probe("nologin"), FakeHost.probe("yes")]
        let s = session(host)
        s.start()
        wait(s, "connected", Self.connected)
        XCTAssertTrue(seen.contains(.needsAction(needs: ["not-logged-in"])))
    }

    func testProbeReportsDesktopRemovalAndReturnOnExplicitRetry() {
        let host = FakeHost(probe: FakeHost.probe("no"), plugin: Self.goodPlugin)
        let s = session(host)
        let ended = expectation(description: "No desktop ends the first attempt")
        let probed = expectation(description: "Both capability changes are reported")
        probed.expectedFulfillmentCount = 2
        let lock = NSLock()
        var desktopStates: [String] = []
        s.onProbe = { result in
            lock.lock(); desktopStates.append(result.desktop); lock.unlock()
            probed.fulfill()
        }
        s.onEnded = { _ in ended.fulfill() }
        s.start()
        wait(for: [ended], timeout: 5)
        XCTAssertEqual(s.failure, .noDesktop)
        XCTAssertTrue(host.allStreams.isEmpty)
        s.onEnded = nil
        host.probes = [FakeHost.probe("yes")]
        s.start()
        wait(s, "connected after retry", Self.connected)
        wait(for: [probed], timeout: 5)
        lock.lock(); let reported = desktopStates; lock.unlock()
        XCTAssertEqual(reported, ["no", "yes"])
    }

    /// macOS permissions: the hello's needs show the guide, and serve is asked again until they are granted.
    func testMacPermissionsArePolledUntilGranted() {
        let host = FakeHost(probe: FakeHost.probe(uname: "Darwin arm64"), plugin: { s, n in
            if n < 3 { s.hello(PluginFrames.hello(needs: n == 1 ? ["screen-recording", "accessibility"] : ["accessibility"])) } else { Self.goodPlugin(s, n) }
        })
        let s = session(host)
        s.start()
        wait(s, "connected", Self.connected)
        XCTAssertTrue(seen.contains(.needsAction(needs: ["screen-recording", "accessibility"])))
        XCTAssertTrue(seen.contains(.needsAction(needs: ["accessibility"])))
        XCTAssertEqual(host.allStreams.count, 3)
        XCTAssertTrue(host.allStreams.prefix(2).allSatisfy { $0.wasClosed })
    }

    /// macOS: someone is at the console but the agent is gone: reload it once.
    func testMacAgentIsReloadedOnce() {
        let host = FakeHost(probe: FakeHost.probe(uname: "Darwin arm64"), plugin: { s, n in
            if n == 1 { s.feed(Array(#"{"error":"not_logged_in"}"#.utf8) + [0x0A]) } else { Self.goodPlugin(s, n) }
        })
        let s = session(host)
        s.start()
        wait(s, "connected", Self.connected)
        XCTAssertTrue(s.log.contains("重新启动桌面代理…"))
        XCTAssertEqual(host.allScripts.filter { $0.contains(#""$HOME/.roamtty/bin/roamtty-desktop" install"#) }.count, 1)
    }

    /// Windows: serve goes through cmd; nobody signed in → one forced install (sets the service up), then the hint.
    func testWindowsNotLoggedInTriesTheServiceOnceThenShowsTheHint() {
        let host = FakeHost(probe: FakeHost.probe(uname: "Windows AMD64"), plugin: { s, _ in
            s.feed(Array(#"{"error":"not_logged_in"}"#.utf8) + [0x0A])
        })
        // The POSIX probe gets no answer from cmd.exe; the PowerShell one does.
        let windows = WindowsAnsweringHost(host, probe: FakeHost.probe(uname: "Windows AMD64"))
        let s2 = session(nil, logins: { .host(windows) })
        s2.start()
        wait(s2, "needs") { $0 == .needsAction(needs: ["not-logged-in"]) }
        XCTAssertTrue(s2.windowsHost)
        XCTAssertTrue(DesktopText.showsWindowsServiceHint(windowsHost: s2.windowsHost, needs: ["not-logged-in"]))
        XCTAssertTrue(host.allStreams.first?.command.hasPrefix(#"cmd /c ""%USERPROFILE%\.roamtty\bin\roamtty-desktop.exe" serve --proto 1"#) == true)
        let installs = windows.decoded.filter { $0.hasPrefix(#"& "$env:USERPROFILE\.roamtty\bin\roamtty-desktop.exe" install"#) }
        XCTAssertEqual(installs.count, 1, "the service install is tried once")
    }

    func testKickedIsFinal() {
        let host = FakeHost(probe: FakeHost.probe(), plugin: { s, _ in
            Self.goodPlugin(s, 1)
            Thread.sleep(forTimeInterval: 0.3)
            s.feed(PluginFrames.state(["kicked": true]))
        })
        let s = session(host)
        s.start()
        wait(s, "kicked") { Self.failed($0) != nil }
        XCTAssertEqual(Self.failed(s.phase), "已在另一台设备上打开")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(host.allStreams.count, 1, "no resume after a take-over")
    }
}

/// A Windows host: `sh -s` does not exist; PowerShell answers the probe, the rest succeeds.
final class WindowsAnsweringHost: DesktopHost, @unchecked Sendable {
    let base: FakeHost
    let probe: String
    private let lock = NSLock()
    private var commands: [String] = []
    init(_ base: FakeHost, probe: String) { self.base = base; self.probe = probe }
    var decoded: [String] {
        lock.lock(); defer { lock.unlock() }
        return commands.compactMap { c -> String? in
            guard let b64 = c.components(separatedBy: "-EncodedCommand ").last, let d = Data(base64Encoded: b64) else { return nil }
            let bytes = [UInt8](d)
            return String(decoding: stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }, as: UTF16.self)
        }
    }
    func run(_ script: String, timeout: TimeInterval, onLine: @escaping (String) -> Void) -> Int? { onLine("'/bin/sh' is not recognized"); return 1 }
    func runCommand(_ command: String, timeout: TimeInterval, onLine: @escaping (String) -> Void) -> Int? {
        lock.lock(); commands.append(command); lock.unlock()
        if command == WindowsDesktop.probeCommand { probe.split(separator: "\n").forEach { onLine(String($0)) } }
        return 0
    }
    func upload(_ data: Data, to path: String) throws {}
    func openStream(_ command: String) -> DesktopStream? { base.openStream(command) }
    func disconnect() {}
}
