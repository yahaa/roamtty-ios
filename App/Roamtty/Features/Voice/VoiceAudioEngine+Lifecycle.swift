#if canImport(AVFoundation)
import AVFoundation
import Foundation
import RoamttyDesktopCore

// MARK: - Engine lifecycle, pull-mode source node, capture DSP, and session notifications (on `queue`)
extension VoiceAudioEngine {
    func logAudioError(_ label: String, _ error: Error?) {
        let desc = error?.localizedDescription ?? "unknown error"
        NSLog("RoamttyVoice: \(label): \(desc)")
        Diagnostics.shared.log("voice-audio-error", "\(label): \(desc)")
    }

    func makeConverter(from: AVAudioFormat, to: AVAudioFormat, label: String) -> AVAudioConverter? {
        var err: NSError?
        let converter = RoamttyAudioConverterCreate(from, to, &err)
        if converter == nil, let err { logAudioError(label, err) }
        return converter
    }

    func ensureEngineRunning(forceRestart: Bool = false) -> Bool {
        if !forceRestart, let engine, engine.isRunning { return true }
        pendingRebuild?.cancel()
        pendingRebuild = nil
        if !sessionActive {
            do {
                try configureAudioSession()
            } catch {
                logAudioError("configureAudioSession", error)
                return false
            }
        }
        // Prefer restarting the existing engine in-place rather than deallocating/recreating it,
        // so Apple's internal IOUnitConfigurationChanged queue never races `-[AVAudioEngine dealloc]`.
        if let existing = engine, let existingSource = sourceNode {
            if startExistingEngine(existing, source: existingSource) { return true }
            let wasVPIO = engineUsesVPIO
            retireCurrentEngineDeferred()
            if wasVPIO && !vpioFailed {
                vpioFailed = true
                Diagnostics.shared.log("voice-vpio-fallback", "in-place restart failed; retrying without VPIO")
            }
        }
        if !vpioFailed {
            if createAndStartEngine(useVPIO: true) { return true }
            vpioFailed = true
            Diagnostics.shared.log("voice-vpio-fallback", "retrying without VPIO")
        }
        return createAndStartEngine(useVPIO: false)
    }

    private func createAndStartEngine(useVPIO: Bool) -> Bool {
        retireCurrentEngineDeferred()
        let eng = AVAudioEngine()
        let ring = pcmRing
        let source = AVAudioSourceNode(format: playbackFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            if let first = abl.first, let ptr = first.mData?.assumingMemoryBound(to: Float.self) {
                ring.readRealtime(into: ptr, frameCount: frames)
                if abl.count > 1 {
                    for i in 1..<abl.count {
                        if let ch = abl[i].mData?.assumingMemoryBound(to: Float.self) {
                            memcpy(ch, ptr, frames * MemoryLayout<Float>.size)
                        }
                    }
                }
            }
            return noErr
        }
        var err: NSError?

        // Access inputNode and enable VPIO once on the fresh stopped engine.
        // Do NOT manually call `eng.connect(eng.mainMixerNode, to: eng.outputNode, ...)`:
        // accessing `mainMixerNode` lets AVAudioEngine manage the VPIO mixer->output link natively.
        let input = eng.inputNode
        if useVPIO, !RoamttyAudioSetVoiceProcessing(input, true, &err) {
            logAudioError("setVoiceProcessing(true)", err)
            retireEngineDeferred(eng, source: source)
            return false
        }
        guard RoamttyAudioEngineAttach(eng, source, &err) else {
            logAudioError("attach(source)", err)
            retireEngineDeferred(eng, source: source)
            return false
        }
        engine = eng
        sourceNode = source
        engineUsesVPIO = useVPIO
        engineGraphAttached = true

        if startExistingEngine(eng, source: source) { return true }
        retireCurrentEngineDeferred()
        return false
    }

