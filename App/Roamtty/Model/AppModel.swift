import SwiftUI
import Combine
import RoamttyCore
import RoamttyTransport

/// The app's state and the actions on it: the saved hosts, the terminal sessions and what is on screen.
/// How hosts are logged in to, connected and watched is the work of its services (`logins`, `pool`, `monitor`,
/// `reachability`), which know nothing of sessions or screens. The features live in extensions:
/// - `AppModel+Hosts`: saved hosts and their stored secrets
/// - `AppModel+Sessions`: terminal sessions, from launch to close, and their reconnects
/// - `AppModel+Connections`: which connection a tool works over, and dropping a host's connections
/// - `AppModel+Desktop`: remote desktops, one `DesktopController` per host
/// - `AppModel+Notifications`: the agent notifications
/// Debug builds add the launch fixtures of the UI tests in `AppModel+Fixtures`.
@MainActor final class AppModel: ObservableObject, ConnectionEnvironment, TransferEnvironment {
    // MARK: State the screens show

    @Published var hosts: [Host] = []
    @Published var settings = AppSettings()
    @Published var records: [SessionRecord] = []
    @Published var path: [AppRoute] = [] {
        didSet {
            if let route = path.last, route != oldValue.last { recordHostUse(for: route) }
        }
    }
    @Published var homeTab: HomeTab = .sessions
    /// The session group the home list shows alone, nil for all of them.
    @Published var sessionFilter: SessionGroup?
    @Published var sheet: AppSheet?
    @Published var drawer = false
    @Published var error: String?
    @Published var notice: String?
    @Published var incomingFiles: [URL] = []
    @Published var childModalCount = 0
    /// The login question on screen.
    var authentication: AuthenticationRequest? { logins.prompts.active }
    private(set) lazy var files = FileTransferModel(environment: self)
    var runtimes: [String: SessionRuntime] = [:]

    // MARK: Bookkeeping shared by the feature extensions

    var store: AppStore?
    var journal = SessionJournal()
    private(set) var foreground = true
    var sessionLaunches: [String: TrackedTask] = [:]
    var sessionSubscriptions: [String: AnyCancellable] = [:]
    /// Session id → when it last reconnected by itself; see `SessionReconnect.interval`.
    var autoReconnectedAt: [String: Date] = [:]
    /// Sessions that already retried an unreachable host during this look at the session list.
    var retriedThisVisit = Set<String>()
    /// Session id → when the list began waiting for its host to answer again.
    var waitingForHostSince: [String: Date] = [:]
    /// Remote desktops' thumbnails, and their controllers once the first desktop opens.
    let desktopThumbnails = DesktopThumbnails()
    private(set) var desktopStore: DesktopStore?
    /// The host whose desktop shows in the small window over its terminal (the dock's desktop button).
    @Published var pipDesktopHostID: String?
    let desktopNetwork = DesktopNetworkMonitor()

    // MARK: Connection services

