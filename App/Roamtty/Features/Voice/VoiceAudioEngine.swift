#if canImport(AVFoundation)
import AVFoundation
import Foundation
import RoamttyDesktopCore

/// Full-duplex iOS voice audio engine for `agy /voice`:
/// - `AVAudioSession` in `.playAndRecord` + `.voiceChat` with 10 ms preferred IO buffer duration
/// - Single reused `AVAudioEngine` with hardware VPIO AEC + pull-mode `AVAudioSourceNode` backed by a
///   real-time-safe `VoicePcmRingBuffer` (zero `scheduleBuffer` jitter, zero block-boundary clicks, instant barge-in)
/// - Adaptive `VoiceJitterBuffer` (Opus VOIP + RED + LBRR + PLC + WSOLA + `turnGen`) for `SPK_OPUS`
/// - Dynamic capture tap size (fixing Bluetooth HFP 16 kHz 64 ms bloat) + 80 Hz HPF & soft-knee limiter
/// - Pure Objective-C `@try/@catch` wrappers around all `AVAudioEngine` / `AVAudioConverter` calls
final class VoiceAudioEngine: VoiceAudioIO, @unchecked Sendable {
    let queue = DispatchQueue(label: "roamtty.voice.audio", qos: .userInteractive)
    let sessionToken = UUID()
    let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    var captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let pcmRing = VoicePcmRingBuffer(capacity: 14_400, maxQueued: 9_600)

    static let levelThrottleNs: UInt64 = 66_000_000
    static let speakerKeepaliveNs: UInt64 = 200_000_000
    static let speakerSilenceDecayNs: UInt64 = 350_000_000
    static let routeSettleSuppressNs: UInt64 = 800_000_000
    static let retiredEngineGraceMs = 1500
    static let levelMinDelta: Float = 0.03
    /// Keep at most 60 ms (2880 samples @ 48 kHz) ahead in the hardware pull ring so JitterBuffer stays in control.
    static let pumpTargetRingSamples = 2_880

    var engine: AVAudioEngine?
    var sourceNode: AVAudioSourceNode?
    var engineUsesVPIO = false
    var engineGraphAttached = false
    var captureConverter: AVAudioConverter?
    var capturePreprocessor = VoiceAudioPreprocessor(sampleRate: 16_000)
    var captureTapInstalled = false
    var captureBuffer: [UInt8] = []
    var micStreamId: UInt32?
    var micCallback: (@Sendable (UInt32, [UInt8]) -> Void)?

    var spkStreamId: UInt32?
    var spkSampleRate: UInt32 = 24_000
    var spkResampler: VoiceLinearResampler?
    var spkJitter: VoiceJitterBuffer?
    var spkPumpTimer: DispatchSourceTimer?
    var lastSpeakerAudioNs: UInt64 = 0
    var route: VoiceAudioRoute = .speaker
    /// True once the user explicitly picks a route; false lets iOS honor the active default (Bluetooth / headset / speaker).
    var routeExplicitlyChosen = false
    var smoothedMicLevel: Float = 0
    var smoothedSpkLevel: Float = 0
    var lastEmittedMicLevel: Float = -1
    var lastEmittedMicNs: UInt64 = 0
    var lastEmittedSpkLevel: Float = -1
    var lastEmittedSpkNs: UInt64 = 0
    var sessionActive = false
    var interrupted = false
    var vpioFailed = false
    var lastHardwareSampleRate: Double = 0
    var suppressRouteRebuildUntilNs: UInt64 = 0
    var pendingRebuild: DispatchWorkItem?

    var onMicLevel: ((Float) -> Void)?
    var onSpeakerLevel: ((Float) -> Void)?
    var onRouteChanged: ((VoiceAudioRoute) -> Void)?

    var routeObserver: NSObjectProtocol?
    var interruptionObserver: NSObjectProtocol?
    var configChangeObserver: NSObjectProtocol?

    init() {
        registerAudioNotifications()
    }

    deinit {
        let nc = NotificationCenter.default
        if let routeObserver { nc.removeObserver(routeObserver) }
        if let interruptionObserver { nc.removeObserver(interruptionObserver) }
        if let configChangeObserver { nc.removeObserver(configChangeObserver) }
        teardownSync()
    }

    // MARK: Permissions & Routes

