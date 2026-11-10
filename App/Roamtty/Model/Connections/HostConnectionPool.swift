import Foundation
import RoamttyCore
import RoamttyTransport

/// The connection that a host's tools (files, plugins, metrics) share: opened once for everything that asks at the
/// same time, and probed for the host's plugins and system when it comes up.
@MainActor final class HostConnectionPool {
    /// What a probe found on a newly connected host: its plugins (nil: unchanged) and its system.
    var onMetadata: ((_ host: Host, _ plugins: [String]?, _ system: String) -> Void)?

    private var connections: [String: SSHConnection] = [:]
    /// The attempts under way and the token of each host's latest attempt.
    private var tasks: [String: Task<SSHConnection, Error>] = [:]
    private var tokens: [String: UUID] = [:]
    private var connecting: [String: SSHConnection] = [:]
    private var metadataJobs: [String: TrackedTask] = [:]
    /// Where each host's shared connection stands.
    private var phases: [String: ConnectionPhase] = [:]
    private unowned let environment: ConnectionEnvironment
    private let logins: HostLogins

    init(environment: ConnectionEnvironment, logins: HostLogins) { self.environment = environment; self.logins = logins }

    /// How many hosts have a shared connection.
    var count: Int { connections.count }
    /// Whether the host's shared connection is up.
    func isConnected(_ hostID: String) -> Bool { connections[hostID]?.isConnected == true }
    /// Whether `connection` is still the host's shared connection.
    func holds(_ connection: SSHConnection, for hostID: String) -> Bool { connections[hostID] === connection }

    /// Drops everything under way for the host: its attempt, its metadata probe and its connection.
    func drop(_ hostID: String) {
        tokens.removeValue(forKey: hostID)
        tasks.removeValue(forKey: hostID)?.cancel()
        metadataJobs.removeValue(forKey: hostID)?.cancel()
        connecting.removeValue(forKey: hostID)?.disconnectInBackground()
        connections.removeValue(forKey: hostID)?.disconnectInBackground()
        phases[hostID] = .disconnected
    }

    /// The host's shared connection, opened once for everything that asks at the same time.
    func connection(for hostID: String) async throws -> SSHConnection {
        if let task = tasks[hostID] { return try await task.value }
        if let ssh = connections[hostID], phases[hostID] == .connected, ssh.isConnected { return ssh }
        guard let host = environment.host(hostID) else { throw RoamError.invalid("Host no longer exists") }
        connections.removeValue(forKey: hostID)?.disconnectInBackground()
        let attempt = logins.attempt(host: hostID, owner: hostID), token = UUID()
        tokens[hostID] = token
        func current() -> Bool { tokens[hostID] == token && logins.isCurrent(attempt) }
        let task = Task<SSHConnection, Error> {
            let credentials = try await self.logins.credentials(for: host, owner: hostID)
            guard !Task.isCancelled, current() else { throw RoamError.cancelled }
            let ssh = try self.logins.makeConnection(host, credentials: credentials, owner: hostID)
            self.connecting[hostID] = ssh
            ssh.onPhase = { [weak self] phase in
                DispatchQueue.main.async {
                    guard let self, self.tokens[hostID] == token, self.logins.isCurrent(attempt) else { return }
                    self.phases[hostID] = phase
                }
            }
            do {
                try await ssh.connectInBackground()
                guard !Task.isCancelled, current() else { throw RoamError.cancelled }
                self.connections[hostID] = ssh
                self.phases[hostID] = .connected
                self.detectMetadata(host: host, ssh: ssh, attempt: attempt, token: token)
                return ssh
            } catch { ssh.disconnectInBackground(); throw error }
        }
        tasks[hostID] = task
        defer { if tokens[hostID] == token { tasks.removeValue(forKey: hostID); connecting.removeValue(forKey: hostID) } }
        do { return try await task.value } catch {
            if current(), (error as? RoamError) == .authentication { logins.rejectLogin(hostID) }
            throw error
        }
    }
    /// Probes a newly connected host for its plugins and system, which the host's page shows.
    private func detectMetadata(host: Host, ssh: SSHConnection, attempt: ConnectionAttempt, token: UUID) {
        metadataJobs[host.id]?.cancel()
        let cancellation = TransferCancellation()
        let task = Task { [weak self] in
            await withTaskCancellationHandler(operation: {
                guard let self else { return }
                defer { if self.tokens[host.id] == token { self.metadataJobs.removeValue(forKey: host.id) } }
                @MainActor func current() -> Bool { !Task.isCancelled && self.tokens[host.id] == token && self.connections[host.id] === ssh && self.logins.isCurrent(attempt) }
                do {
                    guard current() else { return }
                    let plugins = try await ssh.probePlugins(timeout: 8, cancellation: cancellation)
                    guard current() else { return }
                    if let plugins, let latest = self.environment.host(host.id) {
                        self.onMetadata?(host, plugins.map(\.rawValue).sorted(), latest.system)
                    }
                    let system = try await ssh.probeSystem(timeout: 8, cancellation: cancellation) {
                        guard current() else { throw RoamError.cancelled }
                    }
                    if system != .UNKNOWN, let latest = self.environment.host(host.id) { self.onMetadata?(host, latest.plugins, system.rawValue) }
                } catch { /* Metadata probes are optional; an authenticated terminal remains usable. */ }
            }, onCancel: { cancellation.cancel() })
        }
        metadataJobs[host.id] = TrackedTask(token: token, task: task, cancellation: cancellation)
    }
}
