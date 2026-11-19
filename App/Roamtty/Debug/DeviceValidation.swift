#if DEBUG
import Foundation
import UIKit
import RoamttyCore
import RoamttyTransport

enum DeviceValidation {
    @MainActor private static var started = false

    @MainActor static func runIfRequested(model: AppModel) async {
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
#endif
