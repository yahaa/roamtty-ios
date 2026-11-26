import Foundation

/// User-selected voice mode on the terminal voice confirmation sheet.
public enum VoiceMode: String, CaseIterable, Equatable, Sendable {
    /// Two-way live conversation (`/voice live` · `F6`).
    case live
    /// Push-to-dictate speech-to-text (`/voice dictate` · `F5`).
    case dictate

    /// Terminal function key number that starts this mode in `agy`.
    public var startFunctionKey: Int {
        switch self {
        case .live: return 6
        case .dictate: return 5
        }
    }
}

/// Output audio route selection for active voice calls.
public enum VoiceAudioRoute: String, CaseIterable, Equatable, Sendable {
    case speaker
    case earpiece
    case bluetooth
}

/// Lifecycle phase of a `VoiceSession` transport connection.
public enum VoiceSessionPhase: Equatable, Sendable {
    case idle
    case connecting(step: Step)
    case ready(micPort: Int, udp: Bool)
    case recovering(sinceMs: Int64)
    case failed(message: String)

    public enum Step: Equatable, Sendable { case login, install, start }
}

/// Error returned by `VoiceAudioIO.startSpeaker` and forwarded in `SPK_ACK` (`<= 235 B` UTF-8).
public struct VoiceAudioError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Platform audio capture & playback adapter injected into `VoiceSession`.
/// The iOS app implements this with `AVAudioEngine` (VPIO hardware AEC) + `AVAudioPlayerNode`;
/// SwiftPM tests inject a deterministic in-memory fake.
public protocol VoiceAudioIO: AnyObject {
    func startMic(streamId: UInt32, sampleRate: UInt32, channels: UInt8, onPcm: @escaping @Sendable (UInt32, [UInt8]) -> Void)
    func stopMic(streamId: UInt32)
    func startSpeaker(streamId: UInt32, sampleRate: UInt32, channels: UInt8) -> Result<Void, VoiceAudioError>
    func playSpeaker(streamId: UInt32, pcm: [UInt8])
    func clearSpeaker(streamId: UInt32)
    func stopSpeaker(streamId: UInt32)
    func stopAll()
}

/// Transport-level events emitted by `VoiceSession` to drive the UI state machine.
public enum VoiceStreamEvent: Equatable, Sendable {
    case micStarted(streamId: UInt32, sampleRate: UInt32)
    case micStopped(streamId: UInt32)
    case speakerStarted(streamId: UInt32, sampleRate: UInt32)
    case speakerAudio(streamId: UInt32, bytes: Int)
    case speakerCleared(streamId: UInt32)
    case speakerStopped(streamId: UInt32)
}
