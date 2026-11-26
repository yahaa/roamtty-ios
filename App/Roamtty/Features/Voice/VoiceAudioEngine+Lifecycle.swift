#if canImport(AVFoundation)
import AVFoundation
import Foundation
import RoamttyDesktopCore

// MARK: - Engine lifecycle, DSP, and session notifications (on `queue`)
extension VoiceAudioEngine {
    func ensureEngineRunning() -> Bool {
        if let engine, engine.isRunning { return true }
        tearDownEngineOnly()
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
            if eng.isRunning { player.play() }
            engine = eng
            playerNode = player
            lastHardwareSampleRate = AVAudioSession.sharedInstance().sampleRate
            return true
        } catch {
            NSLog("RoamttyVoice: audio engine failed to start: \(error)")
            tearDownEngineOnly()
            return false
        }
    }

    func configureAudioSession() throws {
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]
        try AudioSessionCoordinator.shared.activate(token: sessionToken, role: .voice) { session in
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            try? session.setPreferredSampleRate(Double(VoiceProtocol.defaultMicSampleRate))
            try? session.setPreferredIOBufferDuration(0.02)
        }
        sessionActive = true
        applyRouteLocked()
    }

    func applyRouteLocked() {
        guard sessionActive else { return }
        AudioSessionCoordinator.shared.withActiveSession(token: sessionToken) { session in
            switch route {
            case .speaker:
                if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                    try? session.setPreferredInput(builtIn)
                } else {
                    try? session.setPreferredInput(nil)
                }
                try? session.overrideOutputAudioPort(.speaker)
            case .earpiece:
                if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                    try? session.setPreferredInput(builtIn)
                } else {
                    try? session.setPreferredInput(nil)
                }
                try? session.overrideOutputAudioPort(.none)
            case .bluetooth:
                let btTypes: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE]
                if let bt = session.availableInputs?.first(where: { btTypes.contains($0.portType) }) {
                    try? session.setPreferredInput(bt)
                }
                try? session.overrideOutputAudioPort(.none)
            }
        }
    }

    func rebuildEngine() {
        guard sessionActive, !interrupted else { return }
        tearDownEngineOnly()
        captureBuffer.removeAll(keepingCapacity: true)
        guard ensureEngineRunning() else { return }
        if micStreamId != nil { installCaptureTapIfNeeded() }
        if spkStreamId != nil, let inFmt = spkInputFormat {
            spkConverter = AVAudioConverter(from: inFmt, to: playbackFormat)
            if let engine, engine.isRunning, let playerNode, !playerNode.isPlaying {
                playerNode.play()
            }
        }
    }

    func installCaptureTapIfNeeded() {
        guard !captureTapInstalled, let engine, engine.isRunning else { return }
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

    func removeCaptureTap() {
        guard captureTapInstalled else { return }
        engine?.inputNode.removeTap(onBus: 0)
        captureTapInstalled = false
        captureConverter = nil
    }

    func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, !self.interrupted,
                  let streamId = self.micStreamId, let callback = self.micCallback,
                  let converter = self.captureConverter else { return }
            guard let outBuf = self.convert(buffer, with: converter, to: self.captureFormat),
                  let samples = outBuf.int16ChannelData?[0], outBuf.frameLength > 0 else { return }
            let sampleCount = Int(outBuf.frameLength) * Int(self.captureFormat.channelCount)
            let byteCount = sampleCount * 2
            var bytes = [UInt8](repeating: 0, count: byteCount)
            bytes.withUnsafeMutableBytes { dst in
                guard let base = dst.baseAddress else { return }
                memcpy(base, samples, byteCount)
            }
            self.updateMicLevel(samples: samples, count: sampleCount)
            self.captureBuffer.append(contentsOf: bytes)
            let chunk = VoiceProtocol.micChunkBytes
            while self.captureBuffer.count >= chunk {
                let slice = Array(self.captureBuffer[0..<chunk])
                self.captureBuffer.removeFirst(chunk)
                callback(streamId, slice)
            }
        }
    }

    func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
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

    func tearDownEngineOnly() {
        removeCaptureTap()
        playbackGeneration &+= 1
        pendingPlaybackBuffers = 0
        if let engine, engine.isRunning, let playerNode {
            playerNode.stop()
            playerNode.reset()
        }
        engine?.stop()
        engine = nil
        playerNode = nil
    }

    func teardownSync() {
        tearDownEngineOnly()
        spkInputFormat = nil
        spkConverter = nil
        micStreamId = nil
        spkStreamId = nil
        micCallback = nil
        captureBuffer.removeAll(keepingCapacity: false)
        smoothedMicLevel = 0
        smoothedSpkLevel = 0
        lastEmittedMicLevel = -1
        lastEmittedSpkLevel = -1
        lastEmittedMicNs = 0
        lastEmittedSpkNs = 0
        interrupted = false
        lastHardwareSampleRate = 0
        if sessionActive {
            sessionActive = false
            AudioSessionCoordinator.shared.deactivate(token: sessionToken)
        }
    }

    func registerAudioNotifications() {
        let nc = NotificationCenter.default
        routeObserver = nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.handleRouteChange()
        }
        interruptionObserver = nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            self?.handleInterruption(note)
        }
        configChangeObserver = nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
            self?.handleConfigurationChange(note)
        }
    }

    private func handleRouteChange() {
        queue.async { [weak self] in
            guard let self, self.sessionActive else { return }
            let session = AVAudioSession.sharedInstance()
            let outputs = session.currentRoute.outputs
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
            let rateChanged = session.sampleRate > 0 && self.lastHardwareSampleRate > 0 && session.sampleRate != self.lastHardwareSampleRate
            let tapFormatChanged = self.captureTapInstalled && self.engine.map {
                $0.inputNode.outputFormat(forBus: 0).sampleRate != self.captureConverter?.inputFormat.sampleRate
            } ?? false
            if !self.interrupted && (rateChanged || tapFormatChanged || self.engine?.isRunning != true) {
                self.rebuildEngine()
            }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                self.interrupted = true
                self.tearDownEngineOnly()
                self.resetMicLevel()
                self.resetSpeakerLevel()
            case .ended:
                self.interrupted = false
                guard self.sessionActive else { return }
                self.rebuildEngine()
            @unknown default:
                break
            }
        }
    }

    private func handleConfigurationChange(_ note: Notification) {
        let sender = note.object as AnyObject?
        queue.async { [weak self] in
            guard let self, self.sessionActive, !self.interrupted,
                  let eng = self.engine, sender === eng else { return }
            self.rebuildEngine()
        }
    }
}
#endif