    private func startExistingEngine(_ eng: AVAudioEngine, source: AVAudioSourceNode) -> Bool {
        autoreleasepool {
            var err: NSError?
            let input = eng.inputNode
            if captureTapInstalled {
                _ = RoamttyAudioNodeRemoveTap(input, 0, &err)
                captureTapInstalled = false
            }
            if eng.isRunning {
                _ = RoamttyAudioEngineStop(eng, false, &err)
            }
            err = nil
            guard RoamttyAudioEngineConnect(eng, source, eng.mainMixerNode, playbackFormat, &err) else {
                logAudioError("connect(source->mixer)", err)
                return false
            }
            var tapInstalled = installTapIfFormatReady(on: input)
            err = nil
            guard RoamttyAudioEngineStart(eng, &err), eng.isRunning else {
                logAudioError(engineUsesVPIO ? "engine.start.vpio" : "engine.start.plain", err)
                if tapInstalled { _ = RoamttyAudioNodeRemoveTap(input, 0, &err) }
                _ = RoamttyAudioEngineStop(eng, false, &err)
                return false
            }
            if !tapInstalled { tapInstalled = installTapIfFormatReady(on: input) }

            captureTapInstalled = tapInstalled
            captureConverter = nil
            pcmRing.clear()
            lastHardwareSampleRate = AVAudioSession.sharedInstance().sampleRate
            suppressRouteRebuildUntilNs = DispatchTime.now().uptimeNanoseconds + Self.routeSettleSuppressNs
            Diagnostics.shared.log(
                "voice-engine-started",
                "vpio=\(engineUsesVPIO) rate=\(Int(lastHardwareSampleRate)) tap=\(tapInstalled) pull=1"
            )
            return true
        }
    }

    private func installTapIfFormatReady(on input: AVAudioInputNode) -> Bool {
        var err: NSError?
        guard let fmt = RoamttyAudioNodeOutputFormat(input, 0, &err),
              fmt.sampleRate > 0, fmt.channelCount > 0 else {
            if let err { logAudioError("input.outputFormat", err) }
            return false
        }
        // Match tap size to 20 ms at the active hardware sample rate (e.g. 320 frames on 16 kHz Bluetooth HFP
        // instead of 1024 frames = 64 ms, and 960 frames on 48 kHz built-in mic).
        let tapFrames = AVAudioFrameCount(max(160, min(1024, Int((fmt.sampleRate * 0.02).rounded()))))
        err = nil
        let installed = RoamttyAudioNodeInstallTap(input, 0, tapFrames, nil, { [weak self] buffer, _ in
            guard let self, let copy = Self.copyMonoFloatBuffer(buffer) else { return }
            self.processCopiedMicBuffer(copy)
        }, &err)
        if !installed { logAudioError("installTap", err) }
        return installed
    }

