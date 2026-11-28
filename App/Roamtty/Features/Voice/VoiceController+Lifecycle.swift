import Foundation
import RoamttyCore
import RoamttyDesktopCore

// MARK: - Session observation, remote stream lifecycle, timers, and UI test fixtures
extension VoiceController {
    func observe(_ voiceSession: VoiceSession, runtime: SessionRuntime, model: AppModel) {
        voiceSession.onPhase = { [weak self, weak voiceSession, weak runtime, weak model] phase in
            Task { @MainActor in
                guard let self, let voiceSession, let runtime, let model, self.session === voiceSession else { return }
                self.handlePhase(phase, runtime: runtime, model: model)
            }
        }
        voiceSession.onEvent = { [weak self, weak voiceSession, weak model] event in
            Task { @MainActor in
                guard let self, let voiceSession, let model, self.session === voiceSession else { return }
                self.handleStreamEvent(event, model: model)
            }
        }
        voiceSession.onNetworkPoor = { [weak self, weak voiceSession] poor in
            Task { @MainActor in
                guard let self, let voiceSession, self.session === voiceSession, self.active else { return }
                self.networkPoor = poor
            }
        }
        voiceSession.onEnded = { [weak self, weak voiceSession] _ in
            Task { @MainActor in
                guard let self, let voiceSession, self.session === voiceSession else { return }
                if !voiceSession.active { self.cleanupAfterEnd(reason: "session-ended") }
            }
        }
    }

    func handlePhase(_ phase: VoiceSessionPhase, runtime: SessionRuntime, model: AppModel) {
        switch phase {
        case .idle:
            cleanupAfterEnd(reason: "idle")
        case .connecting:
            recovering = false
            if active { ghostState = .connecting }
        case .recovering:
            recovering = true
            cancelStreamTimers()
            streamTracker.beginRecovery()
            if active { ghostState = .connecting }
        case .ready(let port, let udp):
            recovering = false; networkPoor = false; micPort = backend == .agy && port > 0 ? port : nil; onUdp = udp
            Diagnostics.shared.log("voice-ready", "backend=\(backend.rawValue) port=\(port) udp=\(udp)")
            model.markDesktopPluginInstalled(for: runtime.host.id)
            if !startKeySent {
                startKeySent = true
                if backend == .agy {
                    sendFunctionKey(mode.startFunctionKey, to: runtime)
                }
                ghostState = isMuted ? .muted : .listening(level: 0)
                startElapsedTimer()
                if backend == .agy && port != VoiceProtocol.defaultPort {
                    showToast(model.text(
                        "语音端口 24713 被占用，已改用 \(port)；若当前 agy 无响应请重启会话",
                        "Voice port 24713 is busy; using \(port). Restart agy if voice does not respond"
                    ))
                } else {
                    showToast(model.text("已接通，可以直接说话", "Connected — speak naturally"))
                }
                scheduleNoStreamHint(generation: startGeneration, model: model)
            } else if ghostState == .connecting {
                ghostState = isMuted ? .muted : .listening(level: 0)
            }
        case .failed(let message):
            Diagnostics.shared.log("voice-failed", message)
            errorMessage = message
            cleanupAfterEnd(reason: "failed")
        }
    }

    func handleStreamEvent(_ event: VoiceStreamEvent, model: AppModel) {
        switch event {
        case .micStarted:
            if !isMuted { ghostState = .listening(level: 0.15) }
        case .speakerCleared, .speakerStopped:
            speakerQuietTask?.cancel()
            if active { ghostState = isMuted ? .muted : .listening(level: 0) }
        case .micStopped, .speakerStarted, .speakerAudio:
            break
        }
        guard active else { return }
        switch streamTracker.handle(event, at: ProcessInfo.processInfo.systemUptime) {
        case .none:
            break
        case .streamActive:
            cancelStreamTimers()
        case .endedImmediately(let reason):
            if !recovering { finishFromRemote(reason: reason, model: model) }
        case .scheduleRemoteEnd(let reason):
            if !recovering { scheduleRemoteEnd(reason: reason, generation: startGeneration, model: model) }
        }
    }

