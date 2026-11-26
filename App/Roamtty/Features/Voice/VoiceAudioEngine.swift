#if canImport(AVFoundation)
import AVFoundation
import Foundation
import RoamttyDesktopCore

/// Microphone permission state for contextual confirmation sheet notices.
enum VoiceMicPermission: Equatable, Sendable {
    case undetermined, granted, denied
}

/// Full-duplex iOS voice audio engine for `agy /voice`:
/// - `AVAudioSession` in `.playAndRecord` + `.voiceChat` configured once per call (avoiding Bluetooth HFP renegotiation storms)
/// - Single reused `AVAudioEngine` + `AVAudioPlayerNode` with hardware VPIO AEC (`setVoiceProcessingEnabled(true)`) and non-VPIO fallback
/// - In-place restarts on `.AVAudioEngineConfigurationChange` (never deallocating `AVAudioEngine` while Apple's internal IO queues are active)
/// - Synchronous tap-buffer copy on CoreAudio's tap thread + deferred engine retirement on call end
/// - Pure Objective-C `@try/@catch` wrappers (zero Swift stack unwinding) around all `AVAudioEngine` / `AVAudioConverter` calls
final class VoiceAudioEngine: VoiceAudioIO, @unchecked Sendable {
    let queue = DispatchQueue(label: "roamtty.voice.audio", qos: .userInteractive)
    let sessionToken = UUID()
    let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    var captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    static let maxPendingPlaybackBuffers = 20
    static let levelThrottleNs: UInt64 = 66_000_000
    static let speakerKeepaliveNs: UInt64 = 200_000_000
    static let routeSettleSuppressNs: UInt64 = 800_000_000
    static let retiredEngineGraceMs = 1500
    static let levelMinDelta: Float = 0.03

    var engine: AVAudioEngine?
    var playerNode: AVAudioPlayerNode?
    var engineUsesVPIO = false
    var engineGraphAttached = false
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
            applyRouteLocked(force: true)
        }
    }

    /// Pre-warms `AVAudioSession` (`.playAndRecord` + `.voiceChat`) and `AVAudioEngine`
    /// when the call starts so `SPK_START` replies with `SPK_ACK` without cold-start timeout risk.
    func prepareSession(route next: VoiceAudioRoute) {
        queue.async { [self] in
            route = next
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
            guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true),
                  let converter = makeConverter(from: inFmt, to: playbackFormat, label: "startSpeaker.converter") else {
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
                restartPlayer(playerNode, label: "startSpeaker")
            }
            return .success(())
        }
    }

    func playSpeaker(streamId: UInt32, pcm: [UInt8]) {
        queue.async { [self] in
            autoreleasepool {
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
                let generation = playbackGeneration
                var err: NSError?
                let scheduled = RoamttyAudioPlayerScheduleBuffer(playerNode, outBuf, { [weak self] in
                    self?.queue.async {
                        guard let self, self.playbackGeneration == generation else { return }
                        self.pendingPlaybackBuffers = max(0, self.pendingPlaybackBuffers - 1)
                    }
                }, &err)
                if scheduled {
                    pendingPlaybackBuffers += 1
                } else {
                    logAudioError("playSpeaker.schedule", err)
                }
            }
        }
    }

    func clearSpeaker(streamId: UInt32) {
        queue.async { [self] in
            guard spkStreamId == streamId else { return }
            spkConverter?.reset()
            playbackGeneration &+= 1
            pendingPlaybackBuffers = 0
            if let engine, engine.isRunning, let playerNode {
                restartPlayer(playerNode, label: "clearSpeaker")
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
                var err: NSError?
                if !RoamttyAudioPlayerStop(playerNode, &err) { logAudioError("stopSpeaker", err) }
            }
            resetSpeakerLevel()
        }
    }

    func stopAll() {
        queue.async { [self] in teardownSync() }
    }

    // MARK: DSP & Level Metering (on `queue`)

    func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard input.format == converter.inputFormat else { return nil }
        let ratio = format.sampleRate / max(1, input.format.sampleRate)
        let capacity = max(1, AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var status: AVAudioConverterOutputStatus = .error
        var err: NSError?
        let ok = RoamttyAudioConverterConvert(converter, input, output, &status, &err)
        guard ok, status != .error, output.frameLength > 0 else {
            if let err { logAudioError("converter.convert", err) }
            return nil
        }
        return output
    }

    func updateMicLevel(samples: UnsafePointer<Int16>, count: Int) {
        var sumSq = 0.0
        for i in 0..<count {
            let s = Double(samples[i]) / 32768.0
            sumSq += s * s
        }
        let rms = Float(min(1.0, (sumSq / Double(max(1, count))).squareRoot() * 3.2))
        smoothedMicLevel = smoothedMicLevel * 0.65 + rms * 0.35
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastEmittedMicNs >= Self.levelThrottleNs,
              abs(smoothedMicLevel - lastEmittedMicLevel) > Self.levelMinDelta else { return }
        lastEmittedMicNs = now
        lastEmittedMicLevel = smoothedMicLevel
        onMicLevel?(smoothedMicLevel)
    }

    func updateSpeakerLevel(pcm: [UInt8], sampleCount: Int) {
        let count = min(sampleCount, pcm.count / 2)
        guard count > 0 else { return }
        var sumSq = 0.0
        for i in 0..<count {
            let lo = UInt16(pcm[i * 2])
            let hi = UInt16(pcm[i * 2 + 1]) << 8
            let s = Double(Int16(bitPattern: lo | hi)) / 32768.0
            sumSq += s * s
        }
        let rms = Float(min(1.0, (sumSq / Double(count)).squareRoot() * 2.8))
        smoothedSpkLevel = smoothedSpkLevel * 0.55 + rms * 0.45
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - lastEmittedSpkNs
        let activeFlip = (smoothedSpkLevel > 0.01) != (lastEmittedSpkLevel > 0.01)
        let deltaChanged = elapsed >= Self.levelThrottleNs && abs(smoothedSpkLevel - lastEmittedSpkLevel) > Self.levelMinDelta
        let keepalive = smoothedSpkLevel > 0.01 && elapsed >= Self.speakerKeepaliveNs
        guard activeFlip || deltaChanged || keepalive else { return }
        lastEmittedSpkNs = now
        lastEmittedSpkLevel = smoothedSpkLevel
        onSpeakerLevel?(smoothedSpkLevel)
    }

    func resetMicLevel() {
        smoothedMicLevel = 0
        lastEmittedMicNs = 0
        if lastEmittedMicLevel != 0 {
            lastEmittedMicLevel = 0
            onMicLevel?(0)
        }
    }

    func resetSpeakerLevel() {
        smoothedSpkLevel = 0
        lastEmittedSpkNs = 0
        if lastEmittedSpkLevel != 0 {
            lastEmittedSpkLevel = 0
            onSpeakerLevel?(0)
        }
    }
}
#endif
