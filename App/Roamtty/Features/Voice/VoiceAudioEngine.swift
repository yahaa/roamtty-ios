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
/// - Resampling mic capture to 16 kHz mono Int16 LE (`640 B` / 20 ms chunks) + smoothed RMS level (`0...1`)
/// - `AVAudioPlayerNode` honoring dynamic `SPK_START` sample rates + instant `stop/reset/play` barge-in on `SPK_CLEAR`
final class VoiceAudioEngine: VoiceAudioIO, @unchecked Sendable {
    private let queue = DispatchQueue(label: "roamtty.voice.audio", qos: .userInteractive)
    private let lock = NSLock()
    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var captureConverter: AVAudioConverter?
    private var captureTapInstalled = false
    private var captureBuffer: [UInt8] = []
    private var micStreamId: UInt32?
    private var micCallback: (@Sendable (UInt32, [UInt8]) -> Void)?

    private var spkStreamId: UInt32?
    private var spkInputFormat: AVAudioFormat?
    private var spkConverter: AVAudioConverter?
    private var route: VoiceAudioRoute = .speaker
    private var smoothedMicLevel: Float = 0
    private var smoothedSpkLevel: Float = 0
    private var sessionActive = false

    var onMicLevel: ((Float) -> Void)?
    var onSpeakerLevel: ((Float) -> Void)?
    var onRouteChanged: ((VoiceAudioRoute) -> Void)?

    private var routeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    init() {
        registerAudioNotifications()
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
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
            _ = ensureEngineRunning()
            applyRouteLocked()
        }
    }

    // MARK: VoiceAudioIO

    func startMic(streamId: UInt32, sampleRate: UInt32, channels: UInt8, onPcm: @escaping @Sendable (UInt32, [UInt8]) -> Void) {
        queue.async { [self] in
            micStreamId = streamId
            micCallback = onPcm
            captureBuffer.removeAll(keepingCapacity: true)
            guard ensureEngineRunning() else { return }
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
            smoothedMicLevel = 0
            onMicLevel?(0)
            teardownIfIdle()
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
            guard ensureEngineRunning() else {
                return .failure(VoiceAudioError("audio engine unavailable"))
            }
            spkStreamId = streamId
            spkInputFormat = inFmt
            spkConverter = converter
            if let playerNode, !playerNode.isPlaying { playerNode.play() }
            return .success(())
        }
    }

    func playSpeaker(streamId: UInt32, pcm: [UInt8]) {
        queue.async { [self] in
            guard spkStreamId == streamId, !pcm.isEmpty,
                  let playerNode, let inFmt = spkInputFormat, let converter = spkConverter else { return }
            let samples = pcm.count / 2
            guard samples > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(samples)),
                  let dst = inBuf.int16ChannelData?[0] else { return }
            inBuf.frameLength = AVAudioFrameCount(samples)
            pcm.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(dst, base, samples * 2)
            }
            updateSpeakerLevel(pcm: pcm, sampleCount: samples)
            guard let outBuf = convert(inBuf, with: converter, to: playbackFormat) else { return }
            if !playerNode.isPlaying { playerNode.play() }
            playerNode.scheduleBuffer(outBuf, completionHandler: nil)
        }
    }

    func clearSpeaker(streamId: UInt32) {
        queue.async { [self] in
            guard spkStreamId == streamId, let playerNode else { return }
            // Instant barge-in flush without disturbing the running engine or mic VPIO tap.
            spkConverter?.reset()
            playerNode.stop()
            playerNode.reset()
            playerNode.play()
            smoothedSpkLevel = 0
            onSpeakerLevel?(0)
        }
    }

    func stopSpeaker(streamId: UInt32) {
        queue.async { [self] in
            guard spkStreamId == streamId else { return }
            spkStreamId = nil
            spkInputFormat = nil
            spkConverter = nil
            playerNode?.stop()
            playerNode?.reset()
            smoothedSpkLevel = 0
            onSpeakerLevel?(0)
            teardownIfIdle()
        }
    }

    func stopAll() {
        queue.async { [self] in teardownSync() }
    }
}