    func updateSpeakerActivity(level: Double) {
        guard active else { return }
        if level <= 0.01 {
            if !isMuted, case .speaking = ghostState { ghostState = .listening(level: 0) }
            return
        }
        if !isMuted { ghostState = .speaking(level: level) }
        speakerQuietTask?.cancel()
        speakerQuietTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            guard let self, !Task.isCancelled, self.active else { return }
            if !self.isMuted, case .speaking = self.ghostState { self.ghostState = .listening(level: 0) }
        }
    }

    /// Cleanly hangs up this session's call (sending F7 and tearing down audio synchronously) when another session starts calling.
    func handoverStop(runtime: SessionRuntime) {
        stopInternal(sendHangup: true, runtime: runtime, reason: "handover", syncAudioTeardown: true)
    }

    func stopInternal(sendHangup: Bool, runtime: SessionRuntime? = nil, reason: String, syncAudioTeardown: Bool = false) {
        startGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        if let owner = loginOwner {
            boundModel?.logins.invalidateOwner(owner)
            boundModel?.logins.dismissPrompts(owner: owner)
            loginOwner = nil
        }
        let shouldSendF7 = sendHangup && startKeySent && backend == .agy
        #if DEBUG
        if shouldSendF7, !fixtureMode, let target = runtime ?? boundRuntime { sendFunctionKey(7, to: target) }
        #else
        if shouldSendF7, let target = runtime ?? boundRuntime { sendFunctionKey(7, to: target) }
        #endif
        session?.close()
        cleanupAfterEnd(reason: reason, syncAudioTeardown: syncAudioTeardown)
    }

    func cleanupAfterEnd(reason: String, syncAudioTeardown: Bool = false) {
        if active {
            Diagnostics.shared.log("voice-call-end", "reason=\(reason) elapsed=\(elapsedSeconds)s")
        }
        cancelStreamTimers()
        elapsedTimer?.cancel(); elapsedTimer = nil
        speakerQuietTask?.cancel(); speakerQuietTask = nil
        if syncAudioTeardown {
            audioEngine?.stopAllSync()
        } else {
            audioEngine?.stopAll()
        }
        audioEngine = nil
        session = nil
        streamTracker.reset(mode: mode)
        if let owner = loginOwner {
            boundModel?.logins.dismissPrompts(owner: owner)
            loginOwner = nil
        }
        active = false; recovering = false; networkPoor = false; popoverOpen = false; isMuted = false
        ghostState = .idle; micPort = nil; onUdp = false; startKeySent = false
        boundModel?.setVoiceCallActive(false)
    }

    func cancelStreamTimers() {
        remoteEndTask?.cancel(); remoteEndTask = nil
        noStreamHintTask?.cancel(); noStreamHintTask = nil
    }

    private func scheduleRemoteEnd(reason: VoiceRemoteEndReason, generation: UInt64, model: AppModel) {
        remoteEndTask?.cancel()
        remoteEndTask = Task { @MainActor [weak self, weak model] in
            try? await Task.sleep(for: .milliseconds(VoiceRemoteStreamTracker.remoteEndGraceMs))
            guard let self, let model, !Task.isCancelled,
                  self.active, !self.recovering, self.startGeneration == generation,
                  self.streamTracker.activeMicStreamId == nil,
                  self.streamTracker.activeSpkStreamId == nil else { return }
            self.finishFromRemote(reason: reason, model: model)
        }
    }

    private func scheduleNoStreamHint(generation: UInt64, model: AppModel) {
        #if DEBUG
        if fixtureMode { return }
        #endif
        guard !streamTracker.hadAnyStream else { return }
        noStreamHintTask?.cancel()
        noStreamHintTask = Task { @MainActor [weak self, weak model] in
            try? await Task.sleep(for: .seconds(VoiceRemoteStreamTracker.noStreamHintDelaySeconds))
            guard let self, let model, !Task.isCancelled,
                  self.active, !self.recovering, self.startGeneration == generation,
                  !self.streamTracker.hadAnyStream else { return }
            Diagnostics.shared.log("voice-no-stream", "backend=\(self.backend.rawValue) mode=\(self.mode.rawValue)")
            self.showToast(
                self.backend == .codex
                    ? model.text("未检测到 Codex 语音流，请查看终端状态", "No Codex audio stream yet — check terminal")
                    : model.text("未检测到 agy 语音流，请查看终端状态", "No agy audio stream yet — check terminal"),
                duration: .seconds(3.5)
            )
        }
    }

    private func finishFromRemote(reason: VoiceRemoteEndReason, model: AppModel) {
        guard active else { return }
        switch reason {
        case .abortedEarly:
            showToast(
                backend == .codex
                    ? model.text("Codex 语音已中断，请查看终端输出", "Codex voice stopped — check terminal")
                    : model.text("agy 语音已中断，请查看终端输出", "agy voice stopped — check terminal"),
                duration: .seconds(3.5)
            )
            stopInternal(sendHangup: false, reason: "remote-aborted")
        case .ended:
            showToast(model.text("通话已结束", "Call ended"))
            stopInternal(sendHangup: false, reason: "remote-ended")
        }
    }

    func startElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.active else { return }
                if self.ghostState != .connecting { self.elapsedSeconds += 1 }
            }
        }
    }

    func sendFunctionKey(_ number: Int, to runtime: SessionRuntime) {
        guard let seq = TerminalKeys.function(number, control: false, shift: false) else { return }
        runtime.terminalView.scrollToLiveOutput()
        runtime.send(seq)
    }

    func showToast(_ message: String, duration: Duration = .seconds(2)) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled else { return }
            self.toastMessage = nil
        }
    }

    #if DEBUG
    func configureFixture(state: String?, mode: VoiceMode = .live, popover: Bool = false, networkUnstable: Bool = false) {
        fixtureMode = true; self.mode = mode; audioRoute = .speaker
        guard let state, !state.isEmpty else { cleanupAfterEnd(reason: "fixture-reset"); return }
        active = true; recovering = state == "reconnecting"; networkPoor = networkUnstable || state == "unstable"
        elapsedSeconds = 24; micPort = VoiceProtocol.defaultPort
        onUdp = true; popoverOpen = popover; startKeySent = state != "connecting"
        switch state {
        case "connecting", "reconnecting": ghostState = .connecting; isMuted = false
        case "speaking": ghostState = .speaking(level: 0.72); isMuted = false
        case "muted": ghostState = .muted; isMuted = true
        default: ghostState = .listening(level: 0.45); isMuted = false
        }
    }

    func startFixtureCall(mode: VoiceMode, route: VoiceAudioRoute, english: Bool) {
        self.mode = mode; self.audioRoute = route; self.active = true; self.recovering = false; self.networkPoor = false
        self.isMuted = false; self.elapsedSeconds = 18; self.popoverOpen = false
        self.micPort = VoiceProtocol.defaultPort; self.onUdp = true; self.startKeySent = true
        self.ghostState = .listening(level: 0.48)
        startElapsedTimer()
        showToast(english ? "Connected — speak naturally" : "已接通，可以直接说话")
    }
    #endif
}
