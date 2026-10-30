import Foundation
import Combine
import Network
import UIKit
import RoamttyCore
import RoamttyTransport
import RoamttyDesktopCore

/// At most one desktop per host (Android `DesktopRegistry`), held by the app model so it outlives the page.
@MainActor final class DesktopStore: ObservableObject {
    @Published private(set) var controllers: [String: DesktopController] = [:]
    private var subscriptions: [String: AnyCancellable] = [:]
    subscript(_ hostID: String) -> DesktopController? { controllers[hostID] }
    func put(_ c: DesktopController) {
        controllers[c.host.id] = c
        subscriptions[c.host.id] = c.$phase.removeDuplicates().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
    func remove(_ hostID: String) {
        let removed = controllers.removeValue(forKey: hostID)
        subscriptions[hostID] = nil
        removed?.close()
        objectWillChange.send()
    }
    var live: [DesktopController] {
        controllers.values.filter {
            switch $0.phase {
            case .connected, .recovering, .connecting, .needsAction: return true
            default: return false
            }
        }
    }
    func networkChanged(_ change: NetworkChange) { controllers.values.forEach { $0.session.networkChanged(change) } }
}

/// One host's desktop on the main actor: owns the `DesktopSession`, the VideoToolbox decoder and the page model.
@MainActor final class DesktopController: ObservableObject {
    let host: Host
    let session: DesktopSession
    let decoder: DesktopVideoDecoder
    let page: DesktopPageModel
    let display: VideoToolboxDisplay
    let audio: DesktopAudioPlayer
    /// Nil until the host said; false when it has no sound to send.
    @Published private(set) var audioAvailable: Bool?
    #if DEBUG
    /// Test only (ROAMTTY_DESKTOP_AUDIO_PROBE=1): what the player decoded, for the live UI test.
    @Published private(set) var audioProbe = ""
    #endif
    @Published private(set) var phase: DesktopPhase = .idle
    @Published private(set) var log: [String] = []
    @Published private(set) var stats = DesktopStats()
    @Published private(set) var hello: Hello?
    @Published private(set) var cursor: RemoteCursor?
    @Published var notice: String?
    @Published private(set) var videoSize = (0, 0)
    @Published var clipNote: String?
    /// The gesture view's zoom and pan; the picture and the cursor are drawn where it puts them.
    @Published var viewport: Viewport?
    private(set) var prefs: DesktopHostSettings
    private let onEnded: (DesktopController) -> Void
    private let onPrefs: (DesktopHostSettings) -> Void

    var windowsHost: Bool {
        #if DEBUG
        if layoutFixture { return fixtureWindowsHost }
        #endif
        return session.windowsHost
    }
    var active: Bool { session.active }
    var viewOnly: Bool { session.viewOnly }
    var quality: String { session.quality }
    var fps: Int { session.fps }
    var lockOnClose: Bool { session.lockOnClose }
    var audioOn: Bool { session.audioOn }
    var displayIndex: Int { session.display }
    /// Input and the cursor are in the display's native pixels; the video is often scaled down from
    /// them (a 4K screen arrives 1920 wide). Before the hello, the video size stands in.
    var remoteSize: (Int, Int) {
        if let d = hello?.displays, d.indices.contains(displayIndex) { return (d[displayIndex].width, d[displayIndex].height) }
        return videoSize
    }

