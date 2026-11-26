import Foundation

/// Voice dialogue mode (`agy /voice live` with full-duplex barge-in).
public enum VoiceMode: String, CaseIterable, Equatable, Sendable {
    /// Two-way live conversation (`/voice live` · `F6`).
    case live

    /// Terminal function key number that starts this mode in `agy`.
    public var startFunctionKey: Int { 6 }
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

/// Classification for why remote `agy` audio streams closed.
public enum VoiceRemoteEndReason: Equatable, Sendable {
    /// Live call (`F6`) ended cleanly after running normally (e.g. `hang_up`, `Esc`, or `/voice`).
    case ended
    /// Live call streams closed right after opening without any speaker audio (e.g. `Access denied`).
    case abortedEarly
}

/// Action returned by `VoiceRemoteStreamTracker` for each incoming `VoiceStreamEvent`.
public enum VoiceRemoteStreamAction: Equatable, Sendable {
    case none
    case streamActive
    case endedImmediately(VoiceRemoteEndReason)
    case scheduleRemoteEnd(VoiceRemoteEndReason)
}

/// Tracks active remote `agy` mic/speaker streams so the UI auto-closes live calls when `agy`
/// exits `/voice` (clean `hang_up`, terminal `Esc`, or immediate errors like `Access denied`)
/// without falsely ending calls on mute, barge-in, or transient `--resume` reconnects.
public struct VoiceRemoteStreamTracker: Equatable, Sendable {
    public static let earlyAbortWindowSeconds: TimeInterval = 5.0
    public static let remoteEndGraceMs = 350
    public static let noStreamHintDelaySeconds: TimeInterval = 8.0

    public private(set) var mode: VoiceMode
    public private(set) var activeMicStreamId: UInt32?
    public private(set) var activeSpkStreamId: UInt32?
    public private(set) var hadAnyStream = false
    public private(set) var receivedSpeakerAudio = false
    private var firstStreamAt: TimeInterval?

    public init(mode: VoiceMode = .live) {
        self.mode = mode
    }

    public mutating func reset(mode: VoiceMode) {
        self = VoiceRemoteStreamTracker(mode: mode)
    }

    /// Clears in-flight stream IDs while `VoiceSession` reconnects (`--resume`) so stale stops
    /// cannot trigger hangup before `roamtty-desktop` re-announces live streams.
    public mutating func beginRecovery() {
        activeMicStreamId = nil
        activeSpkStreamId = nil
    }

    public mutating func handle(_ event: VoiceStreamEvent, at now: TimeInterval) -> VoiceRemoteStreamAction {
        switch event {
        case .micStarted(let id, _):
            activeMicStreamId = id
            hadAnyStream = true
            if firstStreamAt == nil { firstStreamAt = now }
            return .streamActive
        case .speakerStarted(let id, _):
            activeSpkStreamId = id
            hadAnyStream = true
            if firstStreamAt == nil { firstStreamAt = now }
            return .streamActive
        case .speakerAudio(_, let bytes):
            if bytes > 0 { receivedSpeakerAudio = true }
            return .none
        case .speakerCleared:
            return .none
        case .micStopped(let id):
            let wasStreaming = activeMicStreamId != nil || activeSpkStreamId != nil
            let matched = activeMicStreamId == id
            if matched { activeMicStreamId = nil }
            guard matched, wasStreaming, activeMicStreamId == nil, activeSpkStreamId == nil else { return .none }
            return .scheduleRemoteEnd(classifyLiveEnd(at: now))
        case .speakerStopped(let id):
            let wasStreaming = activeMicStreamId != nil || activeSpkStreamId != nil
            let matched = activeSpkStreamId == id
            if matched { activeSpkStreamId = nil }
            guard matched, wasStreaming, activeMicStreamId == nil, activeSpkStreamId == nil else {
                return .none
            }
            return .scheduleRemoteEnd(classifyLiveEnd(at: now))
        }
    }

    private func classifyLiveEnd(at now: TimeInterval) -> VoiceRemoteEndReason {
        if !receivedSpeakerAudio, let started = firstStreamAt, now - started < Self.earlyAbortWindowSeconds {
            return .abortedEarly
        }
        return .ended
    }
}
