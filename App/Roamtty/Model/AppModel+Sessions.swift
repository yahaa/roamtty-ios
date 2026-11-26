import Foundation
import RoamttyCore
import RoamttyTransport

/// Terminal sessions: launching, connecting and closing them. What the lists show of them is in
/// `AppModel+SessionList`, reconnecting by themselves in `AppModel+SessionReconnect`.
extension AppModel {
    func persistJournal() { records = journal.records; do { try store?.saveJournal(journal) } catch { self.error = error.localizedDescription } }

    // MARK: Opening and launching

    /// Opens a session's terminal from the home page; leaving it returns to the sessions tab.
    func openSession(_ record: SessionRecord) {
        // Publish only the destination, not an intermediate visit to the host underneath the terminal.
        var next = path
        if case .terminal = next.last { next.removeLast() }
        next.append(.terminal(record.id))
        path = next
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
            guard StartDirectory.isSupported(directory), agent.map({ StartDirectory.isSupported($0.directory) }) ?? true else {
                throw RoamError.invalid(text("文件夹路径含有不支持的控制字符", "The folder path contains unsupported control characters"))
            }
            let directory = StartDirectory.normalize(directory)
            let record = try journal.create(hostID: host.id, mode: mode, title: agent?.title ?? "")
            showNewTerminal(record)
            connectSession(record, directory: directory, agent: agent, preferMosh: mosh, originalLogin: originalLogin)
        } catch { self.error = error.localizedDescription }
    }
    /// Attaches a tmux session that was already on the server; one this app already holds opens its card instead.
    func attachExisting(_ host: Host, name: String, mosh: Bool?) {
        if let record = records.first(where: { $0.hostID == host.id && $0.mode == .tmux && $0.remoteName == name }) {
            sheet = nil; openSession(record); return
        }
        do {
            let record = try journal.create(hostID: host.id, mode: .tmux, title: name, external: name)
            showNewTerminal(record)
            connectSession(record, preferMosh: mosh)
        } catch { self.error = error.localizedDescription }
    }
    /// Saves a new session and shows its terminal. One started from its host's page returns there; one started from
    /// the home page returns home.
    private func showNewTerminal(_ record: SessionRecord) {
        persistJournal(); sheet = nil
        let host = AppRoute.host(record.hostID)
        path = path.first == host ? [host, .terminal(record.id)] : [.terminal(record.id)]
    }
    func reconnect(_ record: SessionRecord, shell: Bool = false) {
        guard let host = host(record.hostID) else { return }
        let originalLogin = runtimes[record.id]?.loginSnapshot
        if shell { launch(host, mode: .shell, directory: "~", agent: nil, mosh: false, originalLogin: originalLogin) } else {
            runtimes[record.id]?.clearLoginCredentials(); runtimes.removeValue(forKey: record.id)?.discard()
            connectSession(record, originalLogin: originalLogin)
        }
    }
    /// Gives the session a fresh runtime and logs it in. `originalLogin` keeps a session on the login it was opened
    /// with after its host was edited.
    func connectSession(_ record: SessionRecord, directory: String = "~", agent: AgentLaunch? = nil, preferMosh: Bool? = nil, originalLogin: SessionLoginSnapshot? = nil) {
        guard let savedHost = host(record.hostID) else { return }
        let host = originalLogin?.reconnect(using: savedHost).host ?? savedHost
        let usesSavedCredentials = host.hasSameLoginIdentity(as: savedHost)
        cancelLaunch(record.id)
        let attempt = logins.attempt(host: host.id, owner: record.id)
        let preference = preferMosh ?? MoshPreference.value(record.id) ?? (savedHost.plugins?.contains("mosh") == true)
        if let preferMosh { MoshPreference.set(preferMosh, for: record.id) }
        let runtime = SessionRuntime(record: record, host: host, loginSnapshot: originalLogin)
        runtime.onFailure = { [weak self, weak runtime] failure in
            guard let self, let runtime, self.runtimes[record.id] === runtime, self.logins.isCurrent(attempt) else { return }
            if usesSavedCredentials, let current = self.host(host.id), host.hasSameLoginIdentity(as: current), (failure as? RoamError) == .authentication {
                self.logins.rejectLogin(host.id)
            }
        }
        // Only a login that needs no answer from the user: it runs in the background, from the status poll.
        runtime.reopenSideConnection = { [weak self, weak runtime] in
            guard let self, let runtime, host.auth != .interactive, self.runtimes[record.id] === runtime, self.logins.isCurrent(attempt) else { throw RoamError.cancelled }
            let retained = runtime.loginSnapshot.reconnect(using: savedHost).retainedCredentials
            let creds = try await self.logins.credentials(for: host, owner: record.id, retained: retained, useSavedCredentials: usesSavedCredentials, asking: false)
            let ssh = try self.logins.makeConnection(host, credentials: creds, owner: record.id)
            do { try await ssh.connectInBackground() } catch { ssh.disconnectInBackground(); throw error }
            return ssh
        }
        runtime.onAgentReport = { [weak self, weak runtime] previous, current in
            guard let self, let runtime, self.runtimes[record.id] === runtime else { return }
            self.agentReported(runtime, previous: previous, current: current)
        }
        runtimes.updateValue(runtime, forKey: record.id)?.discard()
        sessionSubscriptions[record.id] = runtime.summaryWillChange.sink { [weak self] in self?.objectWillChange.send() }
        objectWillChange.send()
        Diagnostics.shared.log("connect", "sessions=\(runtimes.count) terminals=\(TerminalCensus.live)")
        let token = UUID()
        let task = Task {
            defer { if sessionLaunches[record.id]?.token == token { sessionLaunches.removeValue(forKey: record.id) } }
            do {
                let retained = runtime.loginSnapshot.reconnect(using: savedHost).retainedCredentials
                let creds = try await logins.credentials(for: host, owner: record.id, retained: retained, useSavedCredentials: usesSavedCredentials)
                guard foreground else { throw RoamError.cancelled }
                guard !Task.isCancelled, sessionLaunches[record.id]?.token == token, runtimes[record.id] === runtime, runtime.phase.active, logins.isCurrent(attempt) else { return }
                let ssh = try logins.makeConnection(host, credentials: creds, owner: record.id)
                runtime.connect(ssh: ssh, credentials: creds, preferMosh: preference, directory: directory, agent: agent)
            } catch { if logins.isCurrent(attempt), runtimes[record.id] === runtime { runtime.fail(error) } }
        }
        sessionLaunches[record.id] = TrackedTask(token: token, task: task)
    }
    /// Stops a login under way for `id` (a session, or a host's tools) and drops the questions it asked.
    func cancelLaunch(_ id: String) {
        logins.invalidateOwner(id)
        sessionLaunches.removeValue(forKey: id)?.cancel()
        logins.dismissPrompts(owner: id)
    }

    // MARK: Closing

    /// Ends a session outright, without asking: a connected tmux session is killed on the server over its live
    /// connection and its card goes once that worked; a disconnected one logs in to kill it. A connecting one only stops connecting.
    /// A tmux session that was already on the server is only detached: its card goes and the session keeps running.
    func closeSession(_ record: SessionRecord) {
        if path.last == .terminal(record.id) { leaveTerminal() }
        let runtime = runtimes[record.id]
        runtime?.voice.shutdown()
        guard record.mode == .tmux && !record.external else {
            cancelLaunch(record.id); runtime?.close(); removeSession(record); return
        }
        if let runtime, runtime.phase == .connected {
            // The card goes only once the server ended the session, so a failure leaves it there to try again.
            cancelLaunch(record.id)
            Task {
                guard await runtime.killRemoteSession() else {
                    error = text("未能终止远端会话，请检查连接后重试；长按卡片可强制删除", "Couldn't end the remote session. Check the connection and try again, or long-press the card to force delete it")
                    return
                }
                guard records.contains(where: { $0.id == record.id }) else { return }
                removeSession(record)
            }
        } else if let runtime, runtime.phase.active {
            cancelLaunch(record.id); runtime.close()
        } else {
            terminateSession(record)
        }
    }
    /// 强制删除: the card goes at once, whatever the host does. Its tmux session is then ended on the server over a
    /// connection of its own, with the login the card already has and without asking anything; one the host could not
    /// end keeps running, and the user is told.
    /// Names a card on this device; blank gives it back its automatic name. The open terminal's switcher names it too.
    func renameSession(_ id: String, to name: String) {
        journal.rename(id, to: name); persistJournal()
        if let renamed = records.first(where: { $0.id == id }) { runtimes[id]?.record.name = renamed.name }
    }
    func forceDeleteSession(_ record: SessionRecord) {
        if path.last == .terminal(record.id) { leaveTerminal() }
        // Taken before the card goes, which clears a session's own login.
        let login = host(record.hostID).map { runtimes[record.id]?.loginSnapshot.reconnect(using: $0) ?? SessionLoginSnapshot(host: $0).reconnect(using: $0) }
        cancelLaunch(record.id); removeSession(record)
        guard record.mode == .tmux && !record.external, let login else { return }
        Task {
            do {
                let creds = try await logins.credentials(for: login.host, retained: login.retainedCredentials, useSavedCredentials: login.usesSavedCredentials, asking: false)
                let ssh = try logins.makeConnection(login.host, credentials: creds)
                defer { ssh.disconnectInBackground() }
                try await ssh.connectInBackground()
                let result = try await ssh.run(RemoteCommands.shell(RemoteCommands.killTmux(record.remoteName)), timeout: 15)
                guard result.status == 0 else { throw RoamError.transport(result.text) }
            } catch {
                let reason = (error as? RoamError) == .cancelled ? text("没有已保存的登录信息", "no saved login") : error.localizedDescription
                self.error = text("会话卡片已移除，但未能终止远端 tmux 会话：\(reason)", "The card is gone, but the remote tmux session could not be ended: \(reason)")
            }
        }
    }
    /// A tmux session restarts its pane over the live connection; a plain shell gets a fresh one by reconnecting.
    func restartSession(_ record: SessionRecord) {
        guard record.mode == .tmux, let runtime = runtimes[record.id] else { reconnect(record); return }
        Task { if !(await runtime.restartPane()) { error = text("未能重启会话，请检查连接后重试", "Couldn't restart the session. Check the connection and try again.") } }
    }
    /// Logs in to end a disconnected tmux session on the server; its card goes once that worked.
    func terminateSession(_ record: SessionRecord) {
        let runtime = runtimes[record.id]
        // Restored/disconnected cards can connect on request. A live card always owns
        // its existing connection; closing/replacing it while queued must not retarget.
        let target: RemoteConnectionTarget
        if let runtime, runtime.phase == .connected { target = .session(runtime) } else { target = .host(record.hostID) }
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
                try validateTerminationTarget()
                let ssh = try await connection(for: target)
                try validateTerminationTarget()
                let result = try await ssh.run(RemoteCommands.shell(RemoteCommands.killTmux(record.remoteName)))
                guard result.status == 0 else { throw RoamError.transport(result.text) }
                guard runtimes[record.id] === runtime else { throw RoamError.cancelled }
                runtimes[record.id]?.close(); removeSession(record)
            } catch {
                self.error = text("未能终止远端会话：\(error.localizedDescription)。长按卡片可强制删除", "Could not end the remote session: \(error.localizedDescription). Long-press the card to force delete it")
            }
        }
    }
    private func removeSession(_ record: SessionRecord) {
        dropRuntime(record.id)
        autoReconnectedAt.removeValue(forKey: record.id); waitingForHostSince.removeValue(forKey: record.id)
        journal.forget(record.id); persistJournal()
    }
    /// Lets go of a session's runtime for good: its login, its terminal, its updates and its transport choice.
    func dropRuntime(_ id: String) {
        runtimes[id]?.clearLoginCredentials()
        runtimes.removeValue(forKey: id)?.discard()
        sessionSubscriptions.removeValue(forKey: id)
        MoshPreference.forget(id)
        AgentStatusMemory.set(nil, for: id)
        AgentNotifier.shared.withdraw(id)
    }
}