    init(host: Host, session: DesktopSession, prefs: DesktopHostSettings, showStats: Bool, english: Bool,
         onPrefs: @escaping (DesktopHostSettings) -> Void,
         onEnded: @escaping (DesktopController) -> Void) {
        self.host = host; self.session = session; self.prefs = prefs
        self.onPrefs = onPrefs; self.onEnded = onEnded
        decoder = DesktopVideoDecoder(name: "VideoToolbox")
        display = VideoToolboxDisplay()
        display.decoder = decoder
        decoder.display = display
        decoder.session = session
        session.video = decoder
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        audio = DesktopAudioPlayer(muted: environment["ROAMTTY_DESKTOP_AUDIO_MUTE"] == "1")
        #else
        audio = DesktopAudioPlayer()
        #endif
        session.audio = audio
        page = DesktopPageModel(pointerMode: prefs.pointerMode == "mouse" ? .mouse : .touch,
                                showStats: showStats, english: english)
        session.onPhase = { [weak self] p in Task { @MainActor in self?.phase = p } }
        session.onLog = { [weak self] l in Task { @MainActor in self?.log = l } }
        session.onStats = { [weak self] s in Task { @MainActor in self?.stats = s } }
        session.onHello = { [weak self] h in Task { @MainActor in self?.hello = h } }
        session.onCursor = { [weak self] c in Task { @MainActor in self?.cursor = c } }
        session.onNotice = { [weak self] n in Task { @MainActor in self?.notice = n } }
        session.onVideoSize = { [weak self] w, h in Task { @MainActor in self?.videoSize = (w, h) } }
        session.onAudioAvailable = { [weak self] a in Task { @MainActor in self?.audioAvailable = a } }
        session.onRemoteClipboard = { [weak self] text in
            Task { @MainActor in
                UIPasteboard.general.string = text
                self?.clipNote = self?.page.clipReceivedNote(length: text.count)
            }
        }
        session.onEnded = { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.active else { return }
                self.decoder.close()
                self.audio.stop()
                self.onEnded(self)
            }
        }
        decoder.attach(name: "VideoToolbox")
        #if DEBUG
        if environment["ROAMTTY_DESKTOP_AUDIO_PROBE"] == "1" {
            _ = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let l = self.audio.level
                    self.audioProbe = "audio rms=\(l.rms) crossings=\(l.crossings) packets=\(self.audio.packets) dropped=\(self.audio.dropped) queued=\(self.audio.queuedMs) target=\(self.audio.targetMs) cushions=\(self.audio.cushions) rate=\(Int((self.audio.rate * 1000).rounded()))"
                }
            }
        }
        #endif
    }

    func start() { session.start() }
    func close() { session.close() }
    func pause() { session.pause() }
    #if DEBUG
    private var layoutFixture = false
    private var fixtureWindowsHost = false
    private var fixtureRecoverySequence = false
    func configureLayoutFixture(status: String? = nil, english: Bool = false) {
        layoutFixture = true
        fixtureRecoverySequence = status == "recovery-sequence"
        switch status {
        case "login": phase = .connecting(step: .login)
        case "install": phase = .connecting(step: .install)
        case "start": phase = .connecting(step: .start)
        case "first-frame": phase = .connecting(step: .firstFrame)
        case "needs-screen-recording": phase = .needsAction(needs: ["screen-recording"])
        case "needs-accessibility": phase = .needsAction(needs: ["accessibility"])
        case "needs-windows":
            fixtureWindowsHost = true
            phase = .needsAction(needs: ["not-logged-in"])
        case "failed": phase = .failed(message: DesktopText.noDesktop.text(english: english))
        case "recovering": phase = .recovering(sinceMs: Int64(Date().timeIntervalSince1970 * 1000) - 3_000)
        case "poor-network": phase = .connected(poor: true)
        default: phase = .connected()
        }
        if status == nil || status == "connected" || status == "recovering" || status == "stats" || status == "poor-network" || fixtureRecoverySequence { videoSize = (1280, 720) }
        if status == "stats" || status == "poor-network" {
            stats.link = "UDP"; stats.rttMs = 15; stats.fps = 60; stats.kbps = 2400
            stats.width = 1920; stats.height = 1246; stats.encoder = "videotoolbox"
            stats.lossPercent = 0; stats.latency = .init(captureMs: 2, convertMs: 1, encodeMs: 3,
                                                      networkMs: 15, decodeMs: 1, renderMs: 0, totalMs: 22)
        }
        log = [DesktopText.step(.hostDownload).text(english: english),
               DesktopText.installing(version: "0.8.2", target: "linux-x86_64").text(english: english)]
    }
    #endif
    func resume() {
        #if DEBUG
        if layoutFixture {
            if videoSize.0 > 0 { display.showLayoutFixture() }
            return
        }
        #endif
        session.resume()
    }
    func input(_ bytes: [UInt8]) {
        #if DEBUG
        // Existing rail actions drive real in-place phase transitions in the isolated UI fixture.
        if fixtureRecoverySequence {
            if bytes == DesktopProtocol.action(DesktopProtocol.ACTION_ALL_WINDOWS) {
                phase = .recovering(sinceMs: Int64(Date().timeIntervalSince1970 * 1000))
            } else if bytes == DesktopProtocol.action(DesktopProtocol.ACTION_SHOW_DESKTOP) {
                phase = .connected()
            }
            return
        }
        #endif
        session.input(bytes)
    }
    func send(_ bytes: [UInt8]) { session.send(bytes) }

    func setViewOnly(_ on: Bool) { objectWillChange.send(); session.setViewOnly(on) }
    func setQuality(_ q: String) { objectWillChange.send(); session.setQuality(q); prefs.quality = q; onPrefs(prefs) }
    func setFps(_ f: Int) { objectWillChange.send(); session.setFps(f); prefs.fps = f; onPrefs(prefs) }
    func setDisplay(_ i: Int) { objectWillChange.send(); session.setDisplay(i) }
    func setLockOnClose(_ on: Bool) { objectWillChange.send(); session.setLockOnClose(on); prefs.lockOnClose = on; onPrefs(prefs) }
    func setAudio(_ on: Bool) { objectWillChange.send(); session.setAudio(on); prefs.audio = on; onPrefs(prefs) }
    func setPointerMode(_ mode: PointerMode) {
        page.pointerMode = mode
        prefs.pointerMode = mode == .mouse ? "mouse" : "touch"
        onPrefs(prefs)
    }
    func setShowStats(_ on: Bool) { page.showStats = on }
}

