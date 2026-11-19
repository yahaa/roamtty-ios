import Foundation
import RoamttyCore
import RoamttyTransport

/// Logins: the saved and typed credentials of each host, the questions a login asks the user, and the tokens that
/// tell whether a login under way is still wanted.
@MainActor final class HostLogins: ObservableObject {
    /// Login questions waiting for the user; `prompts.active` is the one on screen.
    @Published private(set) var prompts = PromptQueue()
    /// Passwords and keys saved on this device.
    let vault = SecretVault()
    /// Logins typed or unlocked during this run.
    private var cache = CredentialCache()
    private var generations = ConnectionGenerations()
    private unowned let environment: ConnectionEnvironment

    init(environment: ConnectionEnvironment) { self.environment = environment }

    // MARK: Staleness

    /// Marks the start of work for `host` on behalf of `owner`: a session, or a host's tools.
    func attempt(host: String, owner: String?) -> ConnectionAttempt { generations.attempt(host: host, owner: owner) }
    /// Whether the host still exists and neither it nor the attempt's owner moved on since the attempt started.
    func isCurrent(_ attempt: ConnectionAttempt) -> Bool { environment.host(attempt.host) != nil && generations.isCurrent(attempt) }
    /// Makes everything started for the host stale.
    func invalidateHost(_ hostID: String) { generations.invalidateHost(hostID) }
    /// Makes everything started for the owner stale.
    func invalidateOwner(_ owner: String) { generations.invalidateOwner(owner) }
    /// The generation a view's work for the host, or for one owner of a login, started at.
    func hostGeneration(_ hostID: String) -> UUID { generations.host(hostID) }
    func ownerGeneration(_ owner: String) -> UUID { generations.owner(owner) }

    // MARK: Credentials

    private func savedKey(_ hostID: String) -> Data? { try? vault.read(hostID: hostID, purpose: .key) }
    /// The password of the login in memory, for a tool on the host that asks for it again (sudo).
    func loginPassword(for hostID: String) -> String? { cache[hostID]?.password.flatMap { String(data: $0, encoding: .utf8) } }
    /// A host whose login needs nothing typed: a saved password, a key without a passphrase, or a login still cached.
    func canLoginSilently(_ host: Host) -> Bool {
        if cache[host.id] != nil { return true }
        switch host.auth {
        case .password: return !cache.savedPasswordRejected(host.id) && (try? vault.read(hostID: host.id, purpose: .password)) != nil
        case .key: return savedKey(host.id).map { !PrivateKeys.needsPassphrase($0) } ?? false
        case .interactive: return false
        }
    }
    /// Whether a login could start without asking for a password first: the host uses none, or has one saved or in memory.
    func hasLoginSecret(_ host: Host) -> Bool {
        host.auth != .password || (try? vault.read(hostID: host.id, purpose: .password)) != nil || cache[host.id] != nil
    }
    /// The host refused its login: forget it, and stop offering its saved password until the host is edited.
    func rejectLogin(_ hostID: String) { cache.rejectLogin(hostID) }
    /// Wipes the host's login in memory.
    func forget(_ hostID: String) { cache.forget(hostID) }
    /// Wipes every login in memory.
    func forgetAll() { cache.forgetAll() }
    /// The host was edited: its login in memory goes, its saved password is offered again, and what the editor
    /// typed (`typed`, if anything) is the login to use next.
    func hostEdited(_ hostID: String, typed: Credentials?) {
        cache.forget(hostID)
        cache.acceptSavedPassword(hostID)
        if let typed { cache.store(typed, for: hostID) }
    }

