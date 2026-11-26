#if canImport(AVFoundation)
import AVFoundation
import Foundation
import RoamttyDesktopCore

/// Microphone permission state for contextual confirmation sheet notices.
enum VoiceMicPermission: Equatable, Sendable {
    case undetermined, granted, denied
}

/// Full-duplex iOS voice audio engine for `agy /voice`:
/// - `AVAudioSession` in `.playAndRecord` + `.voiceChat` with speaker / earpiece / Bluetooth routing
/// - `AVAudioEngine` inputNode with hardware VPIO AEC (`setVoiceProcessingEnabled(true)`)
/// - Resampling mic capture to requested PCM16 LE format (default 16 kHz mono / `640 B` chunks) + throttled RMS level
/// - `AVAudioPlayerNode` honoring dynamic `SPK_START` sample rates, bounded buffer queue, and instant barge-in flush
final class VoiceAudioEngine: VoiceAudioIO, @unchecked Sendable {
    let queue = DispatchQueue(label: "roamtty.voice.audio", qos: .userInteractive)
    let sessionToken = UUID()
    let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    var captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    static let maxPendingPlaybackBuffers = 20
    static let levelThrottleNs: UInt64 = 66_000_000
    static let speakerKeepaliveNs: UInt64 = 200_000_000
    static let levelMinDelta: Float = 0.03

    var engine: AVAudioEngine?
    var playerNode: AVAudioPlayerNode?
    var captureConverter: AVAudioConverter?
    var captureTapInstalled = false
    var captureBuffer: [UInt8] = []
    var micStreamId: UInt32?
    var micCallback: (@Sendable (UInt32, [UInt8]) -> Void)?

    var spkStreamId: UInt32?
    var spkInputFormat: AVAudioFormat?
    var spkConverter: AVAudioConverter?
    var pendingPlaybackBuffers = 0
    var playbackGeneration: UInt64 = 0
    var route: VoiceAudioRoute = .speaker
    var smoothedMicLevel: Float = 0
    var smoothedSpkLevel: Float = 0
    var lastEmittedMicLevel: Float = -1
    var lastEmittedMicNs: UInt64 = 0
    var lastEmittedSpkLevel: Float = -1
    var lastEmittedSpkNs: UInt64 = 0
    var sessionActive = false
    var interrupted = false
    var lastHardwareSampleRate: Double = 0

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
            applyRouteLocked()
        }
    }

    /// Pre-warms `AVAudioSession` (`.playAndRecord` + `.voiceChat`) and `AVAudioEngine` with VPIO AEC
    /// when the call starts so `SPK_START` replies with `SPK_ACK` without cold-start timeout risk.
    func prepareSession(route next: VoiceAudioRoute) {
        queue.async { [self] in
            route = next
            guard !interrupted else { return }
            _ = ensureEngineRunning()
            applyRouteLocked()
        }
    }

    // MARK: VoiceAudioIO

    func startMic(streamId: UInt32, sampleRate: UInt32, channels: UInt8, onPcm: @escaping @Sendable (UInt32, [UInt8]) -> Void) {
        queue.async { [self] in
            let rate = sampleRate > 0 ? Double(sampleRate) : Double(VoiceProtocol.defaultMicSampleRate)
            let ch = AVAudioChannelCount(max(1, channels))
            if let requested = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: ch, interleaved: true),
               requested.sampleRate != captureFormat.sampleRate || requested.channelCount != captureFormat.channelCount {
                removeCaptureTap()
                captureFormat = requested
            }
            micStreamId = streamId
            micCallback = onPcm
            captureBuffer.removeAll(keepingCapacity: true)
            guard !interrupted, ensureEngineRunning() else { return }
            installCaptureTapIfNeeded()
        }
    }

    func stopMic(streamId: UInt32) {
        queue.async { [self] in
            guard micStreamId == streamId else { return }
            micStreamId = nil
            micCallback = nil
            captureBuffer.removeAll(keepingCapacity: false)
            removeCaptureTap()
            resetMicLevel()
        }
    }

    func startSpeaker(streamId: UInt32, sampleRate: UInt32, channels: UInt8) -> Result<Void, VoiceAudioError> {
        queue.sync { [self] in
            guard VoiceProtocol.speakerRateRange.contains(sampleRate), channels == 1 else {
                return .failure(VoiceAudioError("unsupported format \(sampleRate)Hz \(channels)ch"))
            }
            guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: inFmt, to: playbackFormat) else {
                return .failure(VoiceAudioError("audio converter unavailable"))
            }
            guard !interrupted, ensureEngineRunning() else {
                return .failure(VoiceAudioError("audio engine unavailable"))
            }
            spkStreamId = streamId
            spkInputFormat = inFmt
            spkConverter = converter
            playbackGeneration &+= 1
            pendingPlaybackBuffers = 0
            if let engine, engine.isRunning, let playerNode {
                playerNode.stop()
                playerNode.reset()
                playerNode.play()
            }
            return .success(())
        }
    }

    func playSpeaker(streamId: UInt32, pcm: [UInt8]) {
        queue.async { [self] in
            guard !interrupted, spkStreamId == streamId, !pcm.isEmpty,
                  let engine, engine.isRunning, let playerNode,
                  let inFmt = spkInputFormat, let converter = spkConverter else { return }
            guard pendingPlaybackBuffers < Self.maxPendingPlaybackBuffers else { return }
            let samples = pcm.count / 2
            guard samples > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(samples)),
                  let dst = inBuf.int16ChannelData?[0] else { return }
            inBuf.frameLength = AVAudioFrameCount(samples)
            pcm.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(dst, base, samples * 2)
            }
            updateSpeakerLevel(pcm: pcm, sampleCount: samples)
            guard let outBuf = convert(inBuf, with: converter, to: playbackFormat), engine.isRunning else { return }
            if !playerNode.isPlaying { playerNode.play() }
            pendingPlaybackBuffers += 1
            let generation = playbackGeneration
            playerNode.scheduleBuffer(outBuf) { [weak self] in
                self?.queue.async {
                    guard let self, self.playbackGeneration == generation else { return }
                    self.pendingPlaybackBuffers = max(0, self.pendingPlaybackBuffers - 1)
                }
            }
        }
    }

    func clearSpeaker(streamId: UInt32) {
        queue.async { [self] in
            guard spkStreamId == streamId else { return }
            // Instant barge-in flush without disturbing the running engine or mic VPIO tap.
            spkConverter?.reset()
            playbackGeneration &+= 1
            pendingPlaybackBuffers = 0
            if let engine, engine.isRunning, let playerNode {
                playerNode.stop()
                playerNode.reset()
                playerNode.play()
            }
            resetSpeakerLevel()
        }
    }

    func stopSpeaker(streamId: UInt32) {
        queue.async { [self] in
            guard spkStreamId == streamId else { return }
            spkStreamId = nil
            spkInputFormat = nil
            spkConverter = nil
            playbackGeneration &+= 1
            pendingPlaybackBuffers = 0
            if let engine, engine.isRunning, let playerNode {
                playerNode.stop()
                playerNode.reset()
            }
            resetSpeakerLevel()
        }
    }

    func stopAll() {
        queue.async { [self] in teardownSync() }
    }
}
#endif
