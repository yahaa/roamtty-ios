#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Identifies the owner role holding an active `AVAudioSession` lease.
enum AudioSessionRole: Equatable, Sendable {
    case desktop
    case voice
}

/// Serializes `AVAudioSession` configuration, activation, and deactivation across `VoiceAudioEngine`
/// and `DesktopAudioPlayer` using per-owner tokens so a delayed teardown from an old call or muted
/// desktop stream can never deactivate or downgrade an active session owned by another component.
final class AudioSessionCoordinator: @unchecked Sendable {
    static let shared = AudioSessionCoordinator()

    private let queue = DispatchQueue(label: "roamtty.audio.session", qos: .userInteractive)
    private var activeOwners: [UUID: AudioSessionRole] = [:]

    private init() {}

    /// Activates the shared `AVAudioSession` for `token` and `role`.
    /// Returns `false` (without touching the session) if a `.desktop` owner tries to activate while `.voice` is active.
    @discardableResult
    func activate(token: UUID, role: AudioSessionRole, configure: (AVAudioSession) throws -> Void) throws -> Bool {
        try queue.sync {
            if role == .desktop && activeOwners.values.contains(.voice) {
                return false
            }
            let session = AVAudioSession.sharedInstance()
            try configure(session)
            try session.setActive(true)
            activeOwners[token] = role
            return true
        }
    }

    /// Runs `body` against the shared `AVAudioSession` while `token` holds an active lease.
    func withActiveSession(token: UUID, _ body: (AVAudioSession) -> Void) {
        queue.sync {
            guard activeOwners[token] != nil else { return }
            body(AVAudioSession.sharedInstance())
        }
    }

    /// Releases `token`'s lease and deactivates `AVAudioSession` only when no active owners remain.
    func deactivate(token: UUID) {
        queue.sync {
            guard activeOwners.removeValue(forKey: token) != nil else { return }
            guard activeOwners.isEmpty else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
#endif