    /// The login for `host`: cached, saved, or asked for. A session kept on its original login passes the
    /// `retained` credentials and does not touch the saved ones. `asking: false` fails instead of asking.
    func credentials(for host: Host, owner: String? = nil, retained: Credentials? = nil, useSavedCredentials: Bool = true, asking: Bool = true) async throws -> Credentials {
        let attempt = generations.attempt(host: host.id, owner: owner)
        try Task.checkCancellation()
        guard environment.foreground else { throw RoamError.cancelled }
        if useSavedCredentials, let existing = cache[host.id] { return existing }
        var credentials = useSavedCredentials
            ? Credentials(password: cache.savedPasswordRejected(host.id) ? nil : try vault.read(hostID: host.id, purpose: .password),
                privateKey: try vault.read(hostID: host.id, purpose: .key), passphrase: nil)
            : retained ?? Credentials()
        let originalTarget = useSavedCredentials ? "" : "\(host.username)@\(host.address):\(host.port)\n"
        let text = environment.text
        func stillWanted() -> Bool { environment.foreground && !Task.isCancelled && isCurrent(attempt) }
        if host.auth == .password && credentials.password == nil {
            let password = try await typed(asking, title: host.name, message: originalTarget + text("密码仅用于本次连接", "Password is used for this connection"),
                                           label: text("密码", "Password"), owner: owner)
            guard stillWanted() else { throw RoamError.cancelled }
            credentials.password = Data(password.utf8)
        }
        if host.auth == .key && credentials.privateKey == nil {
            throw RoamError.invalid(useSavedCredentials ? text("请编辑主机并导入私钥",
                "Edit this host and import a private key") : text("原会话的私钥凭据已清除。请恢复原主机并导入它的私钥后重连。",
                "The original session's private key credentials have expired. Restore the original host and import its key before reconnecting."))
        }
        if host.auth == .key && credentials.passphrase == nil, let key = credentials.privateKey, PrivateKeys.needsPassphrase(key) {
            let passphrase = try await typed(asking, title: host.name,
                message: originalTarget + text("私钥已加密时请输入口令；未加密可留空。口令仅保存在内存。", "Enter the key passphrase, or leave it blank for an unencrypted key. Passphrases stay in memory only."),
                label: text("私钥口令", "Key passphrase"), owner: owner)
            guard stillWanted() else { throw RoamError.cancelled }
            credentials.passphrase = passphrase.isEmpty ? nil : passphrase
        }
        guard stillWanted() else { throw RoamError.cancelled }
        if useSavedCredentials { cache.store(credentials, for: host.id) }
        return credentials
    }

    /// One secret typed by the user; cancelled when asking is not allowed or the user backs out.
    private func typed(_ asking: Bool, title: String, message: String, label: String, owner: String?) async throws -> String {
        guard asking else { throw RoamError.cancelled }
        guard let answer = await ask(title: title, message: message, labels: [label], echo: [false], owner: owner)?.first else { throw RoamError.cancelled }
        return answer
    }

    // MARK: Questions for the user

    /// Answers the question on screen and shows the next one waiting.
    func answerPrompt(_ answer: [String]?) {
        guard let request = prompts.active else { return }
        request.answer(answer); prompts.showNext()
    }
    private func ask(title: String, message: String, labels: [String], echo: [Bool], owner: String? = nil) async -> [String]? {
        await withCheckedContinuation { continuation in
            var request = AuthenticationRequest(title: title, message: message, labels: labels, echo: echo, fingerprint: nil) { continuation.resume(returning: $0) }
            request.owner = owner
            prompts.present(request)
        }
    }
    /// Takes down the questions `owner`'s login asked, unanswered.
    func dismissPrompts(owner: String) {
        if prompts.contains(owner: owner) { prompts.removeAll(owner: owner).forEach { $0.answer(nil) } }
    }
    /// Takes down every question, unanswered.
    func dismissAllPrompts() { prompts.removeAll().forEach { $0.answer(nil) } }

    // MARK: Connections

    /// A connection whose host-key and keyboard-interactive questions go to the user while the attempt is current.
    func makeConnection(_ host: Host, credentials: Credentials, owner: String? = nil) throws -> SSHConnection {
        guard let pinStore = environment.pinStore else { throw RoamError.invalid("Storage unavailable") }
        let attempt = generations.attempt(host: host.id, owner: owner)
        return SSHConnection(host: host, credentials: credentials, pinStore: pinStore) { [weak self] prompt in
            let answer = PromptAnswer()
            let id = UUID()
            DispatchQueue.main.async {
                guard let self, self.environment.foreground, self.isCurrent(attempt) else { answer.finish(nil); return }
                let respond: ([String]?) -> Void = { [weak self] values in
                    guard let self, self.environment.foreground, self.isCurrent(attempt) else { answer.finish(nil); return }
                    answer.finish(values)
                }
                var request: AuthenticationRequest
                switch prompt {
                case .verifyHost(let pin):
                    request = AuthenticationRequest(title: self.environment.text("信任这台主机？", "Trust this host?"), message: "\(pin.endpoint)\n\(pin.algorithm)",
                        labels: [], echo: [], fingerprint: pin.fingerprint, answer: respond)
                case .keyboard(let instruction, let labels, let echo):
                    request = AuthenticationRequest(title: host.name, message: instruction, labels: labels, echo: echo, fingerprint: nil, answer: respond)
                }
                request.owner = owner
                self.prompts.present(request, token: id)
            }
            if answer.signal.wait(timeout: .now() + 120) == .timedOut { answer.finish(nil) }
            DispatchQueue.main.async { self?.prompts.withdraw(token: id) }
            return answer.result()
        }
    }
}
