import Foundation
import UIKit
import RoamttyCore
import RoamttyTransport
import RoamttyDesktopCore

extension AppModel {
    /// The button state for a host's session / host card (Android `DesktopButton.derive`).
    func desktopButton(for host: Host, sessionConnected: Bool, preserveOffline: Bool = false) -> DesktopButton {
        guard let manifest = try? PluginManifest.bundled() else { return .hidden }
        let phase = desktops[host.id]?.phase ?? .idle
        let offline = reachability[host.id]?.isOffline == true
        return DesktopButton.derive(
            hostOnline: preserveOffline || !offline,
            sessionConnected: sessionConnected,
            os: DesktopSupport.buttonOS(host.system),
            osSupported: DesktopSupport.osSupported(host.system, manifest: manifest),
            probe: DesktopProbe.decode(host.desktop),
            probedAt: host.desktopProbedAt,
            now: Int64(Date().timeIntervalSince1970 * 1000),
            phase: phase)
    }

    func desktopSupported(_ host: Host) -> Bool {
        return (try? PluginManifest.bundled()).map { DesktopSupport.osSupported(host.system, manifest: $0) } ?? false
    }

    /// Whether the host page offers 桌面 (Android `ItermuxScreen`): a supported OS whose probe has not
    /// found it without a graphical desktop. A host never probed keeps the button; opening it checks.
    func desktopOnHostPage(_ host: Host) -> Bool {
        desktopSupported(host) && DesktopProbe.decode(host.desktop) != .no
    }

    /// Opens the host's desktop page, starting the connection if needed.
    func openDesktop(_ host: Host) { Task { await openDesktopAsync(host) } }

    /// The dock's desktop button: the host's desktop in a small window over its terminal, starting the connection
    /// without opening the page; tapped again, the window goes and the desktop stays for its keep-alive.
    func toggleDesktopPip(_ host: Host) {
        if pipDesktopHostID == host.id { pipDesktopHostID = nil; return }
        pipDesktopHostID = host.id
        if let existing = desktops[host.id], existing.host.hasSameLoginIdentity(as: host), existing.active { return }
        Task { await openDesktopAsync(host, show: false) }
    }

    /// The controller the small window shows for `hostID`, if it is open over that host's terminal.
    func pipDesktop(for hostID: String) -> DesktopController? {
        pipDesktopHostID == hostID ? desktopStore?[hostID] : nil
    }

    /// `show`: push the desktop page; otherwise only connect (for the small window).
    func openDesktopAsync(_ host: Host, show: Bool = true) async {
        if let existing = desktops[host.id],
           existing.host.hasSameLoginIdentity(as: host), existing.active {
            if show, !path.contains(.desktop(host.id)) { path.append(.desktop(host.id)) }
            return
        }
        desktops.remove(host.id)
        do {
            let credentials = try await logins.credentials(for: host)
            let prefs = settings.desktopHosts[host.id] ?? DesktopHostSettings()
            var config = desktopConfig(for: host)
            config.fps = prefs.fps
            config.quality = prefs.quality
            config.lockOnClose = prefs.lockOnClose
            config.audio = prefs.audio
            config.keepAliveMinutes = settings.desktopKeepAliveMinutes
            let manifest = try desktopManifest()
            let hostID = host.id
            let session = DesktopSession(config: config, manifest: manifest, login: { [weak self] in
                guard let self else { return .failed(message: nil, connecting: false) }
                return self.syncDesktopLogin(hostID: hostID, credentials: credentials)
            })
            session.onProbe = { [weak self, weak session] probe in
                Task { @MainActor in
                    guard let self, let session, self.desktops[hostID]?.session === session else { return }
                    self.saveDesktopProbe(host, probe)
                }
            }
            let controller = DesktopController(
                host: host, session: session, prefs: prefs,
                showStats: settings.desktopShowStats, english: english,
                onPrefs: { [weak self] p in self?.saveDesktopPrefs(hostID, p) },
                onEnded: { [weak self] ended in self?.desktopEnded(ended) })
            desktops.put(controller)
            controller.start()
            watchDesktopNetwork()
            if show, !path.contains(.desktop(host.id)) { path.append(.desktop(host.id)) }
            objectWillChange.send()
        } catch {
            if !show, pipDesktopHostID == host.id { pipDesktopHostID = nil }
            self.error = error.localizedDescription
        }
    }

    /// A desktop ended: a failed one keeps its page, with the error, until a retry or a close; any other goes.
    private func desktopEnded(_ ended: DesktopController) {
        guard desktops[ended.host.id] === ended, !ended.active else { return }
        if case .failed = ended.session.phase {
            if ended.session.failure == .noDesktop {
                saveDesktopProbe(ended.host, HostDesktop(desktop: "no", uname: "", pluginVersion: nil))
            }
        } else {
            desktops.remove(ended.host.id)
        }
        objectWillChange.send()
    }

