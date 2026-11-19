#if DEBUG
import Foundation
import UIKit
import SwiftTerm
import RoamttyCore
import RoamttyTransport

/// Opt-in Debug regression probe. Uses only its explicit disposable fixture, never saved hosts.
/// Run via scripts/run-memory-validation.py after installing this build.
@MainActor enum MemoryValidation {
    private static var started = false
    private final class Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }
    /// The checks so far, written to report.json after each one so a run that dies still leaves what it measured.
    @MainActor private final class Report {
        private let folder: URL
        private let startedAt = ISO8601DateFormatter().string(from: Date())
        private var checks: [[String: Any]] = []

        init(folder: URL) { self.folder = folder; save() }

        func add(_ check: [String: Any]) { checks.append(check); save() }

        private func save() {
            let report: [String: Any] = ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "kind": "opt-in Debug memory regression",
                "startedAt": startedAt, "status": checks.last?["name"] as? String == "finished" ? "finished" : "running",
                "device": UIDevice.current.model, "system": UIDevice.current.systemVersion, "checks": checks]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("report.json"), options: .atomic)
            }
        }
    }

    private static var footprint: UInt64 { Diagnostics.footprintMiB() ?? 0 }

    static func runIfRequested() async {
        guard !started, ProcessInfo.processInfo.arguments.contains("--memory-validation") else { return }
        started = true
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("MemoryValidation")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let report = Report(folder: folder)
        try? await Task.sleep(for: .seconds(3))
        report.add(["name": "baseline", "footprintMiB": footprint])
        let gestures = await displayLinkLifetime(report)
        await reattachLifetime(report)
        let host = Host(id: "performance-review-only", name: "Review fixture", address: "127.0.0.1", username: "unused")
        for reset in [false, true] { await terminalDiscard(report, host: host, reset: reset) }
        for wrapped in [false, true] { await feedTiming(report, host: host, wrapped: wrapped) }
        report.add(accessibilityTailProbe(host: host))
        do {
            let result = try await performInBackground { try uploadProbe() }
            report.add(result)
            try? await Task.sleep(for: .seconds(2))
            report.add(["name": "post_upload_idle", "footprintMiB": footprint])
        } catch {
            report.add(["name": "upload_probe_error", "errorType": String(describing: type(of: error))])
        }
        report.add(["name": "finished", "footprintMiB": footprint,
            "desktopGestureViewsStillRetained": gestures.filter { $0.value != nil }.count,
            "terminalCensus": TerminalCensus.live])
    }

    /// Gesture views that never joined a window go as plain views do; returns them for the final count.
    private static func displayLinkLifetime(_ report: Report) async -> [Weak<DesktopGestureView>] {
        var plain: [Weak<UIView>] = []
        var gestures: [Weak<DesktopGestureView>] = []
        for _ in 0..<10 {
            autoreleasepool {
                let view = UIView(frame: .zero); plain.append(Weak(view))
                let desktop = DesktopGestureView(frame: .zero); gestures.append(Weak(desktop))
            }
        }
        try? await Task.sleep(for: .seconds(1))
        report.add(["name": "desktop_displaylink_lifetime", "created": 10,
            "plainViewsRetained": plain.filter { $0.value != nil }.count,
            "desktopGestureViewsRetained": gestures.filter { $0.value != nil }.count,
            "passed": plain.allSatisfy { $0.value == nil } && gestures.allSatisfy { $0.value == nil },
            "footprintMiB": footprint])
        return gestures
    }

    /// Gesture views taken off a window and put back on it still go once they leave it.
    private static func reattachLifetime(_ report: Report) async {
        var reattached: [Weak<DesktopGestureView>] = []
        if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) {
            for _ in 0..<10 {
                autoreleasepool {
                    let view = DesktopGestureView(frame: .zero)
                    reattached.append(Weak(view))
                    window.addSubview(view)
                    view.stopTicking() // UIViewRepresentable dismantle path.
                    view.removeFromSuperview()
                    window.addSubview(view) // Reattachment must restart the link safely.
                    view.removeFromSuperview()
                }
            }
        }
        try? await Task.sleep(for: .seconds(1))
        report.add(["name": "desktop_displaylink_reattach_lifetime", "created": reattached.count,
            "viewsRetained": reattached.filter { $0.value != nil }.count,
            "passed": reattached.count == 10 && reattached.allSatisfy { $0.value == nil }])
    }

    /// Ten sessions with a full scrollback, discarded: the runtime, its view and the terminal model all go.
    private static func terminalDiscard(_ report: Report, host: Host, reset: Bool) async {
        var runtimes: [Weak<SessionRuntime>] = [], views: [Weak<TerminalView>] = [], terminals: [Weak<Terminal>] = []
        for _ in 0..<10 {
            autoreleasepool {
                let runtime = SessionRuntime(record: SessionRecord(hostID: host.id, mode: .shell), host: host)
                runtime.terminalView.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
                runtime.configure(settings: AppSettings(), scheme: .dark)
                let terminal = runtime.terminalView.getTerminal()
                terminal.resize(cols: 80, rows: 24)
                if reset { terminal.feed(text: "\u{1b}c") }
                terminal.feed(text: String(repeating: "review output row abcdefghijklmnopqrstuvwxyz0123456789\r\n", count: 2100))
                runtimes.append(Weak(runtime)); views.append(Weak(runtime.terminalView)); terminals.append(Weak(terminal))
                runtime.discard()
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .seconds(1))
        report.add(["name": reset ? "terminal_reset_then_discard" : "terminal_control_discard", "created": 10,
            "runtimesRetained": runtimes.filter { $0.value != nil }.count,
            "viewsRetained": views.filter { $0.value != nil }.count,
            "terminalModelsRetained": terminals.filter { $0.value != nil }.count,
            "passed": runtimes.allSatisfy { $0.value == nil } && views.allSatisfy { $0.value == nil } && terminals.allSatisfy { $0.value == nil },
            "terminalCensus": TerminalCensus.live, "footprintMiB": footprint])
    }

    /// How long the main thread spends feeding output, raw and through `feedKeepingPlace`.
    private static func feedTiming(_ report: Report, host: Host, wrapped: Bool) async {
        let runtime = SessionRuntime(record: SessionRecord(hostID: host.id, mode: .shell), host: host)
        guard let view = runtime.terminalView as? AccessibleTerminalView else { preconditionFailure("Sessions draw into an AccessibleTerminalView") }
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        runtime.configure(settings: AppSettings(), scheme: .dark)
        view.getTerminal().resize(cols: 80, rows: 24)
        let bytes = Array(String(repeating: String(repeating: "abcdefghij0123", count: 5) + "\r\n", count: 50).utf8)
        var durations: [Double] = []
        for index in 0..<160 {
            let before = ProcessInfo.processInfo.systemUptime
            if wrapped { view.feedKeepingPlace(bytes[...]) } else { view.feed(byteArray: bytes[...]) }
            durations.append((ProcessInfo.processInfo.systemUptime - before) * 1000)
            if index % 8 == 7 { try? await Task.sleep(for: .milliseconds(1)) }
        }
        let sorted = durations.sorted()
        report.add(["name": wrapped ? "terminal_feedKeepingPlace" : "terminal_raw_feed",
            "chunks": durations.count, "bytesPerChunk": bytes.count, "columns": 80, "rows": 24,
            "sumMainThreadMilliseconds": durations.reduce(0, +), "p50Milliseconds": sorted[sorted.count / 2],
            "p95Milliseconds": sorted[Int(Double(sorted.count) * 0.95)], "maxMilliseconds": sorted.last ?? 0])
        runtime.discard()
        try? await Task.sleep(for: .milliseconds(500))
    }

    private static func accessibilityTailProbe(host: Host) -> [String: Any] {
        let runtime = SessionRuntime(record: SessionRecord(hostID: host.id, mode: .shell), host: host)
        defer { runtime.discard() }
        runtime.configure(settings: AppSettings(), scheme: .dark)
        let terminal = runtime.terminalView.getTerminal()
        terminal.resize(cols: 80, rows: 24)
        terminal.feed(text: String(repeating: "history 历史 👩🏽‍💻 e\u{301} abcdefghijklmnopqrstuvwxyz0123456789\r\n", count: 2100))
        let byteLimit = 16 * 1024
        let expected = Data(terminal.getBufferAsData().suffix(byteLimit))
        var equivalent = true
        func measure(_ operation: () -> Data) -> [String: Any] {
            var samples: [Double] = []
            for _ in 0..<20 {
                autoreleasepool {
                    let start = ProcessInfo.processInfo.systemUptime
                    let result = operation()
                    samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
                    equivalent = equivalent && result == expected
                }
            }
            samples.sort()
            return ["iterations": samples.count, "p50Milliseconds": samples[samples.count / 2],
                "maxMilliseconds": samples.last ?? 0, "sumMilliseconds": samples.reduce(0, +)]
        }
        let full = measure { Data(terminal.getBufferAsData().suffix(byteLimit)) }
        let bounded = measure { terminal.getBufferTailAsData(maxBytes: byteLimit) }
        return ["name": "terminal_accessibility_tail", "byteLimit": byteLimit, "returnedBytes": expected.count,
            "passed": equivalent && expected.count == byteLimit, "fullExportThenSuffix": full,
            "boundedTail": bounded, "timingIsBenchmarkNotPassThreshold": true]
    }

    nonisolated private static func uploadProbe() throws -> [String: Any] {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["ROAMTTY_TEST_HOST"], let user = env["ROAMTTY_TEST_USERNAME"],
              let password = env["ROAMTTY_TEST_PASSWORD"], let fingerprint = env["ROAMTTY_TEST_FINGERPRINT"] else {
            return ["name": "sftp_large_upload", "status": "fixture_missing"]
        }
        let token = UUID().uuidString
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("review-" + token)
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let file = try FileHandle(forWritingTo: local)
        try file.truncate(atOffset: 128 * 1_048_576); try file.close()
        defer { try? FileManager.default.removeItem(at: local) }
        let pins = try AppStore(url: URL(fileURLWithPath: ":memory:"))
        let host = Host(name: "Review disposable fixture", address: address,
            port: Int(env["ROAMTTY_TEST_PORT"] ?? "22") ?? 22, username: user, auth: .password)
        let ssh = SSHConnection(host: host, credentials: Credentials(password: Data(password.utf8)), pinStore: pins) { prompt in
            if case .verifyHost(let received) = prompt { return received.fingerprint == fingerprint ? ["verified"] : nil }
            return nil
        }
        let remote = "/tmp/roamtty-review-" + token + ".bin"
        let watchdog = DispatchWorkItem { ssh.disconnect() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: watchdog)
        defer { watchdog.cancel(); try? ssh.remove(remote); ssh.disconnect() }
        try ssh.connect()
        let baseline = Diagnostics.footprintMiB() ?? 0
        var samples: [[String: Any]] = [], next: Int64 = 0
        let start = ProcessInfo.processInfo.systemUptime
        try ssh.upload(local, to: remote, progress: { bytes, _ in
            if bytes >= next {
                samples.append(["uploadedMiB": bytes / 1_048_576, "footprintMiB": Diagnostics.footprintMiB() ?? 0])
                next += 16 * 1_048_576
            }
        })
        let final = Diagnostics.footprintMiB() ?? 0
        try ssh.remove(remote)
        let peak = max(samples.compactMap { $0["footprintMiB"] as? UInt64 }.max() ?? final, final)
        let growth = max(peak, baseline) - baseline
        return ["name": "sftp_large_upload", "status": "completed", "sourceMiB": 128,
            "peakFootprintMiB": peak, "peakGrowthMiB": growth,
            "passed": baseline > 0 && growth < 32,
            "baselineFootprintMiB": baseline, "completedFootprintMiB": final,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start,
            "samples": samples, "remoteFileRemoved": true]
    }
}
#endif
