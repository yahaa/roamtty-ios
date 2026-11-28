import Foundation
import XCTest
@testable import RoamttyDesktopCore

extension VoiceSessionTests {
    func testCodexBackendResolvesThreadSkipsMicPortInjectionAndAcceptsZeroMicPort() throws {
        let audio = FakeVoiceAudioIO()
        let injected = Box<Bool>(false)
        let cleared = Box<Bool>(false)
        let streamBox = Box<FakeStream?>(nil)
        let host = FakeHost(probe: FakeHost.probe("no", uname: "Darwin arm64", version: "0.9.7")) { s, _ in
            streamBox.value = s
            s.hello([
                "proto": 1, "ver": "0.9.7", "os": "macos", "mode": "voice",
                "mic_port": 0, "session": "vs-codex", "resume_token": "tok-codex", "codecs": ["opus", "pcm16"]
            ])
        }
        host.scriptLines = { script in
            script.contains("@roamtty_session") ? ["%3|019a1234-6789-7abc-8def-0123456789ab|019a1234-6789-7abc-8def-0123456789ab|/Users/v/work/app"] : []
        }
        let session = VoiceSession(
            config: .init(hostName: "mac", address: "127.0.0.1", tmuxSession: "roamtty-c", backend: .codex),
            manifest: manifest,
            timings: fastTimings,
            login: { .host(host) },
            readCodexStatus: { "019a1234-6789-7abc-8def-0123456789ab" },
            injectMicPort: { _, _, _ in injected.value = true },
            clearMicPort: { _, _ in cleared.value = true }
        )
        session.audioIO = audio
        session.start()

        XCTAssertTrue(waitUntil(2) { session.hello != nil })
        XCTAssertFalse({ if case .ready = session.phase { return true }; return false }(), "hello alone does not establish audio")
        let stream = try XCTUnwrap(streamBox.value)
        stream.feed(DesktopProtocol.frame(VoiceProtocol.MIC_START, [1, 0, 0, 0, 0x80, 0x3e, 0, 0, 1]))
        XCTAssertTrue(waitUntil(3) { if case .ready(0, _) = session.phase { return true }; return false })
        XCTAssertTrue(stream.command.contains("--backend codex"), stream.command)
        XCTAssertTrue(stream.command.contains("--codex-thread 019a1234-6789-7abc-8def-0123456789ab"), stream.command)
        XCTAssertTrue(stream.command.contains("--codex-cwd '/Users/v/work/app'"), stream.command)
        XCTAssertFalse(stream.command.contains("--port"), stream.command)
        XCTAssertNil(session.micPort)
        XCTAssertFalse(injected.value, "codex backend must never inject ANTIGRAVITY_MIC")

        session.close()
        XCTAssertTrue(waitUntil(2) {
            stream.received.contains { f in
                guard f.type == DesktopProtocol.CONFIG else { return false }
                let text = String(decoding: f.payload, as: UTF8.self)
                return text.contains("\"shutdown\"") && text.contains("true")
            }
        })
        Thread.sleep(forTimeInterval: 0.08)
        XCTAssertFalse(cleared.value, "codex backend must never clear ANTIGRAVITY_MIC")
    }

    func testCodexRefusesUnboundPaneEvenIfDirectoryIsKnown() {
        let host = FakeHost(probe: FakeHost.probe("no", version: "0.9.7")) { _, _ in }
        host.scriptLines = { _ in ["%3|019a1234-6789-7abc-8def-0123456789ab|019b1234-6789-7abc-8def-0123456789ab|/tmp/project"] }
        let session = VoiceSession(config: .init(hostName: "h", address: "localhost", tmuxSession: "work", backend: .codex),
                                   manifest: manifest, timings: fastTimings, login: { .host(host) })
        defer { session.close() }
        session.start()
        XCTAssertTrue(waitUntil(1) { if case .failed = session.phase { return true }; return false })
        XCTAssertTrue(host.allStreams.isEmpty)
    }

    func testLivePaneIdentityResolvesWithoutWaitingForOrTypingStatus() {
        let active = "019a1234-6789-7abc-8def-0123456789ab"
        let stale = "019e1234-6789-7abc-8def-0123456789ab"
        let host = FakeHost(probe: FakeHost.probe()) { _, _ in }
        host.scriptLines = { script in
            script.contains("codex current '%3' </dev/null") ? [active] : ["%3|\(stale)|\(stale)|/project"]
        }
        let session = VoiceSession(config: .init(hostName: "h", address: "host", tmuxSession: "work", backend: .codex),
                                   manifest: manifest, login: { .host(host) }, readCodexStatus: {
                                       XCTFail("A verified current TUI thread does not need manual input"); return nil
                                   })
        defer { session.close() }
        XCTAssertEqual(session.resolveCodexTarget(host)?.thread, active)
    }

