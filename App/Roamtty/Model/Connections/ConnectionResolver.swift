import Foundation
import RoamttyCore
import RoamttyTransport

/// Hands a tool the connection it works over: its host's shared one, or the one of the session that opened it.
@MainActor protocol ConnectionResolver: AnyObject {
    func connectionTarget(hostID: String, sessionID: String?) -> RemoteConnectionTarget
    /// Throws once the session that owns `target` moved on.
    func validate(_ target: RemoteConnectionTarget) throws
    func connection(for target: RemoteConnectionTarget) async throws -> SSHConnection
    /// Whether `connection` is still the host's shared connection.
    func holdsSharedConnection(_ connection: SSHConnection, for hostID: String) -> Bool
}

/// What file transfers ask of the app around them.
@MainActor protocol TransferEnvironment: ConnectionResolver {
    /// The folder the user chose for downloads, as a security-scoped bookmark; nil for the app's own Downloads.
    var downloadBookmark: Data? { get }
    func text(_ chinese: String, _ english: String) -> String
    /// Tells the user of a failure that no transfer row can show.
    func report(_ message: String)
    /// A file shared into the app reached its host.
    func sharedFileUploaded(_ url: URL)
}
