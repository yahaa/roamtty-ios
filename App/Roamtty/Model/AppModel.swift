import SwiftUI
import Combine
import RoamttyCore
import RoamttyTransport

enum AppRoute: Hashable { case host(String), terminal(String), files(String, sessionID: String? = nil, directory: String = ".") }
enum HomeTab: Hashable { case sessions, hosts }
enum AppSheet: Identifiable {
    case editor(Host?)
    /// Fills in a new host on the way to a new session: the agent it starts, or nil for a terminal.
    case newHost(forAgent: CodingAgent?)
    case settings, plugins(Host), guide, about
    /// A launch sheet on a host; `agent` was picked first by the new-session sheet, whose last step this is when `newSession`.
    case launch(Host, Bool, directory: String = "~", agent: CodingAgent? = nil, newSession: Bool = false)
    case newSession
    var id: String {
        switch self {
        case .editor(let h): return "editor-\(h?.id ?? "new")"
        case .newHost(let agent): return "new-host-\(agent?.rawValue ?? "terminal")"
        case .settings: return "settings"
        case .newSession: return "new-session"
        case .launch(let h, let agent, let directory, let picked, _): return "launch-\(h.id)-\(agent)-\(directory)-\(picked?.rawValue ?? "")"
        case .plugins(let h): return "plugins-\(h.id)"
        case .guide: return "guide"
        case .about: return "about"
        }
    }
}
struct AuthenticationRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let labels: [String]
    let echo: [Bool]
    let fingerprint: String?
    var owner: String? = nil
    let answer: ([String]?) -> Void
}
struct HostMonitorState {
    var phase: ConnectionPhase
    var reconnecting = false
    var sampled = false
    var detail: String?
    /// The collectors ran but returned nothing usable: a permissions problem, not a lost login.
    var samplingFailed = false
}
/// Host tools follow the saved host. Session tools retain the exact runtime and SSH
/// connection that opened them, including after that host's address or user is edited.
enum RemoteConnectionTarget {
    case host(String)
    case session(String, SessionConnectionSnapshot<SessionRuntime, SSHConnection>)

    @MainActor static func session(_ runtime: SessionRuntime) -> Self {
        .session(runtime.record.id, SessionConnectionSnapshot(session: runtime, connection: runtime.ssh))
    }