extension AppModel {
    /// The button state for a host's session / host card (Android `DesktopButton.derive`).
    func desktopButton(for host: Host, sessionConnected: Bool, preserveOffline: Bool = false) -> DesktopButton {
        guard let manifest = try? PluginManifest.bundled() else { return .hidden }
        let phase = desktops[host.id]?.phase ?? .idle
        let offline: Bool = {
            if case .offline = reachability[host.id] ?? .checking { return true }
            return false
        }()
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

    #if DEBUG
    /// An isolated, offline UI fixture: no credentials, network connection or user-store changes.
    func installDesktopControlsFixture() throws {
        guard ProcessInfo.processInfo.arguments.contains("--desktop-controls-fixture"),
              ProcessInfo.processInfo.environment["ROAMTTY_STORAGE_NAME"] == "DesktopControlsFixture" else { return }
        let environment = ProcessInfo.processInfo.environment
        if let language = environment["ROAMTTY_DESKTOP_FIXTURE_LANGUAGE"] { settings.language = language }
        if let stats = environment["ROAMTTY_DESKTOP_STATS_FIXTURE"] { settings.desktopShowStats = stats == "1" }
        let host = Host(id: "desktop-controls-fixture", name: "MacBook", address: "127.0.0.1", port: 9, username: "fixture")
        let session = DesktopSession(config: .init(hostName: host.name, address: host.address, clientWidth: 1280, clientHeight: 720, clientDpi: 160),
                                     manifest: try PluginManifest.bundled(),
                                     login: { .failed(message: "Offline UI fixture", connecting: false) })
        let controller = DesktopController(host: host, session: session, prefs: DesktopHostSettings(),
                                           showStats: false, english: english, onPrefs: { _ in }, onEnded: { _ in })
        controller.configureLayoutFixture(status: environment["ROAMTTY_DESKTOP_STATUS_FIXTURE"], english: english)
        desktops.put(controller)
        path = [.desktop(host.id)]
    }
    #endif

    func desktopSupported(_ host: Host) -> Bool {
        return (try? PluginManifest.bundled()).map { DesktopSupport.osSupported(host.system, manifest: $0) } ?? false
    }

    /// Opens the host's desktop page, starting the connection if needed.
    func openDesktop(_ host: Host) { Task { await openDesktopAsync(host) } }

    func openDesktopAsync(_ host: Host) async {
        if let existing = desktops[host.id],
           existing.host.hasSameLoginIdentity(as: host), existing.active {
            if !path.contains(.desktop(host.id)) { path.append(.desktop(host.id)) }
            return
        }
        desktops.remove(host.id)
        do {
            let credentials = try await credentials(for: host)
            let prefs = settings.desktopHosts[host.id] ?? DesktopHostSettings()
            let scale = UIScreen.main.scale
            let bounds = UIScreen.main.bounds
            let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
            let dpi = Int(160 * scale)
            var config = DesktopSession.Config(hostName: host.name, address: host.hostname,
                                               clientWidth: width, clientHeight: height, clientDpi: dpi)
            config.english = english
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
                onEnded: { [weak self] ended in
                    guard let self, self.desktops[ended.host.id] === ended, !ended.active else { return }
                    if case .failed = ended.session.phase {
                        // Keep the failure page until an explicit retry or close, including its error text.
                        if ended.session.failure == .noDesktop {
                            self.saveDesktopProbe(ended.host, HostDesktop(desktop: "no", uname: "", pluginVersion: nil))
                        }
                    } else {
                        self.desktops.remove(ended.host.id)
                    }
                    self.objectWillChange.send()
                })
            desktops.put(controller)
            controller.start()
            startDesktopPathMonitor()
            if !path.contains(.desktop(host.id)) { path.append(.desktop(host.id)) }
            objectWillChange.send()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func desktopManifest() throws -> PluginManifest {
        let pinned = try PluginManifest.bundled()
        let base = settings.desktopPluginBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, base != pinned.baseUrl else { return pinned }
        var targets: [String: Any] = [:]
        for (key, target) in pinned.targets {
            targets[key] = ["file": target.file, "sha256": target.sha256, "size": target.size]
        }
        let obj: [String: Any] = [
            "version": pinned.version,
            "baseUrl": base,
            "proto": ["min": pinned.protoMin, "max": pinned.protoMax],
            "openh264": pinned.openh264,
            "targets": targets,
        ]
        return try PluginManifest.parse(String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self))
    }

    /// Blocking login for the desktop worker thread: a fresh SSH connection of its own (Android's pageLogin).
    nonisolated private func syncDesktopLogin(hostID: String, credentials: Credentials) -> DesktopLogin {
        let host: Host? = DispatchQueue.main.sync { self.host(hostID) }
        guard let host else { return .failed(message: nil, connecting: false) }
        do {
            let ssh = try DispatchQueue.main.sync { try self.makeConnection(host, credentials: credentials, owner: "desktop-\(hostID)") }
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
        do { try store?.saveHost(current); hosts = try store?.hosts() ?? hosts } catch { self.error = error.localizedDescription }
        objectWillChange.send()
    }

    /// Read-only desktop probe over the host's shared connection (host page / session connect).
    func refreshDesktopProbe(_ host: Host) async {
        // Best-effort: never ask for a password just to look. The monitor runs it again once the user logs in.
        guard connections[host.id]?.isConnected == true || canLoginSilently(host) else { return }
        do {
            let ssh = try await connection(for: host.id)
            let found = try await performInBackground { DesktopProbeScript.probe(SSHDesktopHost(connection: ssh)) }
            if let found { saveDesktopProbe(host, found) }
        } catch { /* probe is best-effort */ }
    }

    func startDesktopPathMonitor() {
        // Already running.
        if desktopPathMonitor != nil { return }
        let monitor = NWPathMonitor()
        desktopPathMonitor = monitor
        // Updates come one at a time on this serial queue, the only place `last` is touched.
        let queue = DispatchQueue(label: "roamtty.desktop.path", qos: .utility)
        final class Last: @unchecked Sendable { var interface: String?? = nil }
        let last = Last()
        monitor.pathUpdateHandler = { [weak self] path in
            let current = Self.defaultInterface(path)
            let change = NetworkChange.between(last.interface, current)
            last.interface = .some(current)
            guard let change else { return }
            DispatchQueue.main.async { self?.desktopStore?.networkChanged(change) }
        }
        monitor.start(queue: queue)
    }

    /// The interface the traffic goes out on ("cellular:pdp_ip0"), nil without one. A VPN's tunnel
    /// (Tailscale's utun, type other) is not it: its updates leave the network the same.
    nonisolated static func defaultInterface(_ path: NWPath) -> String? {
        guard path.status == .satisfied else { return nil }
        let kinds: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet]
        guard let i = path.availableInterfaces.first(where: { kinds.contains($0.type) }) else { return nil }
        return "\(i.type):\(i.name)"
    }
}