// MARK: - Engine lifecycle, DSP, and session notifications (on `queue`)
private extension VoiceAudioEngine {
    func ensureEngineRunning() -> Bool {
        if let engine, engine.isRunning { return true }
        do {
            try configureAudioSession()
            let eng = AVAudioEngine()
            let player = AVAudioPlayerNode()
            // Hardware Voice Processing I/O (AEC + AGC + NS) must be enabled before start.
            try? eng.inputNode.setVoiceProcessingEnabled(true)
            eng.attach(player)
            eng.connect(player, to: eng.mainMixerNode, format: playbackFormat)
            eng.prepare()
            try eng.start()
            player.play()
            engine = eng
            playerNode = player
            return true
        } catch {
            NSLog("RoamttyVoice: audio engine failed to start: \(error)")
            teardownSync()
            return false
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try? session.setPreferredSampleRate(16_000)
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        sessionActive = true
        applyRouteLocked()
    }

    private func applyRouteLocked() {
        guard sessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        switch route {
        case .speaker:
            try? session.overrideOutputAudioPort(.speaker)
        case .earpiece:
            try? session.overrideOutputAudioPort(.none)
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
            }
        case .bluetooth:
            try? session.overrideOutputAudioPort(.none)
            let btTypes: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE]
            if let bt = session.availableInputs?.first(where: { btTypes.contains($0.portType) }) {
                try? session.setPreferredInput(bt)
            }
        }
    }

    private func installCaptureTapIfNeeded() {
        guard !captureTapInstalled, let engine else { return }
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else { return }
        captureConverter = AVAudioConverter(from: hwFormat, to: captureFormat)
        guard captureConverter != nil else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.processMicBuffer(buffer)
        }
        captureTapInstalled = true
    }

    private func removeCaptureTap() {
        guard captureTapInstalled else { return }
        engine?.inputNode.removeTap(onBus: 0)
        captureTapInstalled = false
        captureConverter = nil
    }

    private func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard let streamId = micStreamId, let callback = micCallback, let converter = captureConverter else { return }
            guard let outBuf = convert(buffer, with: converter, to: captureFormat),
                  let samples = outBuf.int16ChannelData?[0], outBuf.frameLength > 0 else { return }
            let count = Int(outBuf.frameLength)
            let byteCount = count * 2
            var bytes = [UInt8](repeating: 0, count: byteCount)
            bytes.withUnsafeMutableBytes { dst in
                guard let base = dst.baseAddress else { return }
                memcpy(base, samples, byteCount)
            }
            updateMicLevel(samples: samples, count: count)
            captureBuffer.append(contentsOf: bytes)
            let chunk = VoiceProtocol.micChunkBytes
            while captureBuffer.count >= chunk {
                let slice = Array(captureBuffer[0..<chunk])
                captureBuffer.removeFirst(chunk)
                callback(streamId, slice)
            }
        }
    }

    private func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / max(1, input.format.sampleRate)
        let capacity = max(1, AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    private func updateMicLevel(samples: UnsafePointer<Int16>, count: Int) {
        var sumSq = 0.0
        for i in 0..<count {
            let s = Double(samples[i]) / 32768.0
            sumSq += s * s
        }
        let rms = Float(min(1.0, (sumSq / Double(max(1, count))).squareRoot() * 3.2))
        smoothedMicLevel = smoothedMicLevel * 0.65 + rms * 0.35
        onMicLevel?(smoothedMicLevel)
    }

    private func updateSpeakerLevel(pcm: [UInt8], sampleCount: Int) {
        var sumSq = 0.0
        pcm.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<min(sampleCount, ptr.count) {
                let s = Double(Int16(littleEndian: ptr[i])) / 32768.0
                sumSq += s * s
            }
        }
        let rms = Float(min(1.0, (sumSq / Double(max(1, sampleCount))).squareRoot() * 2.8))
        smoothedSpkLevel = smoothedSpkLevel * 0.55 + rms * 0.45
        onSpeakerLevel?(smoothedSpkLevel)
    }

    private func teardownIfIdle() {
        guard micStreamId == nil && spkStreamId == nil else { return }
        teardownSync()
    }

    private func teardownSync() {
        removeCaptureTap()
        playerNode?.stop()
        playerNode?.reset()
        engine?.stop()
        engine = nil
        playerNode = nil
        spkInputFormat = nil
        spkConverter = nil
        micStreamId = nil
        spkStreamId = nil
        micCallback = nil
        captureBuffer.removeAll(keepingCapacity: false)
        smoothedMicLevel = 0
        smoothedSpkLevel = 0
        if sessionActive {
            sessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func registerAudioNotifications() {
        let nc = NotificationCenter.default
        routeObserver = nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.sessionActive else { return }
                let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
                let btTypes: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]
                let detected: VoiceAudioRoute
                if outputs.contains(where: { btTypes.contains($0.portType) }) {
                    detected = .bluetooth
                } else if outputs.contains(where: { $0.portType == .builtInSpeaker }) {
                    detected = .speaker
                } else {
                    detected = .earpiece
                }
                if detected != self.route {
                    self.route = detected
                    self.onRouteChanged?(detected)
                }
            }
        }
        interruptionObserver = nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .ended {
                self.queue.async {
                    guard self.micStreamId != nil || self.spkStreamId != nil else { return }
                    _ = self.ensureEngineRunning()
                    if self.micStreamId != nil { self.installCaptureTapIfNeeded() }
                }
            }
        }
    }
}
#endif