    /// Synchronously extracts a standalone mono Float32 copy of channel 0 from any CoreAudio tap buffer.
    static func copyMonoFloatBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, rate > 0, channels > 0,
              let monoFmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: buffer.frameLength),
              let dst = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = buffer.frameLength
        if let floatData = buffer.floatChannelData {
            if buffer.format.isInterleaved && channels > 1 {
                let src = floatData[0]
                for i in 0..<frames { dst[i] = src[i * channels] }
            } else {
                memcpy(dst, floatData[0], frames * MemoryLayout<Float>.size)
            }
            return mono
        }
        if let int16Data = buffer.int16ChannelData {
            let src = int16Data[0]
            let stride = buffer.format.isInterleaved ? channels : 1
            for i in 0..<frames { dst[i] = Float(src[i * stride]) / 32768.0 }
            return mono
        }
        return nil
    }

    func configureAudioSession() throws {
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        try AudioSessionCoordinator.shared.activate(token: sessionToken, role: .voice) { session in
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            if !routeExplicitlyChosen {
                try? session.setPreferredInput(nil)
                try? session.overrideOutputAudioPort(.none)
            }
            // 10 ms low-latency IO cycle cuts duplex hardware turnaround latency.
            try? session.setPreferredIOBufferDuration(0.01)
        }
        sessionActive = true
        if routeExplicitlyChosen {
            applyRouteLocked(force: false)
        } else {
            AudioSessionCoordinator.shared.withActiveSession(token: sessionToken) { session in
                let detected = Self.detectRoute(session)
                route = detected
                onRouteChanged?(detected)
            }
        }
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
                let currentIn = session.currentRoute.inputs.first?.portType
                if currentIn.map({ !btTypes.contains($0) }) ?? true,
                   let bt = session.availableInputs?.first(where: { btTypes.contains($0.portType) }) {
                    try? session.setPreferredInput(bt)
                }
                if current == .speaker { try? session.overrideOutputAudioPort(.none) }
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
        let ports = Set(session.currentRoute.outputs.map(\.portType))
        if !ports.isDisjoint(with: [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]) { return .bluetooth }
        return ports.contains(.builtInSpeaker) ? .speaker : .earpiece
    }

    func scheduleRebuild(delayMs: Int = 350) {
        pendingRebuild?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRebuild = nil
            self.restartInPlaceAfterChange()
        }
        pendingRebuild = item
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: item)
    }

    private func restartInPlaceAfterChange() {
        guard sessionActive, !interrupted else { return }
        captureBuffer.removeAll(keepingCapacity: true)
        capturePreprocessor.reset()
        guard ensureEngineRunning(forceRestart: true) else { return }
        if spkStreamId != nil {
            spkResampler = VoiceLinearResampler(inputRate: Double(spkSampleRate), outputRate: playbackFormat.sampleRate)
        }
    }

    func processCopiedMicBuffer(_ srcBuf: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            autoreleasepool {
                guard let self, !self.interrupted,
                      let streamId = self.micStreamId, let callback = self.micCallback,
                      srcBuf.frameLength > 0,
                      srcBuf.format.sampleRate > 0, srcBuf.format.channelCount > 0 else { return }
                if self.captureConverter == nil
                    || self.captureConverter?.inputFormat != srcBuf.format
                    || self.captureConverter?.outputFormat != self.captureFormat {
                    self.captureConverter = self.makeConverter(from: srcBuf.format, to: self.captureFormat, label: "mic.converter")
                }
                guard let converter = self.captureConverter,
                      let outBuf = self.convert(srcBuf, with: converter, to: self.captureFormat),
                      let samples = outBuf.int16ChannelData?[0], outBuf.frameLength > 0 else { return }
                let sampleCount = Int(outBuf.frameLength) * Int(self.captureFormat.channelCount)
                // 80 Hz high-pass filter + soft-knee limiter before Opus encoding.
                self.capturePreprocessor.processInPlace(samples, count: sampleCount)
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
    }

    private func pauseCurrentEngine() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        captureConverter = nil
        pcmRing.clear()
        guard let eng = engine else { return }
        var err: NSError?
        if captureTapInstalled {
            _ = RoamttyAudioNodeRemoveTap(eng.inputNode, 0, &err)
            captureTapInstalled = false
        }
        _ = RoamttyAudioEngineStop(eng, false, &err)
    }

    private func retireCurrentEngineDeferred() {
        pendingRebuild?.cancel()
        pendingRebuild = nil
        let oldEngine = engine
        let oldSource = sourceNode
        let hadTap = captureTapInstalled
        let wasAttached = engineGraphAttached
        captureTapInstalled = false
        engineGraphAttached = false
        engineUsesVPIO = false
        captureConverter = nil
        pcmRing.clear()
        engine = nil
        sourceNode = nil
        guard let oldEngine else { return }
        var err: NSError?
        if hadTap { _ = RoamttyAudioNodeRemoveTap(oldEngine.inputNode, 0, &err) }
        _ = RoamttyAudioEngineStop(oldEngine, true, &err)
        if wasAttached, let oldSource { _ = RoamttyAudioEngineDetach(oldEngine, oldSource, &err) }
        retireEngineDeferred(oldEngine, source: oldSource)
    }

    private func retireEngineDeferred(_ oldEngine: AVAudioEngine, source oldSource: AVAudioSourceNode?) {
        queue.asyncAfter(deadline: .now() + .milliseconds(Self.retiredEngineGraceMs)) {
            _ = oldSource
            _ = oldEngine
        }
    }

    func teardownSync() {
        stopSpeakerPumpLocked()
        retireCurrentEngineDeferred()
        spkJitter = nil
        spkResampler = nil
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
                self.scheduleRebuild(delayMs: 350)
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
                self.pauseCurrentEngine()
                self.resetMicLevel()
                self.resetSpeakerLevel()
            case .ended:
                self.interrupted = false
                guard self.sessionActive else { return }
                self.scheduleRebuild(delayMs: 350)
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
            self.scheduleRebuild(delayMs: 350)
        }
    }
}
#endif