    @MainActor var runtime: SessionRuntime? {
        if case .session(_, let snapshot) = self { return snapshot.session }
        return nil
    }
}
private final class PromptAnswer {
    let signal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var completed = false
    private var value: [String]?
    func finish(_ answer: [String]?) { lock.lock(); defer { lock.unlock() }; guard !completed else { return }; completed = true; value = answer; signal.signal() }
    func result() -> [String]? { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor final class AppModel: ObservableObject {
    @Published var hosts: [Host] = []
    @Published var settings = AppSettings()
    @Published var records: [SessionRecord] = []
    @Published var path: [AppRoute] = []
    @Published var homeTab: HomeTab = .sessions
    /// When each host's shown reachability was measured.
    @Published var reachabilityCheckedAt: [String: Date] = [:]
    @Published var sheet: AppSheet?
    @Published var drawer = false
    @Published var error: String?
    @Published var notice: String?
    @Published var authentication: AuthenticationRequest?
    @Published var metrics: [String: HostMetrics] = [:]
    @Published var metricSeries: [String: HostMetricSeries] = [:]
    @Published var monitorStates: [String: HostMonitorState] = [:]
    @Published var reachability: [String: HostReachability] = [:]
    @Published var hostPhases: [String: ConnectionPhase] = [:]
    @Published var incomingFiles: [URL] = []
    @Published var childModalCount = 0
    @Published var commands: [String] = []
    let files = FileTransferModel()
    private(set) var runtimes: [String: SessionRuntime] = [:]
    private var store: AppStore?
    private let vault = SecretVault()
    private var journal = SessionJournal()
    private var connections: [String: SSHConnection] = [:]
    private var connectionTasks: [String: Task<SSHConnection, Error>] = [:]
    private var connectionTokens: [String: UUID] = [:]
    private var connectingSSH: [String: SSHConnection] = [:]
    private var hostGenerations: [String: UUID] = [:]
    private var ownerGenerations: [String: UUID] = [:]
    private var sessionSubscriptions: [String: AnyCancellable] = [:]
    private var prompts: [AuthenticationRequest] = []
    private var temporaryCredentials: [String: Credentials] = [:]
    private var sessionTasks: [String: Task<Void, Never>] = [:]
    private var sessionLaunchTokens: [String: UUID] = [:]
    private var invalidCredentialHosts = Set<String>()
    private var monitorTokens: [String: UUID] = [:]
    private var monitorTasks: [String: Task<Void, Never>] = [:]
    private var monitorCancellations: [String: TransferCancellation] = [:]
    private var metadataTasks: [String: Task<Void, Never>] = [:]
    private var metadataCancellations: [String: TransferCancellation] = [:]
    private var foreground = true
    /// Session id → when it last reconnected by itself; see `SessionReconnect.interval`.
    private var autoReconnectedAt: [String: Date] = [:]
    /// Sessions that already retried an unreachable host during this look at the session list.
    private var retriedThisVisit = Set<String>()
    /// Session id → when the list began waiting for its host to answer again.
    private var waitingForHostSince: [String: Date] = [:]

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
            commands = UserDefaults.standard.stringArray(forKey: "commonCommands") ?? []
            #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), let address = environment["ROAMTTY_TEST_HOST"], let username = environment["ROAMTTY_TEST_USERNAME"], let password = environment["ROAMTTY_TEST_PASSWORD"] {
                let fixture = Host(id: "ui-live-host", name: "UI Live Host", address: address, port: Int(environment["ROAMTTY_TEST_PORT"] ?? "22") ?? 22, username: username, auth: .password, mode: .tmux, savePassword: true)
                try store.saveHost(fixture); try vault.save(data: Data(password.utf8), hostID: fixture.id, purpose: "password"); hosts = try store.hosts()
            }
            #endif
        } catch { self.error = error.localizedDescription }
    }
    var english: Bool { settings.language.hasPrefix("en") }
    func text(_ chinese: String, _ english: String) -> String { self.english ? english : chinese }
    var colorScheme: ColorScheme? { settings.theme == .system ? nil : settings.theme == .dark ? .dark : .light }
    func host(_ id: String) -> Host? { hosts.first { $0.id == id } }
    /// Android `TerminalConnection.titleForDisplay`: "host · title", or "host · 会话 N" without a title.
    func sessionDefaultTitle(_ record: SessionRecord) -> String { "\(host(record.hostID)?.name ?? "") · " + text("会话 \(record.number)", "Session \(record.number)") }
    /// Sessions the app holds, live first, then connecting, needing the user, and closed (Android `activityRank`).
    var sessionsByActivity: [SessionRecord] {
        func rank(_ record: SessionRecord) -> Int {
            switch runtimes[record.id]?.phase ?? .disconnected {
            case .connected: return 0
            case .connecting, .verifying, .authenticating: return 1
            case .disconnected: return 3
            default: return 2
            }
        }
        return records.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
    /// The agent a session runs: the one its hooks report, else the one it was launched for.
    func sessionAgent(_ record: SessionRecord) -> CodingAgent? {
        let runtime = runtimes[record.id]
        return CodingAgent.fromCommand(runtime?.agentStatus?.agent) ?? runtime?.launchedAgent ?? CodingAgent.fromTitle(record.title)
    }
    func sessionTitle(_ record: SessionRecord) -> String {
        record.title.isEmpty ? sessionDefaultTitle(record) : "\(host(record.hostID)?.name ?? "") · \(record.title)"
    }
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
    func saveSettings() { do { try store?.saveSettings(settings) } catch { self.error = error.localizedDescription } }
    func savedKey(_ hostID: String) -> Data? { try? vault.read(hostID: hostID, purpose: "key") }
    func loginPassword(for hostID: String) -> String? { temporaryCredentials[hostID]?.password.flatMap { String(data: $0, encoding: .utf8) } }
    func saveHost(_ host: Host, password: String, key: Data?, passphrase: String) throws {
        guard let store else { throw RoamError.invalid(text("存储不可用", "Storage unavailable")) }
        let validated = try host.validated()
        let previousHost = self.host(host.id)
        let previousPassword = try vault.read(hostID: host.id, purpose: "password")
        let previousKey = try vault.read(hostID: host.id, purpose: "key")
        let nextKey = key ?? previousKey
        if validated.auth == .key && nextKey == nil { throw RoamError.invalid(text("请选择 SSH 私钥", "Choose an SSH private key")) }
        let nextPassword = validated.savePassword ? (password.isEmpty ? previousPassword : Data(password.utf8)) : nil
        var passwordChanged = false, keyChanged = false
        do {
            if nextPassword != previousPassword { try vault.save(data: nextPassword, hostID: host.id, purpose: "password"); passwordChanged = true }
            if nextKey != previousKey { try vault.save(data: nextKey, hostID: host.id, purpose: "key"); keyChanged = true }
            // The database row is committed only after its credentials are available.
            try store.saveHost(validated)
        } catch {
            let original = error
            do {
                if passwordChanged { try vault.save(data: previousPassword, hostID: host.id, purpose: "password") }
                if keyChanged { try vault.save(data: previousKey, hostID: host.id, purpose: "key") }
            } catch {
                throw RoamError.invalid(original.localizedDescription + text("；凭据恢复失败：", "; credential recovery failed: ") + error.localizedDescription)
            }
            throw original
        }
        let changesConnection = previousHost?.hasSameLoginIdentity(as: validated) != true
            || nextPassword != previousPassword || nextKey != previousKey || !password.isEmpty || !passphrase.isEmpty
        if changesConnection {
            invalidateHostConnections(host.id)
            temporaryCredentials[host.id]?.clear(); temporaryCredentials.removeValue(forKey: host.id)
            invalidCredentialHosts.remove(host.id)
            if !password.isEmpty || !passphrase.isEmpty {
                temporaryCredentials[host.id] = Credentials(password: password.isEmpty ? nextPassword : Data(password.utf8), privateKey: nextKey, passphrase: passphrase.isEmpty ? nil : passphrase)
            }
        }
        hosts = try store.hosts()
        if changesConnection { restartVisibleMonitor() }
    }
    func updateMetadata(host previous: Host, plugins: [String]?, system: String) {
        guard var current = host(previous.id), current.address == previous.address, current.port == previous.port, current.username == previous.username else { return }
        current.plugins = plugins; current.system = system
        do { try store?.saveHost(current); if let index = hosts.firstIndex(where: { $0.id == current.id }) { hosts[index] = current } } catch { self.error = error.localizedDescription }
    }
    func deleteHost(_ host: Host) {
        do {
            invalidateHostConnections(host.id)
            for record in records where record.hostID == host.id { cancelLaunch(record.id); runtimes[record.id]?.clearLoginCredentials(); runtimes[record.id]?.close(); runtimes.removeValue(forKey: record.id); sessionSubscriptions.removeValue(forKey: record.id); UserDefaults.standard.removeObject(forKey: moshPreferenceKey(record.id)) }
            temporaryCredentials[host.id]?.clear(); temporaryCredentials.removeValue(forKey: host.id)
            try vault.remove(hostID: host.id); try store?.deleteHost(id: host.id)
            metrics.removeValue(forKey: host.id); metricSeries.removeValue(forKey: host.id); monitorStates.removeValue(forKey: host.id)
            journal.removeHost(host.id); persistJournal(); hosts.removeAll { $0.id == host.id }; path = []
        } catch { self.error = error.localizedDescription }
    }
    private func persistJournal() { records = journal.records; do { try store?.saveJournal(journal) } catch { self.error = error.localizedDescription } }
    func renameSession(_ id: String, title: String) { journal.rename(id, title: title); persistJournal(); if let record = records.first(where: { $0.id == id }) { runtimes[id]?.record = record } }
    /// Opens a session's terminal from the home page; leaving it returns to the sessions tab.
    func openSession(_ record: SessionRecord) {
        if case .terminal = path.last { path.removeLast() }
        path.append(.terminal(record.id))
        if runtimes[record.id] == nil { autoReconnectedAt[record.id] = Date(); connectSession(record) }
    }
    /// A terminal route whose runtime is gone (restored from the journal): connect it in place.
    func openRestored(_ record: SessionRecord) {
        guard runtimes[record.id] == nil else { return }
        autoReconnectedAt[record.id] = Date(); connectSession(record)
    }
    /// Leaves a terminal for the home page on its sessions tab.
    func leaveTerminal() { path = []; homeTab = .sessions }
    func launch(_ host: Host, mode: SessionMode, directory: String, agent: AgentLaunch?, mosh: Bool?, originalLogin: SessionLoginSnapshot? = nil) {
        do {
            guard StartDirectory.isSupported(directory), agent.map({ StartDirectory.isSupported($0.directory) }) ?? true else { throw RoamError.invalid(text("文件夹路径含有不支持的控制字符", "The folder path contains unsupported control characters")) }
            let directory = StartDirectory.normalize(directory)
            let record = try journal.create(hostID: host.id, mode: mode, title: agent?.title ?? "")
            // A terminal started from its host's page returns there; one started from the home page returns home.
            persistJournal(); sheet = nil
            path = path.first == .host(host.id) ? [.host(host.id), .terminal(record.id)] : [.terminal(record.id)]
            connectSession(record, directory: directory, agent: agent, preferMosh: mosh, originalLogin: originalLogin)
        } catch { self.error = error.localizedDescription }
    }
    func reconnect(_ record: SessionRecord, shell: Bool = false) {
        guard let host = host(record.hostID) else { return }
        let originalLogin = runtimes[record.id]?.loginSnapshot
        if shell { launch(host, mode: .shell, directory: "~", agent: nil, mosh: false, originalLogin: originalLogin) }
        else {
            runtimes[record.id]?.clearLoginCredentials(); runtimes[record.id]?.close(); runtimes.removeValue(forKey: record.id)
            connectSession(record, originalLogin: originalLogin)
        }
    }
    private func connectSession(_ record: SessionRecord, directory: String = "~", agent: AgentLaunch? = nil, preferMosh: Bool? = nil, originalLogin: SessionLoginSnapshot? = nil) {
        guard let savedHost = host(record.hostID) else { return }
        let host = originalLogin?.reconnect(using: savedHost).host ?? savedHost
        let usesSavedCredentials = host.hasSameLoginIdentity(as: savedHost)
        cancelLaunch(record.id)
        let hostGeneration = generation(for: host.id), ownerGeneration = self.ownerGeneration(for: record.id)
        let preference = preferMosh ?? (UserDefaults.standard.object(forKey: moshPreferenceKey(record.id)) as? Bool) ?? (savedHost.plugins?.contains("mosh") == true)
        if let preferMosh { UserDefaults.standard.set(preferMosh, forKey: moshPreferenceKey(record.id)) }
        let runtime = SessionRuntime(record: record, host: host, loginSnapshot: originalLogin)
        runtime.onFailure = { [weak self, weak runtime] failure in
            guard let self, let runtime, self.runtimes[record.id] === runtime, self.isCurrent(hostID: host.id, generation: hostGeneration, owner: record.id, ownerGeneration: ownerGeneration) else { return }
            if usesSavedCredentials, let current = self.host(host.id), host.hasSameLoginIdentity(as: current), (failure as? RoamError) == .authentication {
                self.temporaryCredentials[host.id]?.clear(); self.temporaryCredentials.removeValue(forKey: host.id); self.invalidCredentialHosts.insert(host.id)
            }
        }
        runtimes[record.id] = runtime
        sessionSubscriptions[record.id] = runtime.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        objectWillChange.send()
        let token = UUID(); sessionLaunchTokens[record.id] = token
        sessionTasks[record.id] = Task {
            defer { if sessionLaunchTokens[record.id] == token { sessionTasks.removeValue(forKey: record.id); sessionLaunchTokens.removeValue(forKey: record.id) } }
            do {
                let retained = runtime.loginSnapshot.reconnect(using: savedHost).retainedCredentials
                let creds = try await credentials(for: host, owner: record.id, retained: retained, useSavedCredentials: usesSavedCredentials)
                guard foreground else { throw RoamError.cancelled }
                guard !Task.isCancelled, sessionLaunchTokens[record.id] == token, runtimes[record.id] === runtime, runtime.phase.active, isCurrent(hostID: host.id, generation: hostGeneration, owner: record.id, ownerGeneration: ownerGeneration) else { return }
                let ssh = try makeConnection(host, credentials: creds, owner: record.id)
                runtime.connect(ssh: ssh, credentials: creds, preferMosh: preference, directory: directory, agent: agent)
            } catch { if isCurrent(hostID: host.id, generation: hostGeneration, owner: record.id, ownerGeneration: ownerGeneration), runtimes[record.id] === runtime { runtime.fail(error) } }
        }
    }
    /// Ends a session outright, without asking: a connected tmux session is killed on the server over its live
    /// connection and its card goes; a disconnected one logs in to kill it. A connecting one only stops connecting.
    func closeSession(_ record: SessionRecord) {
        if path.last == .terminal(record.id) { leaveTerminal() }
        let runtime = runtimes[record.id]
        guard record.mode == .tmux else {
            cancelLaunch(record.id); runtime?.close(); removeSession(record); return
        }
        if let runtime, runtime.phase == .connected {
            cancelLaunch(record.id); removeSession(record)
            Task { _ = await runtime.killRemoteSession(); runtime.clearLoginCredentials(); runtime.close() }
        } else if let runtime, runtime.phase.active {
            cancelLaunch(record.id); runtime.close()
        } else {
            forgetSession(record, terminateRemote: true)
        }
    }
    /// 强制删除: forgets a disconnected tmux session's card without logging in; the remote session keeps running.
    func forceDeleteSession(_ record: SessionRecord) { forgetSession(record, terminateRemote: false) }
    /// A tmux session restarts its pane over the live connection; a plain shell gets a fresh one by reconnecting.
    func restartSession(_ record: SessionRecord) {
        guard record.mode == .tmux, let runtime = runtimes[record.id] else { reconnect(record); return }
        Task { if !(await runtime.restartPane()) { error = text("未能重启会话，请检查连接后重试", "Couldn't restart the session. Check the connection and try again.") } }
    }
    private func removeSession(_ record: SessionRecord) {
        runtimes[record.id]?.clearLoginCredentials(); runtimes.removeValue(forKey: record.id); sessionSubscriptions.removeValue(forKey: record.id)
        UserDefaults.standard.removeObject(forKey: moshPreferenceKey(record.id))
        autoReconnectedAt.removeValue(forKey: record.id); waitingForHostSince.removeValue(forKey: record.id)
        journal.forget(record.id); persistJournal()
    }
    func forgetSession(_ record: SessionRecord, terminateRemote: Bool) {
        let runtime = runtimes[record.id]
        // Restored/disconnected cards can connect on request. A live card always owns
        // its existing connection; closing/replacing it while queued must not retarget.
        let target: RemoteConnectionTarget
        if let runtime, runtime.phase == .connected { target = .session(runtime) }
        else { target = .host(record.hostID) }
        cancelLaunch(record.id)
        @MainActor func validateTerminationTarget() throws {
            guard runtimes[record.id] === runtime else { throw RoamError.cancelled }
            if case .host = target, let runtime {
                guard let current = host(record.hostID), runtime.host.hasSameLoginIdentity(as: current) else {
                    throw RoamError.invalid(text("主机连接信息已更改。请恢复原主机后再终止此远端会话。", "Host login details changed. Restore the original host before terminating this remote session."))
                }
            }
            try validate(target)
        }
        Task {
            do {
                if terminateRemote {
                    try validateTerminationTarget()
                    let ssh = try await connection(for: target)
                    try validateTerminationTarget()
                    let result = try await performInBackground { try ssh.exec("/bin/sh -c " + RemoteCommands.shellQuote(RemoteCommands.killTmux(record.remoteName))) }
                    guard result.status == 0 else { throw RoamError.transport(String(decoding: result.output, as: UTF8.self)) }
                }
                guard runtimes[record.id] === runtime else { throw RoamError.cancelled }
                runtimes[record.id]?.close(); removeSession(record)
            } catch {
                guard terminateRemote else { self.error = error.localizedDescription; return }
                self.error = text("未能终止远端会话：\(error.localizedDescription)。长按卡片可强制删除", "Could not end the remote session: \(error.localizedDescription). Long-press the card to force delete it")
            }
        }
    }
    func forgetPin(_ host: Host) { do { try store?.forgetPin(endpoint: host.endpoint); notice = text("已移除指纹，下次连接时重新验证", "Fingerprint removed. Verify it on the next connection.") } catch { self.error = error.localizedDescription } }
    private func cancelLaunch(_ id: String) {
        ownerGenerations[id] = UUID()
        sessionTasks.removeValue(forKey: id)?.cancel(); sessionLaunchTokens.removeValue(forKey: id)
        let cancelled = prompts.filter { $0.owner == id }; prompts.removeAll { $0.owner == id }; cancelled.forEach { $0.answer(nil) }
        if authentication?.owner == id { let active = authentication; authentication = prompts.isEmpty ? nil : prompts.removeFirst(); active?.answer(nil) }
    }
    private func credentials(for host: Host, owner: String? = nil, retained: Credentials? = nil, useSavedCredentials: Bool = true) async throws -> Credentials {
        let hostGeneration = generation(for: host.id), ownerGeneration = owner.map { self.ownerGeneration(for: $0) }
        try Task.checkCancellation()
        guard foreground else { throw RoamError.cancelled }
        if useSavedCredentials, let existing = temporaryCredentials[host.id] { return existing }
        var credentials = useSavedCredentials
            ? Credentials(password: invalidCredentialHosts.contains(host.id) ? nil : try vault.read(hostID: host.id, purpose: "password"), privateKey: try vault.read(hostID: host.id, purpose: "key"), passphrase: nil)
            : retained ?? Credentials()
        let originalTarget = useSavedCredentials ? "" : "\(host.username)@\(host.address):\(host.port)\n"
        if host.auth == .password && credentials.password == nil {
            let answer = await ask(title: host.name, message: originalTarget + text("密码仅用于本次连接", "Password is used for this connection"), labels: [text("密码", "Password")], echo: [false], owner: owner)
            guard let password = answer?.first else { throw RoamError.cancelled }
            guard foreground, !Task.isCancelled, isCurrent(hostID: host.id, generation: hostGeneration, owner: owner, ownerGeneration: ownerGeneration) else { throw RoamError.cancelled }
            credentials.password = Data(password.utf8)
        }
        if host.auth == .key && credentials.privateKey == nil {
            throw RoamError.invalid(useSavedCredentials ? text("请编辑主机并导入私钥", "Edit this host and import a private key") : text("原会话的私钥凭据已清除。请恢复原主机并导入它的私钥后重连。", "The original session's private key credentials have expired. Restore the original host and import its key before reconnecting."))
        }
        if host.auth == .key && credentials.passphrase == nil, let key = credentials.privateKey, PrivateKeys.needsPassphrase(key) {
            let answer = await ask(title: host.name, message: originalTarget + text("私钥已加密时请输入口令；未加密可留空。口令仅保存在内存。", "Enter the key passphrase, or leave it blank for an unencrypted key. Passphrases stay in memory only."), labels: [text("私钥口令", "Key passphrase")], echo: [false], owner: owner)
            guard let passphrase = answer?.first else { throw RoamError.cancelled }
            guard foreground, !Task.isCancelled, isCurrent(hostID: host.id, generation: hostGeneration, owner: owner, ownerGeneration: ownerGeneration) else { throw RoamError.cancelled }
            credentials.passphrase = passphrase.isEmpty ? nil : passphrase
        }
        guard foreground, !Task.isCancelled, isCurrent(hostID: host.id, generation: hostGeneration, owner: owner, ownerGeneration: ownerGeneration) else { throw RoamError.cancelled }
        if useSavedCredentials { temporaryCredentials[host.id] = credentials }
        return credentials
    }
    private func makeConnection(_ host: Host, credentials: Credentials, owner: String? = nil) throws -> SSHConnection {
        guard let store else { throw RoamError.invalid("Storage unavailable") }
        let hostGeneration = generation(for: host.id), ownerGeneration = owner.map { self.ownerGeneration(for: $0) }
        return SSHConnection(host: host, credentials: credentials, pinStore: store) { [weak self] prompt in
            let answer = PromptAnswer()
            let id = UUID()
            DispatchQueue.main.async {
                guard let self, self.foreground, self.isCurrent(hostID: host.id, generation: hostGeneration, owner: owner, ownerGeneration: ownerGeneration) else { answer.finish(nil); return }
                let respond: ([String]?) -> Void = { [weak self] values in
                    guard let self, self.foreground, self.isCurrent(hostID: host.id, generation: hostGeneration, owner: owner, ownerGeneration: ownerGeneration) else { answer.finish(nil); return }
                    answer.finish(values)
                }
                var request: AuthenticationRequest
                switch prompt {
                case .verifyHost(let pin):
                    request = AuthenticationRequest(title: self.text("信任这台主机？", "Trust this host?"), message: "\(pin.endpoint)\n\(pin.algorithm)", labels: [], echo: [], fingerprint: pin.fingerprint, answer: respond)
                case .keyboard(let instruction, let labels, let echo):
                    request = AuthenticationRequest(title: host.name, message: instruction, labels: labels, echo: echo, fingerprint: nil, answer: respond)
                }
                request.owner = owner
                self.enqueue(request, token: id)
            }
            if answer.signal.wait(timeout: .now() + 120) == .timedOut { answer.finish(nil) }
            DispatchQueue.main.async { self?.finishPrompt(token: id) }
            return answer.result()
        }
    }
    private var promptTokens: [UUID: UUID] = [:]
    private func enqueue(_ request: AuthenticationRequest, token: UUID) { promptTokens[token] = request.id; if authentication == nil { authentication = request } else { prompts.append(request) } }
    private func finishPrompt(token: UUID) {
        guard let id = promptTokens.removeValue(forKey: token) else { return }
        prompts.removeAll { $0.id == id }
        if authentication?.id == id { authentication = prompts.isEmpty ? nil : prompts.removeFirst() }
    }
    func answerPrompt(_ answer: [String]?) {
        guard let request = authentication else { return }
        request.answer(answer); authentication = prompts.isEmpty ? nil : prompts.removeFirst()
    }
    func ask(title: String, message: String, labels: [String], echo: [Bool], owner: String? = nil) async -> [String]? {
        await withCheckedContinuation { continuation in
            var request = AuthenticationRequest(title: title, message: message, labels: labels, echo: echo, fingerprint: nil) { continuation.resume(returning: $0) }
            request.owner = owner
            if authentication == nil { authentication = request } else { prompts.append(request) }
        }
    }
    private func generation(for hostID: String) -> UUID {
        if let value = hostGenerations[hostID] { return value }
        let value = UUID(); hostGenerations[hostID] = value; return value
    }
    private func ownerGeneration(for owner: String) -> UUID {
        if let value = ownerGenerations[owner] { return value }
        let value = UUID(); ownerGenerations[owner] = value; return value
    }
    private func isCurrent(hostID: String, generation: UUID, owner: String?, ownerGeneration: UUID?) -> Bool {
        guard host(hostID) != nil, hostGenerations[hostID] == generation else { return false }
        return owner.map { ownerGenerations[$0] == ownerGeneration } ?? true
    }
    private func invalidateHostConnections(_ hostID: String) {
        hostGenerations[hostID] = UUID()
        stopMonitor(hostID); cancelLaunch(hostID)
        connectionTokens.removeValue(forKey: hostID)
        connectionTasks.removeValue(forKey: hostID)?.cancel()
        metadataTasks.removeValue(forKey: hostID)?.cancel(); metadataCancellations.removeValue(forKey: hostID)?.cancel()
        if let ssh = connectingSSH.removeValue(forKey: hostID) { disconnectSoon(ssh) }
        if let ssh = connections.removeValue(forKey: hostID) { disconnectSoon(ssh) }
        for record in records where record.hostID == hostID {
            cancelLaunch(record.id)
            if let runtime = runtimes[record.id], runtime.phase.active && runtime.phase != .connected { runtime.close() }
        }
        hostPhases[hostID] = .disconnected
    }
    private func disconnectSoon(_ ssh: SSHConnection) { DispatchQueue.global(qos: .utility).async { ssh.disconnect() } }
    private func moshPreferenceKey(_ recordID: String) -> String { "sessionMosh-" + recordID }
    func connectionTarget(hostID: String, sessionID: String? = nil) -> RemoteConnectionTarget {
        guard let sessionID else { return .host(hostID) }
        let runtime = runtimes[sessionID].flatMap { $0.host.id == hostID ? $0 : nil }
        return .session(sessionID, SessionConnectionSnapshot(session: runtime, connection: runtime?.ssh))
    }
    /// Validates ownership without looking up a replacement host connection.
    func validate(_ target: RemoteConnectionTarget) throws {
        if case .session(let id, let snapshot) = target {
            let current = runtimes[id]
            _ = try snapshot.resolve(currentSession: current, currentConnection: current?.ssh,
                                     connected: current?.phase == .connected && current?.ssh?.isConnected == true)
        }
    }
    func connection(for target: RemoteConnectionTarget) async throws -> SSHConnection {
        try Task.checkCancellation()
        switch target {
        case .host(let id): return try await connection(for: id)
        case .session(let id, let snapshot):
            let current = runtimes[id]
            return try snapshot.resolve(currentSession: current, currentConnection: current?.ssh,
                                        connected: current?.phase == .connected && current?.ssh?.isConnected == true)
        }
    }
    func connection(for hostID: String) async throws -> SSHConnection {
        if let task = connectionTasks[hostID] { return try await task.value }
        if let ssh = connections[hostID], hostPhases[hostID] == .connected, ssh.isConnected { return ssh }
        guard let host = host(hostID) else { throw RoamError.invalid("Host no longer exists") }
        if let stale = connections.removeValue(forKey: hostID) { disconnectSoon(stale) }
        let hostGeneration = generation(for: hostID), ownerGeneration = self.ownerGeneration(for: hostID), token = UUID()
        connectionTokens[hostID] = token
        let task = Task<SSHConnection, Error> {
            let credentials = try await self.credentials(for: host, owner: hostID)
            guard !Task.isCancelled, self.isCurrent(hostID: hostID, generation: hostGeneration, owner: hostID, ownerGeneration: ownerGeneration), self.connectionTokens[hostID] == token else { throw RoamError.cancelled }
            let ssh = try self.makeConnection(host, credentials: credentials, owner: hostID)
            self.connectingSSH[hostID] = ssh
            ssh.onPhase = { [weak self] phase in
                DispatchQueue.main.async {
                    guard let self, self.connectionTokens[hostID] == token, self.isCurrent(hostID: hostID, generation: hostGeneration, owner: hostID, ownerGeneration: ownerGeneration) else { return }
                    self.hostPhases[hostID] = phase
                }
            }
            do {
                try await performInBackground { try ssh.connect() }
                guard !Task.isCancelled, self.connectionTokens[hostID] == token, self.isCurrent(hostID: hostID, generation: hostGeneration, owner: hostID, ownerGeneration: ownerGeneration) else { throw RoamError.cancelled }
                self.connections[hostID] = ssh
                self.hostPhases[hostID] = .connected
                self.detectMetadata(host: host, ssh: ssh, hostGeneration: hostGeneration, ownerGeneration: ownerGeneration, token: token)
                return ssh
            } catch { self.disconnectSoon(ssh); throw error }
        }
        connectionTasks[hostID] = task
        defer { if connectionTokens[hostID] == token { connectionTasks.removeValue(forKey: hostID); connectingSSH.removeValue(forKey: hostID) } }
        do { return try await task.value }
        catch {
            if connectionTokens[hostID] == token, isCurrent(hostID: hostID, generation: hostGeneration, owner: hostID, ownerGeneration: ownerGeneration), (error as? RoamError) == .authentication {
                temporaryCredentials[hostID]?.clear(); temporaryCredentials.removeValue(forKey: hostID); invalidCredentialHosts.insert(hostID)
            }
            throw error
        }
    }
    private func detectMetadata(host: Host, ssh: SSHConnection, hostGeneration: UUID, ownerGeneration: UUID, token: UUID) {
        metadataTasks[host.id]?.cancel(); metadataCancellations[host.id]?.cancel()
        let cancellation = TransferCancellation()
        metadataCancellations[host.id] = cancellation
        metadataTasks[host.id] = Task { [weak self] in
            await withTaskCancellationHandler(operation: {
                guard let self else { return }
                defer { if self.connectionTokens[host.id] == token { self.metadataTasks.removeValue(forKey: host.id); self.metadataCancellations.removeValue(forKey: host.id) } }
                @MainActor func current() -> Bool { !Task.isCancelled && self.connectionTokens[host.id] == token && self.connections[host.id] === ssh && self.isCurrent(hostID: host.id, generation: hostGeneration, owner: host.id, ownerGeneration: ownerGeneration) }
                do {
                    guard current() else { return }
                    let pluginResult = try await performInBackground { try ssh.exec(HostPluginProbe.command, input: Data(HostPluginProbe.script.utf8), timeout: 8, cancellation: cancellation) }
                    guard current() else { return }
                    if let plugins = HostPluginProbe.parse(String(decoding: pluginResult.output, as: UTF8.self)), let latest = self.host(host.id) {
                        self.updateMetadata(host: host, plugins: plugins.map(\.rawValue).sorted(), system: latest.system)
                    }
                    let unix = try await performInBackground { try ssh.exec(HostSystemProbe.command, input: Data(HostSystemProbe.script.utf8), timeout: 8, cancellation: cancellation) }
                    guard current() else { return }
                    var system = HostSystemProbe.parse(unix: String(decoding: unix.output, as: UTF8.self))
                    if system == .UNKNOWN {
                        let windows = try await performInBackground { try ssh.exec(HostSystemProbe.windowsCommand, input: Data(), timeout: 8, cancellation: cancellation) }
                        guard current() else { return }
                        system = HostSystemProbe.parse(unix: nil, windows: String(decoding: windows.output, as: UTF8.self))
                    }
                    if system != .UNKNOWN, let latest = self.host(host.id) { self.updateMetadata(host: host, plugins: latest.plugins, system: system.rawValue) }
                } catch { /* Metadata probes are optional; an authenticated terminal remains usable. */ }
            }, onCancel: { cancellation.cancel() })
        }
    }
    func startMonitor(_ host: Host, interactive: Bool = false) {
        guard foreground, monitorTasks[host.id] == nil else { return }
        let hasSecret = connections[host.id]?.isConnected == true || host.auth != .password || (try? vault.read(hostID: host.id, purpose: "password")) != nil || temporaryCredentials[host.id] != nil
        guard interactive || hasSecret else { return }
        let token = UUID(), cancellation = TransferCancellation()
        monitorTokens[host.id] = token; monitorCancellations[host.id] = cancellation
        monitorStates[host.id] = HostMonitorState(phase: .connecting)
        monitorTasks[host.id] = Task { [weak self] in
            guard let self else { return }
            @MainActor func current() -> Bool { !Task.isCancelled && !cancellation.isCancelled && self.foreground && self.monitorTokens[host.id] == token }
            defer {
                if self.monitorTokens[host.id] == token {
                    self.monitorTasks.removeValue(forKey: host.id); self.monitorTokens.removeValue(forKey: host.id); self.monitorCancellations.removeValue(forKey: host.id)
                }
            }
            var retry = 0
            while current() {
                var samplingConnection: SSHConnection?
                do {
                    let ssh = try await self.connection(for: host.id)
                    guard current() else { return }
                    samplingConnection = ssh
                    self.monitorStates[host.id] = HostMonitorState(phase: .connected)
                    var series = self.metricSeries[host.id] ?? HostMetricSeries()
                    series.resetNetworkBaseline()
                    while current() {
                        let result = try await performInBackground { try ssh.exec("/bin/sh -c " + RemoteCommands.shellQuote(HostMetrics.script), input: Data(), timeout: 10, cancellation: cancellation) }
                        guard current() else { return }
                        let value = HostMetrics.parse(String(decoding: result.output, as: UTF8.self))
                        // The collectors ran but returned nothing usable: the host refused the queries. A lost login
                        // (timeout, dropped connection) throws instead and reconnects, keeping the last sample.
                        guard result.status == 0, value.cpuPercent != nil || value.memPercent != nil || !value.disks.isEmpty else {
                            self.metrics.removeValue(forKey: host.id); series.resetNetworkBaseline(); self.metricSeries[host.id] = series
                            self.monitorStates[host.id] = HostMonitorState(phase: .connected, samplingFailed: true)
                            return
                        }
                        series.observe(value, timestamp: ProcessInfo.processInfo.systemUptime)
                        self.metrics[host.id] = value
                        self.metricSeries[host.id] = series
                        self.monitorStates[host.id] = HostMonitorState(phase: .connected, sampled: true)
                        retry = 0
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                } catch {
                    guard current() else { return }
                    // A channel can observe cancellation after another channel detected a dead socket.
                    // Only that established, dead connection is retryable; cancelling authentication is not.
                    let failure: Error = (error as? RoamError) == .cancelled && samplingConnection?.isConnected == false
                        ? RoamError.transport(self.text("监控连接已关闭", "Monitor connection closed")) : error
                    retry += 1
                    guard let delay = HostMonitorRetry.delay(after: failure, attempt: retry, interactive: host.auth == .interactive) else {
                        self.monitorStates[host.id] = HostMonitorState(phase: HostMonitorRetry.phase(after: failure), detail: failure.localizedDescription)
                        return
                    }
                    self.monitorStates[host.id] = HostMonitorState(phase: .connecting, reconnecting: true, detail: failure.localizedDescription)
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                }
            }
        }
    }
    func stopMonitor(_ id: String) {
        monitorCancellations.removeValue(forKey: id)?.cancel(); monitorTasks.removeValue(forKey: id)?.cancel(); monitorTokens.removeValue(forKey: id)
        if monitorStates[id]?.phase.active == true { monitorStates[id] = HostMonitorState(phase: .disconnected) }
    }
    func probeHosts(_ hosts: [Host]) async {
        for host in hosts where reachability[host.id] == nil { reachability[host.id] = .checking }
        await withTaskGroup(of: (String, HostReachability).self) { group in
            for host in hosts { group.addTask { (host.id, await ReachabilityProbe.measure(address: host.hostname, port: host.port)) } }
            for await (id, result) in group { if !Task.isCancelled, self.host(id) != nil { reachability[id] = result; reachabilityCheckedAt[id] = Date() } }
        }
    }
    /// A host whose login needs nothing typed: a saved password, a key without a passphrase, or a login still cached.
    func canLoginSilently(_ host: Host) -> Bool {
        if temporaryCredentials[host.id] != nil { return true }
        switch host.auth {
        case .password: return !invalidCredentialHosts.contains(host.id) && (try? vault.read(hostID: host.id, purpose: "password")) != nil
        case .key: return savedKey(host.id).map { !PrivateKeys.needsPassphrase($0) } ?? false
        case .interactive: return false
        }
    }
    /// A live session to the same endpoint already shows the host is up, without probing it.
    func hostConnected(_ host: Host) -> Bool {
        runtimes.values.contains { $0.host.id == host.id && $0.host.address == host.address && $0.host.port == host.port && $0.phase == .connected }
    }
    /// Shown on a session's card while it waits for its host: the last probe found sshd silent.
    func hostOffline(_ record: SessionRecord) -> Bool {
        guard let host = host(record.hostID), runtimes[record.id]?.phase.active != true, !hostConnected(host) else { return false }
        if case .offline = reachability[host.id] { return true }
        return false
    }
    /// Why a session's terminal is down; one with no runtime came back from the journal.
    func sessionEnd(_ record: SessionRecord) -> SessionEnd? { runtimes[record.id].map { $0.phase.active ? nil : $0.end } ?? .restored }
    /// Opening a dropped or restored terminal reconnects it, at most once per `SessionReconnect.interval`.
    func reconnectOnOpen(_ record: SessionRecord) async {
        guard SessionReconnect.onOpen(sessionEnd(record)) else { return }
        let wait = SessionReconnect.delay(lastAttempt: autoReconnectedAt[record.id], now: Date())
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        guard !Task.isCancelled, foreground, records.contains(record), SessionReconnect.onOpen(sessionEnd(record)) else { return }
        autoReconnectedAt[record.id] = Date()
        reconnect(record)
    }
    func beginSessionListVisit() { retriedThisVisit = [] }
    /// While the session list is on screen, sessions that dropped, came back from the journal or lost the network
    /// reconnect by themselves: only on hosts that need nothing typed, and only once the host answers again.
    func reconnectFromList() {
        guard foreground else { return }
        let now = Date()
        for record in records {
            guard let host = host(record.hostID), canLoginSilently(host), !retriedThisVisit.contains(record.id) else { continue }
            let end = sessionEnd(record)
            guard SessionReconnect.fromList(end), SessionReconnect.delay(lastAttempt: autoReconnectedAt[record.id], now: now) == 0 else { continue }
            // An offline host is left alone, not retried on every visit: a fresh probe must find its sshd first.
            if !hostConnected(host) {
                let since: Date
                if let waiting = waitingForHostSince[record.id] { since = waiting }
                else { since = now; waitingForHostSince[record.id] = now; Task { await probeHosts([host]) } }
                let online: Bool = { if case .online = reachability[host.id] { return true }; return false }()
                guard SessionReconnect.hostBack(online: online, checkedAt: reachabilityCheckedAt[host.id], since: since) else { continue }
            }
            waitingForHostSince.removeValue(forKey: record.id)
            // A host still out of reach is tried once per visit, not every few seconds.
            if !SessionReconnect.onOpen(end) { retriedThisVisit.insert(record.id) }
            autoReconnectedAt[record.id] = now
            if runtimes[record.id] == nil { connectSession(record) } else { reconnect(record) }
        }
    }
    /// Presents `next` once the sheet on screen has gone.
    func replaceSheet(with next: AppSheet) {
        sheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.sheet = next }
    }
    func saveCommand(_ command: String) {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        commands.removeAll { $0 == value }; commands.insert(value, at: 0); commands = Array(commands.prefix(100)); UserDefaults.standard.set(commands, forKey: "commonCommands")
    }
    func removeCommand(_ command: String) { commands.removeAll { $0 == command }; UserDefaults.standard.set(commands, forKey: "commonCommands") }
    private func restartVisibleMonitor() {
        guard foreground, case .host(let id) = path.last, let host = host(id) else { return }
        startMonitor(host)
    }
    func resume() {
        foreground = true
        for runtime in runtimes.values { runtime.probe() }
        restartVisibleMonitor()
        let existing = Set(incomingFiles + files.pendingUploadURLs).union(files.activeUploadURLs)
        incomingFiles.append(contentsOf: SharedInbox.consume().filter { !existing.contains($0) })
    }
    func suspend() {
        foreground = false
        for id in Array(monitorTasks.keys) { stopMonitor(id) }
        for id in Array(temporaryCredentials.keys) { temporaryCredentials[id]?.clear() }; temporaryCredentials.removeAll()
        for runtime in runtimes.values { runtime.clearLoginCredentials() }
        if let request = authentication { request.answer(nil) }; prompts.forEach { $0.answer(nil) }; prompts = []; authentication = nil
    }
}
func performInBackground<T>(_ operation: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try operation() }) } }
}