    /// A desktop session's settings for `host`, at this screen's size and in the app's language.
    func desktopConfig(for host: Host) -> DesktopSession.Config {
        let scale = UIScreen.main.scale, bounds = UIScreen.main.bounds
        var config = DesktopSession.Config(hostName: host.name, address: host.hostname, clientWidth: Int(bounds.width * scale),
                                           clientHeight: Int(bounds.height * scale), clientDpi: Int(160 * scale))
        config.english = english
        return config
    }

    func desktopManifest() throws -> PluginManifest {
        let pinned = try PluginManifest.bundled()
        let base = settings.desktopPluginBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? pinned : pinned.withBaseUrl(base)
    }

    /// Blocking login for the desktop worker thread: a fresh SSH connection of its own (Android's pageLogin).
    nonisolated private func syncDesktopLogin(hostID: String, credentials: Credentials) -> DesktopLogin {
        let host: Host? = DispatchQueue.main.sync { self.host(hostID) }
        guard let host else { return .failed(message: nil, connecting: false) }
        do {
            let ssh = try DispatchQueue.main.sync { try self.logins.makeConnection(host, credentials: credentials, owner: "desktop-\(hostID)") }
            try ssh.connect()
            return .host(SSHDesktopHost(connection: ssh))
        } catch let error as RoamError {
            if case .authentication = error {
                return .failed(message: DispatchQueue.main.sync { self.text("认证失败", "Authentication failed") }, connecting: false)
            }
            return .failed(message: error.localizedDescription, connecting: true)
        } catch {
            return .failed(message: error.localizedDescription, connecting: true)
        }
    }

    func closeDesktop(_ hostID: String) {
        if pipDesktopHostID == hostID { pipDesktopHostID = nil }
        desktops.remove(hostID)
        path.removeAll { $0 == .desktop(hostID) }
        objectWillChange.send()
    }

    func saveDesktopPrefs(_ hostID: String, _ prefs: DesktopHostSettings) {
        settings.desktopHosts[hostID] = prefs
        saveSettings()
    }

    func saveDesktopProbe(_ host: Host, _ probe: HostDesktop) {
        guard var current = self.host(host.id), current.hasSameLoginIdentity(as: host) else { return }
        current.desktop = probe.desktop
        current.desktopProbedAt = Int64(Date().timeIntervalSince1970 * 1000)
        desktopPluginInstalled[current.id] = probe.version != nil
        do { try store?.saveHost(current); hosts = try store?.hosts() ?? hosts } catch { self.error = error.localizedDescription }
        objectWillChange.send()
    }

    func markDesktopPluginInstalled(for hostID: String) {
        if desktopPluginInstalled[hostID] != true {
            desktopPluginInstalled[hostID] = true
        }
    }

    /// Read-only desktop probe over the host's shared connection (host page / session connect).
    func refreshDesktopProbe(_ host: Host) async {
        // Best-effort: never ask for a password just to look. The monitor runs it again once the user logs in.
        guard pool.isConnected(host.id) || logins.canLoginSilently(host) else { return }
        do {
            let ssh = try await pool.connection(for: host.id)
            let found = try await performInBackground { DesktopProbeScript.probe(SSHDesktopHost(connection: ssh)) }
            if let found { saveDesktopProbe(host, found) }
        } catch { /* probe is best-effort */ }
    }

    /// Blocking SSH login for a `VoiceSession` worker thread.
    nonisolated func syncVoiceLogin(host: Host, credentials: Credentials) -> DesktopLogin {
        do {
            let ssh = try DispatchQueue.main.sync { try self.logins.makeConnection(host, credentials: credentials, owner: "voice-\(host.id)") }
            try ssh.connect()
            return .host(SSHDesktopHost(connection: ssh))
        } catch let error as RoamError {
            if case .authentication = error {
                return .failed(message: DispatchQueue.main.sync { self.text("认证失败", "Authentication failed") }, connecting: false)
            }
            return .failed(message: error.localizedDescription, connecting: true)
        } catch {
            return .failed(message: error.localizedDescription, connecting: true)
        }
    }

    /// Desktops and active voice sessions follow the phone onto another network.
    func watchDesktopNetwork() {
        desktopNetwork.start { [weak self] change in
            guard let self else { return }
            self.desktopStore?.networkChanged(change)
            self.runtimes.values.forEach { $0.voice.networkChanged(change) }
        }
    }
}
