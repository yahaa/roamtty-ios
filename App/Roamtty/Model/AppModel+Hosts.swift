import Foundation
import RoamttyCore

/// Saved hosts: editing and deleting them, their stored secrets, and what the session list reads of them.
extension AppModel {
    func host(_ id: String) -> Host? { hosts.first { $0.id == id } }

    /// Navigation records user intent; background probes and automatic reconnects never change recency.
    func recordHostUse(for route: AppRoute) {
        let hostID: String
        switch route {
        case .host(let id), .desktop(let id), .files(let id, _, _): hostID = id
        case .terminal(let sessionID):
            guard let record = records.first(where: { $0.id == sessionID }) else { return }
            hostID = record.hostID
        }
        guard let store, var current = host(hostID) else { return }
        current.lastUsedAt = Date()
        do {
            try store.saveHost(current)
            hosts = try store.hosts()
        } catch { self.error = error.localizedDescription }
    }

    func saveHost(_ host: Host, password: String, key: Data?, passphrase: String) throws {
        guard let store else { throw RoamError.invalid(text("存储不可用", "Storage unavailable")) }
        var validated = try host.validated()
        let previousHost = self.host(host.id)
        // An editor may have been opened before the latest visit; keep the current usage time.
        validated.lastUsedAt = previousHost?.lastUsedAt
        let vault = logins.vault
        let previousPassword = try vault.read(hostID: host.id, purpose: .password)
        let previousKey = try vault.read(hostID: host.id, purpose: .key)
        let nextKey = key ?? previousKey
        if validated.auth == .key && nextKey == nil { throw RoamError.invalid(text("请选择 SSH 私钥", "Choose an SSH private key")) }
        let nextPassword = validated.savePassword ? (password.isEmpty ? previousPassword : Data(password.utf8)) : nil
        var passwordChanged = false, keyChanged = false
        do {
            if nextPassword != previousPassword { try vault.save(data: nextPassword, hostID: host.id, purpose: .password); passwordChanged = true }
            if nextKey != previousKey { try vault.save(data: nextKey, hostID: host.id, purpose: .key); keyChanged = true }
            // The database row is committed only after its credentials are available.
            try store.saveHost(validated)
        } catch {
            let original = error
            do {
                if passwordChanged { try vault.save(data: previousPassword, hostID: host.id, purpose: .password) }
                if keyChanged { try vault.save(data: previousKey, hostID: host.id, purpose: .key) }
            } catch {
                throw RoamError.invalid(original.localizedDescription + text("；凭据恢复失败：", "; credential recovery failed: ") + error.localizedDescription)
            }
            throw original
        }
        let changesConnection = previousHost?.hasSameLoginIdentity(as: validated) != true
            || nextPassword != previousPassword || nextKey != previousKey || !password.isEmpty || !passphrase.isEmpty
        if changesConnection {
            invalidateHostConnections(host.id)
            let typed = password.isEmpty && passphrase.isEmpty ? nil
                : Credentials(password: password.isEmpty ? nextPassword : Data(password.utf8), privateKey: nextKey, passphrase: passphrase.isEmpty ? nil : passphrase)
            logins.hostEdited(host.id, typed: typed)
        }
        hosts = try store.hosts()
        if changesConnection { restartVisibleMonitor() }
    }
    /// Records what a probe found on the host, unless the host was pointed elsewhere meanwhile.
    func updateMetadata(host previous: Host, plugins: [String]?, system: String) {
        guard var current = host(previous.id), current.address == previous.address, current.port == previous.port, current.username == previous.username else { return }
        current.plugins = plugins; current.system = system
        do { try store?.saveHost(current); if let index = hosts.firstIndex(where: { $0.id == current.id }) { hosts[index] = current } } catch { self.error = error.localizedDescription }
    }
    func deleteHost(_ host: Host) {
        do {
            invalidateHostConnections(host.id)
            for record in records where record.hostID == host.id { cancelLaunch(record.id); dropRuntime(record.id) }
            logins.forget(host.id)
            try logins.vault.remove(hostID: host.id); try store?.deleteHost(id: host.id)
            closeDesktop(host.id)
            desktopThumbnails.remove(host.id)
            monitor.forget(host.id)
            journal.removeHost(host.id); persistJournal(); hosts.removeAll { $0.id == host.id }; path = []
        } catch { self.error = error.localizedDescription }
    }
    func forgetPin(_ host: Host) {
        do {
            try store?.forgetPin(endpoint: host.endpoint)
            notice = text("已移除指纹，下次连接时重新验证", "Fingerprint removed. Verify it on the next connection.")
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Whether a session's host is up

    /// A live session to the same endpoint already shows the host is up, without probing it.
    func hostConnected(_ host: Host) -> Bool {
        runtimes.values.contains { $0.host.id == host.id && $0.host.address == host.address && $0.host.port == host.port && $0.phase == .connected }
    }
    /// Shown on a session's card while it waits for its host: the last probe found sshd silent.
    func hostOffline(_ record: SessionRecord) -> Bool {
        guard let host = host(record.hostID), runtimes[record.id]?.phase.active != true, !hostConnected(host) else { return false }
        return reachability[host.id]?.isOffline == true
    }
}