    static var microphonePermission: VoiceMicPermission {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .undetermined
            @unknown default: return .undetermined
            }
        }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    static func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static var hasBluetoothRoute: Bool {
        let session = AVAudioSession.sharedInstance()
        let btTypes: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]
        let outHasBT = session.currentRoute.outputs.contains { btTypes.contains($0.portType) }
        let inHasBT = (session.availableInputs ?? []).contains { btTypes.contains($0.portType) }
        return outHasBT || inHasBT
    }

    func setAudioRoute(_ next: VoiceAudioRoute) {
        queue.async { [self] in
            route = next
            routeExplicitlyChosen = true
            applyRouteLocked(force: true)
        }
    }

    /// Pre-warms `AVAudioSession` (`.playAndRecord` + `.voiceChat`) and `AVAudioEngine`
    /// when the call starts so `SPK_START` replies with `SPK_ACK` without cold-start timeout risk.
    func prepareSession(route next: VoiceAudioRoute? = nil) {
        queue.async { [self] in
            if let next {
                route = next
                routeExplicitlyChosen = true
            } else {
                routeExplicitlyChosen = false
            }
            guard !interrupted else { return }
            _ = ensureEngineRunning()
        }
    }

    // MARK: VoiceAudioIO

    func startMic(streamId: UInt32, sampleRate: UInt32, channels: UInt8, onPcm: @escaping @Sendable (UInt32, [UInt8]) -> Void) {
        queue.async { [self] in
            Diagnostics.shared.log("voice-mic-start", "stream=\(streamId) rate=\(sampleRate) ch=\(channels)")
            let rate = sampleRate > 0 ? Double(sampleRate) : Double(VoiceProtocol.defaultMicSampleRate)
            let ch = AVAudioChannelCount(max(1, channels))
            if let requested = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: ch, interleaved: true),
               requested.sampleRate != captureFormat.sampleRate || requested.channelCount != captureFormat.channelCount {
                captureConverter = nil
                captureFormat = requested
            }
            capturePreprocessor = VoiceAudioPreprocessor(sampleRate: rate)
            micStreamId = streamId
            micCallback = onPcm
            captureBuffer.removeAll(keepingCapacity: true)
            guard !interrupted else { return }
            _ = ensureEngineRunning()
        }
    }

    func stopMic(streamId: UInt32) {
        queue.async { [self] in
            guard micStreamId == streamId else { return }
            Diagnostics.shared.log("voice-mic-stop", "stream=\(streamId)")
            micStreamId = nil
            micCallback = nil
            captureBuffer.removeAll(keepingCapacity: false)
            resetMicLevel()
        }
    }

    func startSpeaker(streamId: UInt32, sampleRate: UInt32, channels: UInt8) -> Result<Void, VoiceAudioError> {
        queue.sync { [self] in
            Diagnostics.shared.log("voice-spk-start", "stream=\(streamId) rate=\(sampleRate) ch=\(channels)")
            guard VoiceProtocol.speakerRateRange.contains(sampleRate), channels == 1 else {
                return .failure(VoiceAudioError("unsupported format \(sampleRate)Hz \(channels)ch"))
            }
            guard !interrupted, ensureEngineRunning() else {
                return .failure(VoiceAudioError("audio engine unavailable"))
            }
            stopSpeakerPumpLocked()
            pcmRing.clear()
            spkStreamId = streamId
            spkSampleRate = sampleRate
            spkResampler = VoiceLinearResampler(inputRate: Double(sampleRate), outputRate: playbackFormat.sampleRate)
            spkJitter = nil
            lastSpeakerAudioNs = 0
            return .success(())
        }
    }

    /// Legacy PCM16 fallback: resamples continuously into the real-time pull ring (dropping oldest on overflow).
    func playSpeaker(streamId: UInt32, pcm: [UInt8]) {
        queue.async { [self] in
            guard !interrupted, spkStreamId == streamId, pcm.count >= 2,
                  let engine, engine.isRunning, let resampler = spkResampler else { return }
            let samples = VoiceOpusMath.bytesToInt16(pcm)
            updateSpeakerLevel(samples: samples)
            pcmRing.write(resampler.resample(samples))
            lastSpeakerAudioNs = DispatchTime.now().uptimeNanoseconds
        }
    }

    /// Sequenced Opus speaker packet (`SPK_OPUS`): feeds the adaptive speech jitter buffer (RED + LBRR + PLC + WSOLA).
    func playSpeakerOpus(streamId: UInt32, packet: VoiceOpusPacket) {
        queue.async { [self] in
            guard !interrupted, spkStreamId == streamId else { return }
            let nowMs = Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
            if spkJitter == nil || spkJitter?.streamId != streamId {
                guard VoiceOpusMath.isOpusSampleRate(spkSampleRate),
                      let jb = VoiceJitterBuffer(streamId: streamId, sampleRate: spkSampleRate) else { return }
                spkJitter = jb
                startSpeakerPumpLocked()
            }
            spkJitter?.push(packet, nowMs: nowMs)
            pumpOpusSpeakerLocked()
        }
    }

    func speakerStats(streamId: UInt32, nowMs: Int64) -> VoiceStats? {
        queue.sync { [self] in
            guard let jb = spkJitter, jb.streamId == streamId else { return nil }
            return jb.statsSnapshot(nowMs: nowMs)
        }
    }

    func clearSpeaker(streamId: UInt32) {
        queue.async { [self] in
            guard spkStreamId == streamId else { return }
            spkJitter?.clearForBargeIn()
            spkResampler?.reset()
            pcmRing.clear()
            resetSpeakerLevel()
        }
    }

    func stopSpeaker(streamId: UInt32) {
        queue.async { [self] in
            guard spkStreamId == streamId else { return }
            Diagnostics.shared.log("voice-spk-stop", "stream=\(streamId)")
            stopSpeakerPumpLocked()
            spkStreamId = nil
            spkJitter = nil
            spkResampler = nil
            pcmRing.clear()
            resetSpeakerLevel()
        }
    }

    func stopAll() {
        queue.async { [self] in teardownSync() }
    }

    /// Synchronously stops the active engine and releases the `AVAudioSession` lease before another session takes over.
    func stopAllSync() {
        queue.sync { [self] in teardownSync() }
    }
}
#endif