    /// Credentials, the questions a login asks and whether a login under way is still wanted.
    private(set) lazy var logins = relay(HostLogins(environment: self))
    /// The connection each host's tools (files, plugins, metrics) share.
    private(set) lazy var pool: HostConnectionPool = {
        let pool = HostConnectionPool(environment: self, logins: logins)
        pool.onMetadata = { [weak self] host, plugins, system in self?.updateMetadata(host: host, plugins: plugins, system: system) }
        return pool
    }()
    /// The host page's live metrics.
    private(set) lazy var monitor: HostMonitor = {
        let monitor = relay(HostMonitor(environment: self, logins: logins, pool: pool))
        monitor.onConnected = { [weak self] host in Task { await self?.refreshDesktopProbe(host) } }
        return monitor
    }()
    /// Whether each host's sshd answers.
    private(set) lazy var reachability = relay(HostReachabilityTracker(environment: self))
    private var relays = Set<AnyCancellable>()
    /// Screens observe the model alone, so a change in one of its services redraws them as a change in the model does.
    private func relay<Service: ObservableObject>(_ service: Service) -> Service where Service.ObjectWillChangePublisher == ObservableObjectPublisher {
        service.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &relays)
        return service
    }
    var pinStore: PinStore? { store }

    init() {
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let name = ProcessInfo.processInfo.environment["ROAMTTY_STORAGE_NAME"] ?? "Roamtty"
            let folder = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let store = try AppStore(url: folder.appendingPathComponent("roamtty.sqlite"))
            self.store = store
            hosts = try store.hosts(); journal = try store.loadJournal(); settings = try store.loadSettings(); records = journal.records
            let restoredFont = FontCatalog.shared.restore(selection: settings.font)
            if settings.font != restoredFont { settings.font = restoredFont; try store.saveSettings(settings) }
            #if DEBUG
            try installUITestFixture(store)
            try installDesktopControlsFixture()
            try installDesktopGestureFixture()
            #endif
        } catch { self.error = error.localizedDescription }
        installAgentNotifications()
    }

    // MARK: Language and appearance

    var english: Bool { settings.language.hasPrefix("en") }
    var language: AppLanguage { AppLanguage(english: english) }
    func text(_ chinese: String, _ english: String) -> String { language.text(chinese, english) }
    var colorScheme: ColorScheme? { settings.theme == .system ? nil : settings.theme == .dark ? .dark : .light }
    func phaseText(_ phase: ConnectionPhase) -> String {
        switch phase {
        case .connecting: return text("连接中", "Connecting")
        case .verifying: return text("验证指纹", "Verifying host")
        case .authenticating: return text("认证中", "Authenticating")
        case .connected: return text("已连接", "Connected")
        case .disconnected: return text("已断开", "Disconnected")
        case .authFailed: return text("认证失败", "Authentication failed")
        case .hostKeyChanged: return text("指纹已变化", "Host key changed")
        case .failed: return text("连接失败", "Connection failed")
        case .tmuxMissing: return text("未安装 tmux", "tmux missing")
        }
    }
    func saveSettings() {
        AgentNotifier.shared.apply(settings.agentNotifications)
        do { try store?.saveSettings(settings) } catch { self.error = error.localizedDescription }
    }

    /// Remote desktops for every host; created on first use.
    var desktops: DesktopStore {
        if let desktopStore { return desktopStore }
        let store = DesktopStore(); desktopStore = store; return store
    }

    // MARK: Presentation

    /// Presents `next` once the sheet on screen has gone.
    func replaceSheet(with next: AppSheet) {
        sheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.sheet = next }
    }

    // MARK: App lifecycle

    func resume() {
        foreground = true
        AgentNotifier.shared.keepWatching(false)
        Diagnostics.shared.log("foreground", "sessions=\(runtimes.count) terminals=\(TerminalCensus.live)")
        for runtime in runtimes.values { runtime.probe() }
        // A terminal on screen that dropped while the app was away found the app in the background and did not
        // reconnect then; it does now.
        if case .terminal(let id)? = path.last, let record = records.first(where: { $0.id == id }) { Task { await reconnectOnOpen(record) } }
        restartVisibleMonitor()
        // Cold launch never creates the store or the network monitor: both wait for the first desktop opened.
        if desktopStore != nil {
            desktopStore?.live.forEach { $0.resume() }
            watchDesktopNetwork()
        }
        #if DEBUG
        // Fixture diagnostics use separate stores and must not consume the user's shared inbox.
        let diagnostics = ["--device-validation", "--memory-validation", "--desktop-memory-validation"]
        if ProcessInfo.processInfo.arguments.contains(where: { diagnostics.contains($0) }) { return }
        #endif
        SharedInbox.consume { [weak self] result in
            guard let self else { return }
            // Use current presentation/upload state, not the state at the foreground request.
            self.appendIncoming(result.urls)
            if let error = result.errors.first { self.error = error.localizedDescription }
        }
    }
    func importIncoming(_ url: URL) {
        SharedInbox.copyIncoming(url) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let imported): self.appendIncoming([imported])
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }
    /// Restarts the monitor of the host page on screen, after a login change stopped it.
    func restartVisibleMonitor() {
        guard foreground, case .host(let id) = path.last, let host = host(id) else { return }
        monitor.start(host)
    }
    private func appendIncoming(_ urls: [URL]) {
        var existing = Set(incomingFiles + files.pendingUploadURLs).union(files.activeUploadURLs)
        incomingFiles.append(contentsOf: urls.filter { existing.insert($0).inserted })
    }
    /// In the background no login stays in memory and nothing waits for the user.
    func suspend() {
        foreground = false
        Diagnostics.shared.log("background", "sessions=\(runtimes.count) terminals=\(TerminalCensus.live)")
        monitor.stopAll()
        logins.forgetAll()
        for runtime in runtimes.values { runtime.clearLoginCredentials() }
        desktopStore?.live.forEach { $0.pause() }
        logins.dismissAllPrompts()
        // An agent at work may still need the user or finish before iOS suspends the app.
        AgentNotifier.shared.keepWatching(runtimes.values.contains { $0.phase == .connected && ($0.agentStatus.map { $0.state != .idle } ?? false) })
    }
}
