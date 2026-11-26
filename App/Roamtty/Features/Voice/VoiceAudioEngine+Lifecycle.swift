#if canImport(AVFoundation)
import AVFoundation
import Foundation
import RoamttyDesktopCore

// MARK: - Engine lifecycle, DSP, and session notifications (on `queue`)
extension VoiceAudioEngine {
    @discardableResult
    func safelyRunAudio(_ label: String, _ body: () -> Void) -> Bool {
        var nsError: NSError?
        let ok = RoamttyTryObjC(body, &nsError)
        if !ok {
            let desc = nsError?.localizedDescription ?? "unknown NSException"
            NSLog("RoamttyVoice: ObjC exception in \(label): \(desc)")
            Diagnostics.shared.log("voice-audio-exception", "\(label): \(desc)")
        }
        return ok
    }

    func ensureEngineRunning() -> Bool {
        if let engine, engine.isRunning { return true }
        tearDownEngineOnly()
        do {
            try configureAudioSession()
        } catch {
            NSLog("RoamttyVoice: audio session failed: \(error)")
            Diagnostics.shared.log("voice-session-error", "\(error)")
            return false
        }
        if !vpioFailed, buildAndStartEngine(useVPIO: true) { return true }
        if !vpioFailed {
            vpioFailed = true
            Diagnostics.shared.log("voice-vpio-fallback", "retrying without VPIO")
        }
        return buildAndStartEngine(useVPIO: false)
    }

    private func buildAndStartEngine(useVPIO: Bool) -> Bool {
        tearDownEngineOnly()
        let eng = AVAudioEngine()
        let player = AVAudioPlayerNode()
        var swiftError: Error?
        var tapInstalled = false
        let started = safelyRunAudio(useVPIO ? "engine.start.vpio" : "engine.start.plain") {
            let input = eng.inputNode
            let output = eng.outputNode
            if useVPIO {
                do { try input.setVoiceProcessingEnabled(true) } catch { swiftError = error; return }
            }
            eng.attach(player)
            eng.connect(player, to: eng.mainMixerNode, format: playbackFormat)
            eng.connect(eng.mainMixerNode, to: output, format: nil)
            tapInstalled = installTapIfFormatReady(on: input)
            eng.prepare()
            do { try eng.start() } catch { swiftError = error; return }
            if !tapInstalled { tapInstalled = installTapIfFormatReady(on: input) }
            if eng.isRunning { player.play() }
        }
        guard started, swiftError == nil, eng.isRunning else {
            if let swiftError {
                NSLog("RoamttyVoice: engine start failed (vpio=\(useVPIO)): \(swiftError)")
                Diagnostics.shared.log("voice-engine-error", "vpio=\(useVPIO) \(swiftError)")
            }
            _ = safelyRunAudio("engine.cleanup") {
                if tapInstalled { eng.inputNode.removeTap(onBus: 0) }
                eng.stop()
            }
            return false
        }
        engine = eng
        playerNode = player
        captureTapInstalled = tapInstalled
        captureConverter = nil
        lastHardwareSampleRate = AVAudioSession.sharedInstance().sampleRate
        suppressRouteRebuildUntilNs = DispatchTime.now().uptimeNanoseconds + Self.routeSettleSuppressNs
        Diagnostics.shared.log("voice-engine-started", "vpio=\(useVPIO) rate=\(Int(lastHardwareSampleRate)) tap=\(tapInstalled)")
        return true
    }

