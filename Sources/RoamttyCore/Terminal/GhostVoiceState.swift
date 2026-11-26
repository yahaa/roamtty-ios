import Foundation

/// Voice-call visual state for the 26x26 toolbox ghost pet (`GhostArt.swift`), shared between
/// the SwiftUI renderer and SwiftPM unit tests.
public enum GhostVoiceState: Equatable, Sendable {
    case idle
    case connecting
    case listening(level: Double)
    case speaking(level: Double)
    case muted

    public var isCall: Bool { self != .idle }
    public var showsHandset: Bool { isCall }
    public var showsKeyboard: Bool { !isCall }
    public var showsAura: Bool {
        switch self {
        case .connecting, .listening, .speaking: return true
        case .idle, .muted: return false
        }
    }
    public var showsSoundWaves: Bool {
        switch self {
        case .connecting, .speaking: return true
        case .idle, .listening, .muted: return false
        }
    }
    public var showsMuteBadge: Bool { self == .muted }

    /// Clamped audio level (`0...1`) driving aura radius and speaking mouth aperture.
    public var audioLevel: Double {
        switch self {
        case .listening(let level), .speaking(let level):
            guard level.isFinite else { return 0 }
            return min(max(level, 0), 1)
        case .idle, .connecting, .muted:
            return 0
        }
    }
}

/// Pure animation parameters of the ghost pet at a point in time, honoring `reduceMotion`.
/// Exact port of `agy-voice-ui-design.html` (`drawGhostCanvas`) and `GhostArt.swift`.
public struct GhostVoicePose: Equatable, Sendable {
    public var float: Double
    public var sway: Double
    public var hem: Double
    public var eyes: Double
    public var wave: Double
    public var cursor: Double
    public var ringJiggle: Double
    public var pulseProgress: Double?
    public var waveAlpha1: Double
    public var waveAlpha2: Double
    public var level: Double

    public static let still = GhostVoicePose(
        float: 0, sway: 0, hem: 0, eyes: 1, wave: 0, cursor: 1,
        ringJiggle: 0, pulseProgress: nil, waveAlpha1: 0.85, waveAlpha2: 0.55, level: 0
    )

    public static func at(_ time: TimeInterval, voice: GhostVoiceState = .idle, reduceMotion: Bool = false) -> GhostVoicePose {
        if reduceMotion {
            return GhostVoicePose(
                float: voice.isCall ? 0.35 : 0, sway: 0, hem: 0, eyes: 1, wave: 0, cursor: 1,
                ringJiggle: 0, pulseProgress: nil, waveAlpha1: 0.85, waveAlpha2: 0.55,
                level: voice.isCall ? 0.35 : 0
            )
        }
        let ms = max(0, time * 1000)
        let (floatPeriod, swayAmp, swayPeriod) = timing(for: voice)
        let floatVal = fastOutSlowIn(reversing(ms, period: floatPeriod))
        let swayVal = -swayAmp + 2 * swayAmp * fastOutSlowIn(reversing(ms, period: swayPeriod))
        let hemVal = ms.truncatingRemainder(dividingBy: 1100) / 1100 * 2 * .pi
        let eyesVal = keyframes(ms, period: 3600, [(0, 1), (3250, 1), (3330, 0.1), (3420, 1), (3600, 1)])
        let rawWave = keyframes(ms, period: 5200, [(0, 0), (3000, 0), (3180, -30), (3380, 14), (3580, -30), (3780, 14), (3980, 0), (5200, 0)])
        let waveVal = voice.isCall ? rawWave * 0.18 : rawWave
        let cursorVal = ms.truncatingRemainder(dividingBy: 1060) < 530 ? 1.0 : 0.0
        let jiggle = ringJiggle(ms: ms, voice: voice)
        let pulsePeriod: Double = voice == .connecting ? 1400 : 1800
        let pulse: Double? = voice.showsAura ? ms.truncatingRemainder(dividingBy: pulsePeriod) / pulsePeriod : nil
        return GhostVoicePose(
            float: floatVal, sway: swayVal, hem: hemVal, eyes: eyesVal, wave: waveVal, cursor: cursorVal,
            ringJiggle: jiggle, pulseProgress: pulse,
            waveAlpha1: 0.35 + 0.65 * max(0, sin(ms / 190)),
            waveAlpha2: 0.25 + 0.75 * max(0, sin(ms / 190 - 1.0)),
            level: voice.audioLevel
        )
    }

    private static func timing(for voice: GhostVoiceState) -> (floatPeriod: Double, swayAmp: Double, swayPeriod: Double) {
        switch voice {
        case .muted: return (2200, 2.5, 2300)
        case .speaking: return (1050, 6.5, 1500)
        case .idle, .connecting, .listening: return (1400, 5.0, 2300)
        }
    }

    private static func ringJiggle(ms: Double, voice: GhostVoiceState) -> Double {
        switch voice {
        case .connecting: return sin(ms / 45) * 7.5 * (sin(ms / 420) > 0 ? 1 : 0.15)
        case .speaking: return sin(ms / 210) * 3.2
        case .idle, .listening, .muted: return 0
        }
    }

    /// A tween that runs forward then back, as `RepeatMode.Reverse` does.
    private static func reversing(_ ms: Double, period: Double) -> Double {
        let phase = ms.truncatingRemainder(dividingBy: 2 * period) / period
        return phase <= 1 ? phase : 2 - phase
    }

    /// Linear interpolation between keyframes, Compose's default.
    private static func keyframes(_ ms: Double, period: Double, _ frames: [(Double, Double)]) -> Double {
        let t = ms.truncatingRemainder(dividingBy: period)
        for (a, b) in zip(frames, frames.dropFirst()) where t <= b.0 {
            return b.0 == a.0 ? b.1 : a.1 + (b.1 - a.1) * (t - a.0) / (b.0 - a.0)
        }
        return frames.last?.1 ?? 0
    }

    /// Material's FastOutSlowInEasing, cubic-bezier(0.4, 0, 0.2, 1).
    public static func fastOutSlowIn(_ x: Double) -> Double {
        func curve(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<16 {
            let mid = (low + high) / 2
            if curve(mid, 0.4, 0.2) < x { low = mid } else { high = mid }
        }
        return curve((low + high) / 2, 0, 1)
    }
}
