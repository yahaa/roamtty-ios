#if DEBUG
import Foundation
import UIKit
import AVFoundation
import RoamttyDesktopCore
import RoamttyCore
import RoamttyTransport

enum DeviceValidation {
    @MainActor private static var started = false

    @MainActor static func runIfRequested(model: AppModel) async {
        if !started, ProcessInfo.processInfo.arguments.contains("--voice-peer-validation") {
            started = true
            _ = await waitUntilActive()
            await runVoicePeerValidation()
            return
        }
        if !started, ProcessInfo.processInfo.arguments.contains("--voice-audio-validation") {
            started = true
            _ = await waitUntilActive()
            await runVoiceAudioValidation()
            return
        }
        await runFixtureIfRequested(model: model)
    }

    @MainActor private static func runFixtureIfRequested(model: AppModel) async {
        guard !started, ProcessInfo.processInfo.arguments.contains("--device-validation"),
              let fixture = DeviceFixture(environment: ProcessInfo.processInfo.environment) else { return }
        started = true
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = documents.appendingPathComponent("Validation", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let runner = try DeviceValidationRunner(fixture: fixture, folder: folder)
            let active = await waitUntilActive()
            runner.check("app_foreground") {
                guard active else { throw DeviceFailure("App remained inactive for 15 seconds; check pending system permission prompts") }
                return ["activeBeforeNetworkChecks": "true"]
            }
            guard active else { runner.finish(); return }
            try await performInBackground { runner.run() }
            // The app's own reachability probe: online only once the fixture's sshd greets it.
            let online = await ReachabilityProbe.measure(address: fixture.address, port: fixture.port)
            let closed = await ReachabilityProbe.measure(address: fixture.address, port: 9)
            runner.check("ssh_greeting_reachability") {
                guard case .online(let latency) = online else { throw DeviceFailure("The fixture's sshd did not answer the probe") }
                if case .online = closed { throw DeviceFailure("A port without sshd counted as online") }
                return ["sshdOnline": "true", "latencyRecorded": latency >= 0 ? "true" : "false", "closedPortOffline": "true"]
            }

            // Navigate the real app using an in-memory fixture host. Nothing is added
            // to the user's host database, keychain or persistent trust store.
            let host = fixture.host(auth: .password)
            let previousPath = model.path
            model.hosts.append(host)
            if let metrics = runner.displayMetrics { model.monitor.showValidationMetrics(metrics, for: host.id) }
            model.path = []; model.homeTab = .sessions
            _ = await waitUntilActive()
            try? await Task.sleep(for: .milliseconds(800))
            runner.check("home_sessions_snapshot") { try snapshot(model, folder: folder, name: "home-sessions.png", screen: "HomeSessionsTab") }
            model.homeTab = .hosts
            try? await Task.sleep(for: .milliseconds(800))
            runner.check("home_hosts_snapshot") { try snapshot(model, folder: folder, name: "home-hosts.png", screen: "HomeHostsTab") }
            model.path = [.host(host.id)]
            _ = await waitUntilActive()
            try? await Task.sleep(for: .milliseconds(800))
            runner.check("app_window_snapshot") { try captureHostDetail(model, folder: folder) }
            model.monitor.stop(host.id)
            model.path = previousPath
            model.hosts.removeAll { $0.id == host.id }
            model.monitor.showValidationMetrics(nil, for: host.id)
            model.reachability.forgetValidationHost(host.id)
            runner.finish()
        } catch {
            // No environment values, credentials, SSH output or remote file contents
            // are logged. The report is the only diagnostic output.
        }
    }