    private func installTapIfFormatReady(on input: AVAudioInputNode) -> Bool {
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return false }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.processMicBuffer(buffer)
        }
        return true
    }

    func configureAudioSession() throws {
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        try AudioSessionCoordinator.shared.activate(token: sessionToken, role: .voice) { session in
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            try? session.setPreferredIOBufferDuration(0.02)
        }
        sessionActive = true
        applyRouteLocked(force: false)
    }

    func applyRouteLocked(force: Bool = true) {
        guard sessionActive else { return }
        AudioSessionCoordinator.shared.withActiveSession(token: sessionToken) { session in
            let current = Self.detectRoute(session)
            if !force && current == route { return }
            switch route {
            case .speaker:
                Self.selectBuiltInInputIfNeeded(session)
                if current != .speaker { try? session.overrideOutputAudioPort(.speaker) }
            case .earpiece:
                Self.selectBuiltInInputIfNeeded(session)
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

    private static func selectBuiltInInputIfNeeded(_ session: AVAudioSession) {
        let currentIn = session.currentRoute.inputs.first?.portType
        guard currentIn != .builtInMic else { return }
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        } else {
            try? session.setPreferredInput(nil)
        }
    }

    private static func detectRoute(_ session: AVAudioSession) -> VoiceAudioRoute {
        let outputs = session.currentRoute.outputs
        let btTypes: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]
        if outputs.contains(where: { btTypes.contains($0.portType) }) { return .bluetooth }
        if outputs.contains(where: { $0.portType == .builtInSpeaker }) { return .speaker }
        return .earpiece
    }

    func scheduleRebuild(delayMs: Int = 250) {
        pendingRebuild?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRebuild = nil
            self.rebuildEngine()
        }
        pendingRebuild = item
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: item)
    }

    func rebuildEngine() {
        guard sessionActive, !interrupted else { return }
        tearDownEngineOnly()
        captureBuffer.removeAll(keepingCapacity: true)
        guard ensureEngineRunning() else { return }
        if spkStreamId != nil, let inFmt = spkInputFormat {
            spkConverter = AVAudioConverter(from: inFmt, to: playbackFormat)
            if let engine, engine.isRunning, let playerNode, !playerNode.isPlaying {
                _ = safelyRunAudio("rebuild.play") { playerNode.play() }
            }
        }
    }

    func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, !self.interrupted,
                  let streamId = self.micStreamId, let callback = self.micCallback,
                  buffer.frameLength > 0,
                  buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else { return }
            let srcBuf = self.extractMonoIfNeeded(buffer) ?? buffer
            if self.captureConverter == nil
                || self.captureConverter?.inputFormat != srcBuf.format
                || self.captureConverter?.outputFormat != self.captureFormat {
                self.captureConverter = AVAudioConverter(from: srcBuf.format, to: self.captureFormat)
            }
            guard let converter = self.captureConverter,
                  let outBuf = self.convert(srcBuf, with: converter, to: self.captureFormat),
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

    /// Down-selects channel 0 from multi-channel VPIO aggregate formats (e.g. 2/4/9-ch iPhone mic arrays)
    /// into a clean mono Float32 buffer so `AVAudioConverter` never fails or throws on channel layout mismatches.
    private func extractMonoIfNeeded(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.channelCount > 1,
              let src = buffer.floatChannelData?[0],
              let monoFmt = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: buffer.frameLength),
              let dst = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = buffer.frameLength
        memcpy(dst, src, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        return mono
    }

    func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard input.format == converter.inputFormat else { return nil }
        let ratio = format.sampleRate / max(1, input.format.sampleRate)
        let capacity = max(1, AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        var status: AVAudioConverterOutputStatus = .error
        let ok = safelyRunAudio("converter.convert") {
            status = converter.convert(to: output, error: &error) { _, outStatus in
                if supplied { outStatus.pointee = .noDataNow; return nil }
                supplied = true
                outStatus.pointee = .haveData
                return input
            }
        }
        guard ok, status != .error, output.frameLength > 0 else { return nil }
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

    func tearDownEngineOnly() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        let oldEngine = engine
        let oldPlayer = playerNode
        let hadTap = captureTapInstalled
        captureTapInstalled = false
        captureConverter = nil
        playbackGeneration &+= 1
        pendingPlaybackBuffers = 0
        engine = nil
        playerNode = nil
        guard let oldEngine else { return }
        _ = safelyRunAudio("tearDownEngineOnly") {
            if hadTap { oldEngine.inputNode.removeTap(onBus: 0) }
            if oldEngine.isRunning { oldPlayer?.stop() }
            oldEngine.stop()
        }
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
        vpioFailed = false
        lastHardwareSampleRate = 0
        suppressRouteRebuildUntilNs = 0
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
            let detected = Self.detectRoute(session)
            if detected != self.route {
                self.route = detected
                self.onRouteChanged?(detected)
            }
            let settled = DispatchTime.now().uptimeNanoseconds >= self.suppressRouteRebuildUntilNs
            let rateChanged = settled && session.sampleRate > 0 && self.lastHardwareSampleRate > 0 && session.sampleRate != self.lastHardwareSampleRate
            if !self.interrupted && (rateChanged || self.engine?.isRunning != true) {
                self.scheduleRebuild(delayMs: 250)
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
                self.scheduleRebuild(delayMs: 250)
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
            Diagnostics.shared.log("voice-engine-config-change")
            self.tearDownEngineOnly()
            self.scheduleRebuild(delayMs: 250)
        }
    }
}
#endif