    func testMissingOrAmbiguousLiveIdentityAndManualTimeoutCannotUseStaleMarkers() {
        let id = "019a1234-6789-7abc-8def-0123456789ab"
        for (code, output) in [(1, [id]), (0, [id, id]), (0, ["invalid"])] {
            let host = FakeHost(probe: FakeHost.probe()) { _, _ in }
            host.scriptLines = { $0.contains("codex current") ? output : ["%3|\(id)|\(id)|/project"] }
            host.scriptStatus = { $0.contains("codex current") ? code : 0 }
            let session = VoiceSession(config: .init(hostName: "h", address: "host", tmuxSession: "work", backend: .codex),
                                       manifest: manifest, login: { .host(host) }, readCodexStatus: { nil })
            XCTAssertNil(session.resolveCodexTarget(host))
            XCTAssertFalse(host.scripts.contains { $0.contains("codex bind") })
            session.close()
        }
    }

    func testCancelledDirectStatusCannotReturnAThread() {
        let id = "019a1234-6789-7abc-8def-0123456789ab"
        let host = FakeHost(probe: FakeHost.probe()) { _, _ in }
        var session: VoiceSession!
        session = VoiceSession(config: .init(hostName: "h", address: "host", backend: .codex),
                               manifest: manifest, login: { .host(host) }, readCodexStatus: { session.close(); return id })
        XCTAssertNil(session.resolveCodexTarget(host))
        XCTAssertTrue(host.scripts.isEmpty)
    }

    func testPaneSwitchDuringReadOnlyProofCannotStartTheWrongCall() {
        let id = "019a1234-6789-7abc-8def-0123456789ab"
        let host = FakeHost(probe: FakeHost.probe()) { _, _ in }
        var active = "%3"
        host.scriptLines = { script in
            if script.contains("codex current") { active = "%4"; return [id] }
            return ["\(active)|||/project"]
        }
        let session = VoiceSession(config: .init(hostName: "h", address: "host", tmuxSession: "work", backend: .codex),
                                   manifest: manifest, login: { .host(host) }, readCodexStatus: {
                                       XCTFail("Switched panes cannot supply input for this call"); return nil
                                   })
        defer { session.close() }
        XCTAssertNil(session.resolveCodexTarget(host))
    }

    func testManualStatusCaptureIgnoresPriorOutputOtherSubmissionsAndCancelledAttempts() {
        let id = "019a1234-6789-7abc-8def-0123456789ab"
        let report = Data("Model: gpt-5\r\nDirectory: /tmp\r\nSession: \(id)".utf8)
        var observation = CodexStatusObservation()
        observation.receive(report)
        XCTAssertNil(observation.thread)
        observation.sentInput(submittingStatus: false)
        observation.receive(report)
        XCTAssertNil(observation.thread)
        observation.sentInput(submittingStatus: true)
        observation.receive(report.prefix(25))
        XCTAssertNil(observation.thread)
        // A new call after cancellation or timeout starts with no pending input or prior response.
        observation = CodexStatusObservation()
        observation.receive(report.suffix(from: 25))
        XCTAssertNil(observation.thread)
        observation.sentInput(submittingStatus: true)
        observation.receive(report)
        XCTAssertEqual(observation.thread, id)
        observation.sentInput(submittingStatus: false)
        XCTAssertNil(observation.thread)
    }

    func testFreshStatusBindsUnboundPaneAndReplacesStaleBindingAfterThreadSwitch() {
        let id = "019a1234-6789-7abc-8def-0123456789ab"
        for previous in ["", "019e1234-6789-7abc-8def-0123456789ab"] {
            let bound = Box(false)
            let host = FakeHost(probe: FakeHost.probe("no", version: "0.9.7")) { stream, _ in stream.exit(0) }
            host.scriptLines = { script in
                if script.contains("codex bind '%3' '\(id)'") { bound.value = true }
                let marker = bound.value ? id : previous
                return ["%3|\(marker)|\(marker)|/project"]
            }
            let session = VoiceSession(config: .init(hostName: "h", address: "localhost", tmuxSession: "work", backend: .codex),
                                       manifest: manifest, timings: fastTimings, login: { .host(host) }, readCodexStatus: { id })
            session.start()
            XCTAssertTrue(waitUntil(2) { host.allStreams.first?.command.contains("--codex-thread " + id) == true })
            XCTAssertTrue(bound.value)
            session.close()
        }
    }

    func testDirectCodexWithoutMediaReportsFailureAfterDeadline() {
        let thread = "019a1234-6789-7abc-8def-0123456789ab"
        let host = FakeHost(probe: FakeHost.probe("no", version: "0.9.7")) { s, _ in
            s.hello(["proto": 1, "mic_port": 0, "session": "s", "resume_token": "t"])
        }
        var timings = fastTimings
        timings.mediaStartTimeoutMs = 100
        let session = VoiceSession(config: .init(hostName: "h", address: "localhost", backend: .codex),
                                   manifest: manifest, timings: timings, login: { .host(host) }, readCodexStatus: { thread })
        session.start()
        XCTAssertTrue(waitUntil(2) { if case .failed = session.phase { return true }; return false })
        XCTAssertEqual(host.allStreams.count, 1)
        XCTAssertTrue(host.allStreams.first?.command.contains("--codex-thread " + thread) == true)
        session.close()
    }

