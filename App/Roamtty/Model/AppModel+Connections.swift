import Foundation
import RoamttyCore
import RoamttyTransport

/// Which connection a tool works over (its host's shared one, or the one of the session that opened it), and
/// dropping everything under way for a host.
extension AppModel {
    /// Drops everything under way for the host: its shared connection, metadata probes, monitor and logins.
    func invalidateHostConnections(_ hostID: String) {
        logins.invalidateHost(hostID)
        monitor.stop(hostID); cancelLaunch(hostID)
        pool.drop(hostID)
        for runtime in runtimes.values where runtime.host.id == hostID {
            runtime.voice.shutdown()
        }
        for record in records where record.hostID == hostID {
            cancelLaunch(record.id)
            if let runtime = runtimes[record.id], runtime.phase.active && runtime.phase != .connected { runtime.close() }
        }
    }

    func connectionTarget(hostID: String, sessionID: String?) -> RemoteConnectionTarget {
        guard let sessionID else { return .host(hostID) }
        let runtime = runtimes[sessionID].flatMap { $0.host.id == hostID ? $0 : nil }
        return .session(sessionID, SessionConnectionSnapshot(session: runtime, connection: runtime?.ssh))
    }
    /// Validates ownership without looking up a replacement host connection.
    func validate(_ target: RemoteConnectionTarget) throws {
        if case .session(let id, let snapshot) = target { _ = try resolve(snapshot, session: id) }
    }
    func connection(for target: RemoteConnectionTarget) async throws -> SSHConnection {
        try Task.checkCancellation()
        switch target {
        case .host(let id): return try await pool.connection(for: id)
        case .session(let id, let snapshot): return try resolve(snapshot, session: id)
        }
    }
    func holdsSharedConnection(_ connection: SSHConnection, for hostID: String) -> Bool { pool.holds(connection, for: hostID) }

    // MARK: What file transfers ask (TransferEnvironment)

    var downloadBookmark: Data? { settings.downloadBookmark }
    func report(_ message: String) { error = message }
    func sharedFileUploaded(_ url: URL) { incomingFiles.removeAll { $0 == url } }

    private func resolve(_ snapshot: SessionConnectionSnapshot<SessionRuntime, SSHConnection>, session id: String) throws -> SSHConnection {
        let current = runtimes[id]
        return try snapshot.resolve(currentSession: current, currentConnection: current?.ssh,
                                    connected: current?.phase == .connected && current?.ssh?.isConnected == true)
    }
}
