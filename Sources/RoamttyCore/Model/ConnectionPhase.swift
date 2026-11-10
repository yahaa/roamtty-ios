import Foundation

public enum ConnectionPhase: String, Codable, Sendable {
    case connecting, verifying, authenticating, connected, disconnected, authFailed, hostKeyChanged, failed, tmuxMissing
    public var active: Bool { [.connecting, .verifying, .authenticating, .connected].contains(self) }

    /// What a connection that failed with `error` shows: why the login stopped, or plainly that it failed.
    public init(failure error: Error) {
        switch error as? RoamError {
        case .authentication: self = .authFailed
        case .hostKeyChanged: self = .hostKeyChanged
        case .tmuxMissing: self = .tmuxMissing
        case .cancelled, .rejected: self = .disconnected
        default: self = .failed
        }
    }
}