    func testFreshStatusRequiresAnExactSessionUUIDFromStatusPanel() {
        let id = "019a1234-6789-7abc-8def-0123456789ab"
        let report = "│ Model: gpt-5 │\r\n│ Directory: /tmp │\r\n│ Session: \u{1b}[1m" + id + "\u{1b}[0m │"
        XCTAssertEqual(VoiceProtocol.codexThreadFromStatus(Data(report.utf8)), id)
        let wrapped = "  Model: gpt-5\r\n  Directory: /tmp\r\n  Session:\r\n                       " + id.prefix(21) + "\r\n                       " + id.dropFirst(21)
        XCTAssertEqual(VoiceProtocol.codexThreadFromStatus(Data(wrapped.utf8)), id)
        XCTAssertNil(VoiceProtocol.codexThreadFromStatus(Data(report.replacingOccurrences(of: id, with: id + "b").utf8)))
        XCTAssertNil(VoiceProtocol.codexThreadFromStatus(Data(("Conversation: " + id).utf8)))
    }

    func testCodexKeepsThreadOnResumeAndStopsAfterMediaLessReconnects() {
        let host = FakeHost(probe: FakeHost.probe("no", version: "0.9.7")) { s, attempt in
            s.hello(["proto": 1, "mic_port": 0, "session": "session", "resume_token": "token"])
            if attempt == 1 { s.feed(DesktopProtocol.frame(VoiceProtocol.MIC_START, [9, 0, 0, 0, 0x80, 0x3e, 0, 0, 1])) }
            Thread.sleep(forTimeInterval: 0.06)
            s.exit(0)
        }
        let first = "019a1234-6789-7abc-8def-0123456789ab", second = "019b1234-6789-7abc-8def-0123456789ab"
        host.scriptLines = { [weak host] _ in
            let id = host?.allStreams.isEmpty == true ? first : second
            return ["%3|\(id)|\(id)|/project"]
        }
        var timings = fastTimings
        timings.recoverLimitMs = 230
        let session = VoiceSession(config: .init(hostName: "h", address: "localhost", tmuxSession: "work", backend: .codex),
                                   manifest: manifest, timings: timings, login: { .host(host) }, readCodexStatus: { "019a1234-6789-7abc-8def-0123456789ab" })
        defer { session.close() }
        session.start()
        XCTAssertTrue(waitUntil(1.5) { if case .failed = session.phase { return true }; return false })
        XCTAssertGreaterThanOrEqual(host.allStreams.count, 2)
        XCTAssertTrue(host.allStreams.allSatisfy { $0.command.contains("--codex-thread 019a1234-6789-7abc-8def-0123456789ab") })
    }

    func testCodexBackendAutoUpgradesWhenLegacyPluginReturnsNonZeroMicPort() {
        let installAttempts = Box<Int>(0)
        let host = FakeHost(probe: FakeHost.probe("no", uname: "Linux x86_64", version: "0.9.7")) { s, attempt in
            if attempt == 1 {
                // Simulates an old plugin ignoring --backend codex and opening agy TCP port 24713.
                s.hello(["proto": 1, "ver": "0.9.7", "os": "linux", "mode": "voice", "mic_port": 24713, "session": "old", "resume_token": "t", "codecs": ["opus"]])
            } else {
                s.hello(["proto": 1, "ver": "0.9.7", "os": "linux", "mode": "voice", "mic_port": 0, "session": "new", "resume_token": "t", "codecs": ["opus"]])
                s.feed(DesktopProtocol.frame(VoiceProtocol.MIC_START, [1, 0, 0, 0, 0x80, 0x3e, 0, 0, 1]))
            }
        }
        host.scriptLines = { _ in ["%3|019a1234-6789-7abc-8def-0123456789ab|019a1234-6789-7abc-8def-0123456789ab|/project"] }
        host.scriptStatus = { script in
            if script.contains("roamtty-desktop") { installAttempts.value += 1 }
            return 0
        }
        let session = VoiceSession(
            config: .init(hostName: "h", address: "127.0.0.1", tmuxSession: "work", backend: .codex),
            manifest: manifest,
            timings: fastTimings,
            login: { .host(host) },
            readCodexStatus: { "019a1234-6789-7abc-8def-0123456789ab" },
            fetch: { _ in Data() }
        )
        defer { session.close() }
        session.start()
        // Attempt 1 sees mic_port=24713 -> triggers headless auto-upgrade -> attempt 2 succeeds with mic_port=0!
        XCTAssertTrue(waitUntil(3) {
            if case .ready(0, _) = session.phase { return true }
            return false
        })
        XCTAssertEqual(host.allStreams.count, 2)
    }
}