    @MainActor private static func snapshot(_ model: AppModel, folder: URL, name: String, screen: String) throws -> [String: String] {
        guard model.authentication == nil, model.sheet == nil, model.error == nil, !model.drawer, UIApplication.shared.applicationState == .active,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: { $0.isKeyWindow }),
              window.bounds.width > 0, window.bounds.height > 0 else { throw DeviceFailure("App window unavailable") }
        var rendered = false
        let png = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        guard rendered else { throw DeviceFailure("App window rendering failed") }
        try png.write(to: folder.appendingPathComponent(name), options: .atomic)
        return ["artifact": name, "screen": screen, "method": "App-owned window capture"]
    }
    @MainActor private static func waitUntilActive() async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while UIApplication.shared.applicationState != .active {
            guard Date() < deadline, !Task.isCancelled else { return false }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return true
    }

    /// The host page as the app's own window draws it; no automated tap or accessibility assertion is involved.
    @MainActor private static func captureHostDetail(_ model: AppModel, folder: URL) throws -> [String: String] {
        guard model.authentication == nil, model.sheet == nil, model.error == nil,
              !model.drawer, UIApplication.shared.applicationState == .active,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: { $0.isKeyWindow }),
              window.bounds.width > 0, window.bounds.height > 0 else { throw DeviceFailure("App window unavailable") }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        var rendered = false
        let png = renderer.pngData { _ in rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        guard rendered else { throw DeviceFailure("App window rendering failed") }
        try png.write(to: folder.appendingPathComponent("host-detail.png"), options: .atomic)
        return ["artifact": "host-detail.png", "screen": "HostDetailScreen", "method": "App-owned window capture; no automated tap or accessibility assertions"]
    }
}
extension DeviceValidation {
    static func saveVoiceReport(_ report: [String: Any], name: String) {
        guard let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folder = root.appendingPathComponent("Validation", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    @MainActor static func runVoicePeerValidation() async {
        let file = "voice-peer.json"
        saveVoiceReport(["finished": false], name: file)
        guard let fixture = DeviceFixture(environment: ProcessInfo.processInfo.environment),
              let manifest = try? PluginManifest.bundled(), await VoiceAudioEngine.requestMicrophonePermission() else {
            saveVoiceReport(["finished": true, "passed": false, "error": "Missing fixture, manifest or microphone permission"], name: file)
            return
        }
        let engine = VoiceAudioEngine()
        let events = DispatchQueue(label: "voice.validation.events")
        var micStarted = false, speakerStarted = false
        let ended = DispatchSemaphore(value: 0)
        let session = VoiceSession(config: .init(hostName: "fixture", address: fixture.address), manifest: manifest, callbackQueue: events,
                                   login: {
                                       do { return .host(SSHDesktopHost(connection: try fixture.connect())) }
                                       catch { return .failed(message: nil, connecting: false) }
                                   })
        session.onEvent = { event in
            switch event {
            case .micStarted: micStarted = true
            case .speakerStarted: speakerStarted = true
            default: break
            }
        }
        session.onEnded = { _ in ended.signal() }
        session.audioIO = engine
        engine.prepareSession(route: .speaker)
        session.start()
        var report: [String: Any] = [:]
        var received = 0, acknowledged = 0
        do {
            let (port, bytes, acks) = try await collectPeerAudio(session, fixture: fixture)
            report["port"] = port
            received = bytes
            acknowledged = acks
        } catch { report["error"] = DeviceValidationRunner.safeReason(error) }
        session.close()
        let closed = (try? await performInBackground { ended.wait(timeout: .now() + 8) == .success }) == true
        engine.stopAllSync()
        let streams = events.sync { (micStarted, speakerStarted) }
        let released = engine.queue.sync { engine.engine == nil && !engine.sessionActive && !engine.captureTapInstalled }
        report["microphoneStarted"] = streams.0
        report["speakerStarted"] = streams.1
        report["receivedMicPcmBytes"] = received
        report["speakerAcknowledgements"] = acknowledged
        report["closed"] = closed
        report["released"] = released
        report["finished"] = true
        report["passed"] = closed && released && streams.0 && streams.1 && received >= 3200 && acknowledged >= 1
        saveVoiceReport(report, name: file)
    }

    private static func collectPeerAudio(_ session: VoiceSession, fixture: DeviceFixture) async throws -> (Int, Int, Int) {
        let deadline = Date().addingTimeInterval(30)
        var readyPort: Int?
        while readyPort == nil && Date() < deadline {
            switch session.phase {
            case .ready(let port, _): readyPort = port
            case .failed: throw DeviceFailure("Voice bridge failed before READY")
            default: try await Task.sleep(for: .milliseconds(100))
            }
        }
        guard let port = readyPort else { throw DeviceFailure("No AGY voice port") }
        let result = try await performInBackground {
            let ssh = try fixture.connect()
            defer { ssh.disconnect() }
            return try ssh.exec("\"$HOME/.roamtty/voice-validation-peer\" \(port)", timeout: 25)
        }
        let parts = result.trimmedText.split(whereSeparator: \.isWhitespace)
        guard result.status == 0, parts.count == 3, parts[0] == "ROAMTTY_VOICE_PEER",
              let bytes = Int(parts[1]), let acks = Int(parts[2]) else { throw DeviceFailure("Peer failed or returned invalid counters") }
        return (port, bytes, acks)
    }

    /// Captures frame counts and audio-port names only. The microphone PCM never leaves this callback.
    @MainActor static func runVoiceAudioValidation() async {
        let probe = VoiceAudioEngine()
        let counts = CaptureCounts()
        var report: [String: Any] = ["finished": false]
        func save() { saveVoiceReport(report, name: "voice-audio.json") }
        save()
        let granted = await VoiceAudioEngine.requestMicrophonePermission()
        report["microphonePermission"] = granted
        var stages: [[String: Any]] = []
        var ok = granted
        if granted {
            probe.prepareSession(route: .speaker)
            probe.startMic(streamId: 1, sampleRate: 24_000, channels: 1) { _, bytes in counts.observe(bytes.count) }
            for (route, expected) in [(VoiceAudioRoute.speaker, AVAudioSession.Port.builtInSpeaker),
                                      (.earpiece, .builtInReceiver), (.speaker, .builtInSpeaker)] {
                let before = counts.snapshot()
                probe.setAudioRoute(route)
                let deadline = Date().addingTimeInterval(6)
                var ports: [String] = []
                var after = before
                repeat {
                    try? await Task.sleep(for: .milliseconds(100))
                    ports = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }
                    after = counts.snapshot()
                } while (!ports.contains(expected.rawValue) || after.frames <= before.frames) && Date() < deadline
                let passed = ports.contains(expected.rawValue) && after.frames > before.frames && after.invalid == before.invalid
                stages.append(["expectedOutput": expected.rawValue, "actualOutputs": ports,
                               "capturedFrames24k": after.frames - before.frames, "passed": passed])
                ok = ok && passed
                report["stages"] = stages
                save()
            }
        }
        probe.stopAllSync()
        let released = probe.queue.sync { probe.engine == nil && !probe.sessionActive && !probe.captureTapInstalled }
        report["releasedEngineTapAndSession"] = released
        report["finished"] = true
        report["passed"] = ok && released
        save()
    }
}

private final class CaptureCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0, invalid = 0
    func observe(_ bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        frames += bytes / 2
        if bytes != 960 { invalid += 1 }
    }
    func snapshot() -> (frames: Int, invalid: Int) {
        lock.lock(); defer { lock.unlock() }
        return (frames, invalid)
    }
}
#endif
