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
    private var elapsedTimer: Task<Void, Never>?
    private var speakerQuietTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var startKeySent = false
    private weak var boundRuntime: SessionRuntime?
    private weak var boundModel: AppModel?

    #if DEBUG
    private var fixtureMode = false
    #endif

    var formattedElapsed: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    /// Compact micro-tag below the phone-holding pet when the control popover is closed.
    func petStatusTag(english: Bool) -> String? {
        guard active else { return nil }
        switch ghostState {
        case .idle: return nil
        case .connecting: return english ? "Connecting…" : "连接中…"
        case .muted: return english ? "Muted" : "已静音"
        case .speaking: return english ? "Speaking" : "AI 回复中"
        case .listening:
            if mode == .dictate { return (english ? "Dictate " : "听写 ") + formattedElapsed }
            return formattedElapsed
        }
    }

    func popoverStatusLabel(english: Bool) -> String {
        switch ghostState {
        case .idle, .connecting: return english ? "Connecting…" : "正在接通…"
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
        #if DEBUG
        if fixtureMode {
            startFixtureCall(mode: mode, route: route, english: model.english)
            return
        }
        #endif
        Task { await startCallAsync(mode: mode, route: route, runtime: runtime, model: model) }
    }

    private func startCallAsync(mode: VoiceMode, route: VoiceAudioRoute, runtime: SessionRuntime, model: AppModel) async {
        let granted = await VoiceAudioEngine.requestMicrophonePermission()
        guard granted else {
            errorMessage = model.text("未获得麦克风权限，请在系统设置中允许访问。", "Microphone permission was denied. Enable it in Settings.")
            return
        }
        stopInternal(sendHangup: false)
        boundRuntime = runtime
        boundModel = model
        self.mode = mode
        self.audioRoute = route
        self.active = true
        self.isMuted = false
        self.elapsedSeconds = 0
        self.popoverOpen = false
        self.errorMessage = nil
        self.startKeySent = false
        self.ghostState = .connecting
        model.setVoiceCallActive(true)
        showToast(model.text("正在连接 agy 语音通道…", "Connecting agy voice channel…"))

        do {
            let credentials = try await model.logins.credentials(for: runtime.host)
            let manifest = try model.desktopManifest()
            let voiceSession = buildVoiceSession(runtime: runtime, model: model, credentials: credentials, manifest: manifest)
            let engine = makeAudioEngine(route: route)
            voiceSession.audioIO = engine
            self.audioEngine = engine
            self.session = voiceSession
            observe(voiceSession, runtime: runtime, model: model)
            voiceSession.start()
            model.watchDesktopNetwork()
        } catch {
            stopInternal(sendHangup: false)
            errorMessage = error.localizedDescription
        }
    }

    private func buildVoiceSession(runtime: SessionRuntime, model: AppModel, credentials: Credentials, manifest: PluginManifest) -> VoiceSession {
        let host = runtime.host
        let tmux = runtime.record.mode == .tmux ? runtime.record.remoteName : nil
        var config = VoiceSession.Config(hostName: host.name, address: host.hostname, tmuxSession: tmux)
        config.english = model.english
        return VoiceSession(
            config: config,
            manifest: manifest,
            login: { [weak model] in
                guard let model else { return .failed(message: nil, connecting: false) }
                return model.syncVoiceLogin(host: host, credentials: credentials)
            },
            injectMicPort: { remote, port, windows in
                if windows {
                    if let cmd = WindowsDesktop.writeAgyLauncherCommand(micPort: port) {
                        _ = remote.runCommand(cmd, timeout: 10) { _ in }
                    }
                } else if let script = RemoteCommands.injectAntigravityMicScript(micPort: port, tmuxSession: tmux) {
                    _ = remote.run(script, timeout: 10) { _ in }
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
                if case .listening = self.ghostState {
                    self.ghostState = .listening(level: Double(level))
                }
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
        voiceSession.onPhase = { [weak self, weak voiceSession] phase in
            Task { @MainActor in
                guard let self, self.session === voiceSession else { return }
                self.handlePhase(phase, runtime: runtime, model: model)
            }
        }
        voiceSession.onEvent = { [weak self, weak voiceSession] event in
            Task { @MainActor in
                guard let self, self.session === voiceSession else { return }
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
        case .connecting, .recovering:
            if active { ghostState = .connecting }
        case .ready(let port, let udp):
            micPort = port
            onUdp = udp
            model.markDesktopPluginInstalled(for: runtime.host.id)
            if !startKeySent {
                startKeySent = true
                sendFunctionKey(mode.startFunctionKey, to: runtime)
                ghostState = isMuted ? .muted : .listening(level: 0)
                startElapsedTimer()
                showToast(mode == .live
                    ? model.text("已接通，可以直接说话", "Connected — speak naturally")
                    : model.text("听写已开始", "Dictation started"))
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
        case .speakerStarted:
            break
        case .speakerAudio:
            updateSpeakerActivity(level: max(ghostState.audioLevel, 0.35))
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
            if !self.isMuted, case .speaking = self.ghostState {
                self.ghostState = .listening(level: 0)
            }
        }
    }

    func toggleMute(runtime: SessionRuntime, english: Bool) {
        guard active else { return }
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

    func networkChanged(_ change: NetworkChange) {
        session?.networkChanged(change)
    }

    func shutdown() {
        stopInternal(sendHangup: false)
    }
}

// MARK: - Internal lifecycle & UI test fixtures
extension VoiceController {
    private func stopInternal(sendHangup: Bool, runtime: SessionRuntime? = nil) {
        #if DEBUG
        if sendHangup, !fixtureMode, let target = runtime ?? boundRuntime {
            sendFunctionKey(7, to: target)
        }
        #else
        if sendHangup, let target = runtime ?? boundRuntime {
            sendFunctionKey(7, to: target)
        }
        #endif
        session?.close()
        session = nil
        audioEngine?.stopAll()
        audioEngine = nil
        cleanupAfterEnd()
    }

    private func cleanupAfterEnd() {
        elapsedTimer?.cancel(); elapsedTimer = nil
        speakerQuietTask?.cancel(); speakerQuietTask = nil
        active = false
        popoverOpen = false
        isMuted = false
        ghostState = .idle
        micPort = nil
        onUdp = false
        startKeySent = false
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
        fixtureMode = true
        self.mode = mode
        audioRoute = .speaker
        guard let state, !state.isEmpty else {
            cleanupAfterEnd()
            return
        }
        active = true
        elapsedSeconds = 24
        micPort = VoiceProtocol.defaultPort
        onUdp = true
        popoverOpen = popover
        switch state {
        case "connecting": ghostState = .connecting; isMuted = false
        case "speaking": ghostState = .speaking(level: 0.72); isMuted = false
        case "muted": ghostState = .muted; isMuted = true
        default: ghostState = .listening(level: 0.45); isMuted = false
        }
    }

    private func startFixtureCall(mode: VoiceMode, route: VoiceAudioRoute, english: Bool) {
        self.mode = mode
        self.audioRoute = route
        self.active = true
        self.isMuted = false
        self.elapsedSeconds = 18
        self.popoverOpen = false
        self.micPort = VoiceProtocol.defaultPort
        self.onUdp = true
        self.ghostState = .listening(level: 0.48)
        startElapsedTimer()
        showToast(english ? "Connected — speak naturally" : "已接通，可以直接说话")
    }
    #endif
}
