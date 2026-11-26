import Foundation
import Combine
import UIKit
import RoamttyCore
import RoamttyDesktopCore
import RoamttyTransport

/// Coordinates an active `agy /voice` call for one terminal session:
/// owns `VoiceSession` + `VoiceAudioEngine`, sends interactive F5/F6/F7 keys,
/// auto-mutes `DesktopAudioPlayer` to protect VPIO AEC, and drives the Ghost pet & popover UI.
@MainActor final class VoiceController: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var recovering = false
    @Published private(set) var mode: VoiceMode = .live
    @Published private(set) var audioRoute: VoiceAudioRoute = .speaker
    @Published private(set) var ghostState: GhostVoiceState = .idle
    @Published private(set) var isMuted = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var micPort: Int?
    @Published private(set) var onUdp = false
    @Published var popoverOpen = false
    @Published var toastMessage: String?
    @Published var errorMessage: String?

    private var session: VoiceSession?
    private var audioEngine: VoiceAudioEngine?
    private var startTask: Task<Void, Never>?
    private var startGeneration: UInt64 = 0
    private var loginOwner: String?
    private var elapsedTimer: Task<Void, Never>?
    private var speakerQuietTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var startKeySent = false
    private weak var boundRuntime: SessionRuntime?
    private weak var boundModel: AppModel?

    #if DEBUG
    private var fixtureMode = false
    #endif

    var isBusy: Bool { active || startTask != nil }
    var canToggleMute: Bool { active && mode == .live && ghostState != .connecting }
    var formattedElapsed: String { String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60) }

    /// Compact micro-tag below the phone-holding pet when the control popover is closed.
    func petStatusTag(english: Bool) -> String? {
        guard active else { return nil }
        switch ghostState {
        case .idle: return nil
        case .connecting:
            return recovering ? (english ? "Reconnecting…" : "重连中…") : (english ? "Connecting…" : "连接中…")
        case .muted: return english ? "Muted" : "已静音"
        case .speaking: return english ? "Speaking" : "AI 回复中"
        case .listening:
            if mode == .dictate { return (english ? "Dictate " : "听写 ") + formattedElapsed }
            return formattedElapsed
        }
    }

    func popoverStatusLabel(english: Bool) -> String {
        switch ghostState {
        case .idle, .connecting:
            return recovering ? (english ? "Reconnecting…" : "正在重连…") : (english ? "Connecting…" : "正在接通…")
        case .listening:
            return mode == .dictate
                ? (english ? "Dictating" : "正在听写")
                : (english ? "Listening" : "聆听中")
        case .speaking: return english ? "AI speaking" : "AI 语音回复中"
        case .muted: return english ? "Mic muted" : "麦克风已静音"
        }
    }

    func routeLabel(_ route: VoiceAudioRoute, english: Bool) -> String {
        switch route {
        case .speaker: return english ? "Speaker" : "扬声器"
        case .earpiece: return english ? "Earpiece" : "听筒"
        case .bluetooth: return english ? "Bluetooth" : "蓝牙"
        }
    }

    func startCall(mode: VoiceMode, route: VoiceAudioRoute, runtime: SessionRuntime, model: AppModel) {
        model.stopOtherVoiceCalls(except: runtime.record.id)
        #if DEBUG
        if fixtureMode {
            startFixtureCall(mode: mode, route: route, english: model.english)
            return
        }
        #endif
        stopInternal(sendHangup: false)
        let generation = startGeneration
        startTask = Task { @MainActor [weak self, weak runtime, weak model] in
            guard let self, let runtime, let model else { return }
            await self.startCallAsync(generation: generation, mode: mode, route: route, runtime: runtime, model: model)
        }
    }

    private func startCallAsync(generation: UInt64, mode: VoiceMode, route: VoiceAudioRoute, runtime: SessionRuntime, model: AppModel) async {
        defer { if startGeneration == generation { startTask = nil } }
        let granted = await VoiceAudioEngine.requestMicrophonePermission()
        guard !Task.isCancelled, startGeneration == generation else { return }
        guard granted else {
            errorMessage = model.text("未获得麦克风权限，请在系统设置中允许访问。", "Microphone permission was denied. Enable it in Settings.")
            return
        }
        let owner = "voice-\(runtime.record.id)"
        boundRuntime = runtime; boundModel = model; loginOwner = owner
        self.mode = mode; self.audioRoute = route; self.active = true; self.recovering = false
        self.isMuted = false; self.elapsedSeconds = 0; self.popoverOpen = false
        self.errorMessage = nil; self.startKeySent = false; self.ghostState = .connecting
        model.setVoiceCallActive(true)
        showToast(model.text("正在连接 agy 语音通道…", "Connecting agy voice channel…"))

        do {
            let latestHost = model.host(runtime.host.id) ?? runtime.host
            _ = try await model.logins.credentials(for: latestHost, owner: owner)
            guard !Task.isCancelled, startGeneration == generation else {
                if startGeneration == generation { cleanupAfterEnd() }
                return
            }
            let manifest = try model.desktopManifest()
            let voiceSession = buildVoiceSession(runtime: runtime, host: latestHost, model: model, owner: owner, manifest: manifest)
            let engine = makeAudioEngine(route: route)
            engine.prepareSession(route: route)
            voiceSession.audioIO = engine
            self.audioEngine = engine
            self.session = voiceSession
            observe(voiceSession, runtime: runtime, model: model)
            voiceSession.start()
            model.watchDesktopNetwork()
        } catch {
            guard startGeneration == generation else { return }
            stopInternal(sendHangup: false)
            if !(error is CancellationError) && (error as? RoamError) != .cancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func buildVoiceSession(runtime: SessionRuntime, host: Host, model: AppModel, owner: String, manifest: PluginManifest) -> VoiceSession {
        let hostID = host.id
        let tmux = runtime.record.mode == .tmux ? runtime.record.remoteName : nil
        var config = VoiceSession.Config(hostName: host.name, address: host.hostname, tmuxSession: tmux)
        config.english = model.english
        return VoiceSession(
            config: config,
            manifest: manifest,
            login: { [weak model] in
                guard let model else { return .failed(message: nil, connecting: false) }
                return model.syncVoiceLogin(hostID: hostID, owner: owner)
            },
            injectMicPort: { remote, port, windows in
                if windows {
                    if let cmd = WindowsDesktop.writeAgyLauncherCommand(micPort: port) { _ = remote.runCommand(cmd, timeout: 10) { _ in } }
                } else if let script = RemoteCommands.injectAntigravityMicScript(micPort: port, tmuxSession: tmux) {
                    _ = remote.run(script, timeout: 10) { _ in }
                }
            },
            clearMicPort: { remote, windows in
                if windows {
                    _ = remote.runCommand(WindowsDesktop.clearAgyLauncherCommand(), timeout: 5) { _ in }
                } else {
                    _ = remote.run(RemoteCommands.clearAntigravityMicScript(tmuxSession: tmux), timeout: 5) { _ in }
                }
            }
        )
    }

    private func makeAudioEngine(route: VoiceAudioRoute) -> VoiceAudioEngine {
        let engine = VoiceAudioEngine()
        engine.setAudioRoute(route)
        engine.onMicLevel = { [weak self] level in
            Task { @MainActor in
                guard let self, self.active, !self.isMuted else { return }
                if case .listening = self.ghostState { self.ghostState = .listening(level: Double(level)) }
            }
        }
        engine.onSpeakerLevel = { [weak self] level in
            Task { @MainActor in
                guard let self, self.active else { return }
                self.updateSpeakerActivity(level: Double(level))
            }
        }
        engine.onRouteChanged = { [weak self] detected in
            Task { @MainActor in self?.audioRoute = detected }
        }
        return engine
    }

    private func observe(_ voiceSession: VoiceSession, runtime: SessionRuntime, model: AppModel) {
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
        voiceSession.onEnded = { [weak self, weak voiceSession] _ in
            Task { @MainActor in
                guard let self, let voiceSession, self.session === voiceSession else { return }
                if !voiceSession.active { self.cleanupAfterEnd() }
            }
        }
    }

    private func handlePhase(_ phase: VoiceSessionPhase, runtime: SessionRuntime, model: AppModel) {
        switch phase {
        case .idle:
            cleanupAfterEnd()
        case .connecting:
            recovering = false
            if active { ghostState = .connecting }
        case .recovering:
            recovering = true
            if active { ghostState = .connecting }
        case .ready(let port, let udp):
            recovering = false; micPort = port; onUdp = udp
            model.markDesktopPluginInstalled(for: runtime.host.id)
            if !startKeySent {
                startKeySent = true
                sendFunctionKey(mode.startFunctionKey, to: runtime)
                ghostState = isMuted ? .muted : .listening(level: 0)
                startElapsedTimer()
                if port != VoiceProtocol.defaultPort {
                    showToast(model.text(
                        "语音端口 24713 被占用，已改用 \(port)；若当前 agy 无响应请重启会话",
                        "Voice port 24713 is busy; using \(port). Restart agy if voice does not respond"
                    ))
                } else {
                    showToast(mode == .live
                        ? model.text("已接通，可以直接说话", "Connected — speak naturally")
                        : model.text("听写已开始", "Dictation started"))
                }
            } else if ghostState == .connecting {
                ghostState = isMuted ? .muted : .listening(level: 0)
            }
        case .failed(let message):
            errorMessage = message
            cleanupAfterEnd()
        }
    }

    private func handleStreamEvent(_ event: VoiceStreamEvent, model: AppModel) {
        switch event {
        case .micStarted:
            if !isMuted { ghostState = .listening(level: 0.15) }
        case .micStopped:
            // Dictation ends cleanly once agy closes the mic stream, swapping handset back to keyboard.
            if mode == .dictate && active {
                showToast(model.text("听写已结束", "Dictation finished"))
                stopInternal(sendHangup: false)
            }
        case .speakerStarted, .speakerAudio:
            break
        case .speakerCleared, .speakerStopped:
            speakerQuietTask?.cancel()
            if active { ghostState = isMuted ? .muted : .listening(level: 0) }
        }
    }

    private func updateSpeakerActivity(level: Double) {
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

    func toggleMute(runtime: SessionRuntime, english: Bool) {
        guard canToggleMute else { return }
        isMuted.toggle()
        session?.setMuted(isMuted)
        #if DEBUG
        if !fixtureMode { sendFunctionKey(6, to: runtime) }
        #else
        sendFunctionKey(6, to: runtime)
        #endif
        ghostState = isMuted ? .muted : .listening(level: 0.25)
        showToast(isMuted ? (english ? "Muted (F6)" : "已静音（F6）") : (english ? "Microphone resumed" : "已恢复麦克风"))
    }

    func cycleAudioRoute(english: Bool) {
        let routes: [VoiceAudioRoute]
        #if DEBUG
        routes = (fixtureMode || VoiceAudioEngine.hasBluetoothRoute) ? [.speaker, .earpiece, .bluetooth] : [.speaker, .earpiece]
        #else
        routes = VoiceAudioEngine.hasBluetoothRoute ? [.speaker, .earpiece, .bluetooth] : [.speaker, .earpiece]
        #endif
        let idx = routes.firstIndex(of: audioRoute) ?? 0
        audioRoute = routes[(idx + 1) % routes.count]
        audioEngine?.setAudioRoute(audioRoute)
        showToast(english ? "Switched to \(routeLabel(audioRoute, english: true))" : "已切换\(routeLabel(audioRoute, english: false))")
    }

    func hangup(runtime: SessionRuntime, model: AppModel) {
        showToast(model.text("通话已结束", "Call ended"))
        stopInternal(sendHangup: true, runtime: runtime)
    }

    func networkChanged(_ change: NetworkChange) { session?.networkChanged(change) }
    func shutdown() { stopInternal(sendHangup: false) }
}

// MARK: - Internal lifecycle & UI test fixtures
extension VoiceController {
    private func stopInternal(sendHangup: Bool, runtime: SessionRuntime? = nil) {
        startGeneration &+= 1
        startTask?.cancel()
        startTask = nil
        if let owner = loginOwner {
            boundModel?.logins.invalidateOwner(owner)
            boundModel?.logins.dismissPrompts(owner: owner)
            loginOwner = nil
        }
        let shouldSendF7 = sendHangup && startKeySent
        #if DEBUG
        if shouldSendF7, !fixtureMode, let target = runtime ?? boundRuntime { sendFunctionKey(7, to: target) }
        #else
        if shouldSendF7, let target = runtime ?? boundRuntime { sendFunctionKey(7, to: target) }
        #endif
        session?.close()
        cleanupAfterEnd()
    }

    private func cleanupAfterEnd() {
        elapsedTimer?.cancel(); elapsedTimer = nil
        speakerQuietTask?.cancel(); speakerQuietTask = nil
        audioEngine?.stopAll(); audioEngine = nil
        session = nil
        if let owner = loginOwner {
            boundModel?.logins.dismissPrompts(owner: owner)
            loginOwner = nil
        }
        active = false; recovering = false; popoverOpen = false; isMuted = false
        ghostState = .idle; micPort = nil; onUdp = false; startKeySent = false
        boundModel?.setVoiceCallActive(false)
    }

    private func startElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.active else { return }
                if self.ghostState != .connecting { self.elapsedSeconds += 1 }
            }
        }
    }

    private func sendFunctionKey(_ number: Int, to runtime: SessionRuntime) {
        guard let seq = TerminalKeys.function(number, control: false, shift: false) else { return }
        runtime.terminalView.scrollToLiveOutput()
        runtime.send(seq)
    }

    private func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.toastMessage = nil
        }
    }

    #if DEBUG
    func configureFixture(state: String?, mode: VoiceMode = .live, popover: Bool = false) {
        fixtureMode = true; self.mode = mode; audioRoute = .speaker
        guard let state, !state.isEmpty else { cleanupAfterEnd(); return }
        active = true; recovering = false; elapsedSeconds = 24; micPort = VoiceProtocol.defaultPort
        onUdp = true; popoverOpen = popover; startKeySent = state != "connecting"
        switch state {
        case "connecting": ghostState = .connecting; isMuted = false
        case "speaking": ghostState = .speaking(level: 0.72); isMuted = false
        case "muted": ghostState = .muted; isMuted = true
        default: ghostState = .listening(level: 0.45); isMuted = false
        }
    }

    private func startFixtureCall(mode: VoiceMode, route: VoiceAudioRoute, english: Bool) {
        self.mode = mode; self.audioRoute = route; self.active = true; self.recovering = false
        self.isMuted = false; self.elapsedSeconds = 18; self.popoverOpen = false
        self.micPort = VoiceProtocol.defaultPort; self.onUdp = true; self.startKeySent = true
        self.ghostState = .listening(level: 0.48)
        startElapsedTimer()
        showToast(english ? "Connected — speak naturally" : "已接通，可以直接说话")
    }
    #endif
}
