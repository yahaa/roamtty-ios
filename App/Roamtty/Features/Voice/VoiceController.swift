import Foundation
import Combine
import UIKit
import RoamttyCore
import RoamttyDesktopCore
import RoamttyTransport

extension SessionRuntime {
    var voiceBackend: VoiceBackend? {
        switch activeAgentKind ?? CodingAgent(screenApp: detectScreenApp()) {
        case .agy: return .agy
        case .codex: return .codex
        default: return nil
        }
    }
}

/// Coordinates an active `agy /voice` call for one terminal session:
/// owns `VoiceSession` + `VoiceAudioEngine`, sends interactive F5/F6/F7 keys,
/// auto-mutes `DesktopAudioPlayer` to protect VPIO AEC, and drives the Ghost pet & popover UI.
@MainActor final class VoiceController: ObservableObject {
    @Published var active = false
    @Published var recovering = false
    @Published var networkPoor = false
    @Published var mode: VoiceMode = .live
    @Published var backend: VoiceBackend = .agy
    @Published var audioRoute: VoiceAudioRoute = .speaker
    @Published var ghostState: GhostVoiceState = .idle
    @Published var isMuted = false
    @Published var elapsedSeconds = 0
    @Published var micPort: Int?
    @Published var onUdp = false
    @Published var popoverOpen = false
    @Published var toastMessage: String?
    @Published var errorMessage: String?

    var pendingCodexStatus: Data?
    var codexInputRevision: UInt64 = 0
    var awaitingManualStatus = false
    var session: VoiceSession?
    var audioEngine: VoiceAudioEngine?
    var startTask: Task<Void, Never>?
    var startGeneration: UInt64 = 0
    var loginOwner: String?
    var elapsedTimer: Task<Void, Never>?
    var speakerQuietTask: Task<Void, Never>?
    var remoteEndTask: Task<Void, Never>?
    var noStreamHintTask: Task<Void, Never>?
    var toastTask: Task<Void, Never>?
    var bridgeReady = false
    var startKeySent = false
    var streamTracker = VoiceRemoteStreamTracker()
    weak var boundRuntime: SessionRuntime?
    weak var boundModel: AppModel?

    #if DEBUG
    var fixtureMode = false
    #endif

    var isBusy: Bool { active || startTask != nil }
    var networkUnstable: Bool { recovering || networkPoor }
    var canToggleMute: Bool { active && !recovering && ghostState != .connecting }
    var formattedElapsed: String { String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60) }

    /// Compact micro-tag below the phone-holding pet when the control popover is closed.
    func petStatusTag(english: Bool) -> String? {
        guard active else { return nil }
        if recovering { return english ? "Reconnecting…" : "重连中…" }
        if networkPoor { return english ? "Poor network" : "网络不稳定" }
        switch ghostState {
        case .idle: return nil
        case .connecting: return english ? "Connecting…" : "连接中…"
        case .muted: return english ? "Muted" : "已静音"
        case .speaking: return english ? "Speaking" : "AI 回复中"
        case .listening: return formattedElapsed
        }
    }

    func popoverStatusLabel(english: Bool) -> String {
        if recovering { return english ? "Reconnecting…" : "正在重连…" }
        if networkPoor { return english ? "Poor network" : "网络不稳定" }
        switch ghostState {
        case .idle, .connecting: return english ? "Connecting…" : "正在接通…"
        case .listening: return english ? "Listening" : "聆听中"
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

    func startCall(mode: VoiceMode, route: VoiceAudioRoute? = nil, runtime: SessionRuntime, model: AppModel) {
        let hadOtherCall = model.stopOtherVoiceCalls(except: runtime.record.id)
        #if DEBUG
        if fixtureMode {
            startFixtureCall(mode: mode, route: route ?? .speaker, english: model.english)
            return
        }
        #endif
        stopInternal(sendHangup: false, reason: "restart", syncAudioTeardown: true)
        let generation = startGeneration
        startTask = Task { @MainActor [weak self, weak runtime, weak model] in
            guard let self, let runtime, let model else { return }
            await self.startCallAsync(
                generation: generation,
                mode: mode,
                route: route,
                hadHandover: hadOtherCall,
                runtime: runtime,
                model: model
            )
        }
    }

    private func startCallAsync(
        generation: UInt64,
        mode: VoiceMode,
        route: VoiceAudioRoute?,
        hadHandover: Bool,
        runtime: SessionRuntime,
        model: AppModel
    ) async {
        defer { if startGeneration == generation { startTask = nil } }
        let granted = await VoiceAudioEngine.requestMicrophonePermission()
        guard !Task.isCancelled, startGeneration == generation else { return }
        guard granted else {
            errorMessage = model.text("未获得麦克风权限，请在系统设置中允许访问。", "Microphone permission was denied. Enable it in Settings.")
            return
        }
        let owner = "voice-\(runtime.record.id)-\(UUID())"
        let initialRoute = route ?? (VoiceAudioEngine.hasBluetoothRoute ? .bluetooth : .speaker)
        guard let targetBackend = runtime.voiceBackend else { return }
        boundRuntime = runtime; boundModel = model; loginOwner = owner
        self.mode = mode; self.backend = targetBackend; self.audioRoute = initialRoute; self.active = true; self.recovering = false; self.networkPoor = false
        self.isMuted = false; self.elapsedSeconds = 0; self.popoverOpen = false
        self.errorMessage = nil; self.startKeySent = false; self.ghostState = .connecting
        streamTracker.reset(mode: mode)
        cancelStreamTimers()
        model.setVoiceCallActive(true)
        Diagnostics.shared.log("voice-call-start", "backend=\(targetBackend.rawValue) mode=\(mode.rawValue) route=\(route?.rawValue ?? "default") handover=\(hadHandover)")
        showToast(
            targetBackend == .codex
                ? model.text("正在连接 Codex 语音通道…", "Connecting Codex voice channel…")
                : model.text("正在连接 agy 语音通道…", "Connecting agy voice channel…")
        )

        do {
            if hadHandover {
                // Allow CoreAudio / Bluetooth HFP to settle after tearing down the prior session's VPIO engine.
                try await Task.sleep(for: .milliseconds(220))
            }
            let (login, credentials) = try await resolveVoiceLogin(runtime, model: model, owner: owner)
            guard !Task.isCancelled, startGeneration == generation else {
                if startGeneration == generation { cleanupAfterEnd(reason: "cancelled") }
                return
            }
            runtime.loginSnapshot = SessionLoginSnapshot(host: login.host, credentials: credentials)
            let manifest = try model.desktopManifest()
            let voiceSession = buildVoiceSession(runtime: runtime, host: login.host, model: model, owner: owner, manifest: manifest, backend: targetBackend)
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
            stopInternal(sendHangup: false, reason: "start-error")
            if !(error is CancellationError) && (error as? RoamError) != .cancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resolveVoiceLogin(_ runtime: SessionRuntime, model: AppModel, owner: String) async throws -> (SessionReconnectLogin, Credentials) {
        guard let saved = model.host(runtime.host.id) else { throw RoamError.cancelled }
        let login = runtime.loginSnapshot.reconnect(using: saved)
        let credentials = try await model.logins.credentials(for: login.host, owner: owner, retained: login.retainedCredentials,
                                                             useSavedCredentials: login.usesSavedCredentials)
        return (login, credentials)
    }

    private func buildVoiceSession(runtime: SessionRuntime, host: Host, model: AppModel, owner: String, manifest: PluginManifest, backend: VoiceBackend) -> VoiceSession {
        let sessionID = runtime.record.id
        let tmux = runtime.record.mode == .tmux ? runtime.record.remoteName : nil
        var config = VoiceSession.Config(hostName: host.name, address: host.hostname, tmuxSession: tmux, backend: backend)
        config.english = model.english
        return VoiceSession(
            config: config,
            manifest: manifest,
            login: { [weak model] in
                guard let model else { return .failed(message: nil, connecting: false) }
                return model.syncVoiceLogin(sessionID: sessionID, owner: owner)
            },
            prepareCodexBind: Self.prepareCodexBind,
            readCodexStatus: { [weak model] in model?.syncCodexStatus(sessionID: sessionID, owner: owner) },
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

    /// Manual Codex launches can be dialed before the terminal's periodic hook installation has run.
    nonisolated private static func prepareCodexBind(_ host: DesktopHost) -> Bool {
        guard let ssh = (host as? SSHDesktopHost)?.connection else { return false }
        let script = """
        set -e
        dir="$HOME/.roamtty"
        mkdir -p "$dir"
        tmp=$(mktemp "$dir/.voice-hook.XXXXXX")
        trap 'rm -f "$tmp"' EXIT
        cat > "$tmp"
        cmp -s "$tmp" "$dir/agent-hook.sh" || mv -f "$tmp" "$dir/agent-hook.sh"
        """
        return (try? ssh.exec(RemoteCommands.shell(script), input: Data(AgentHooks.script.utf8), timeout: 8).status) == 0
    }

    private func makeAudioEngine(route: VoiceAudioRoute?) -> VoiceAudioEngine {
        let engine = VoiceAudioEngine()
        if let route { engine.setAudioRoute(route) }
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
        engine.onRouteChanged = { [weak self, weak engine] detected in
            Task { @MainActor in
                guard let self, let engine, self.audioEngine === engine else { return }
                self.audioRoute = detected
            }
        }
        return engine
    }

    func toggleMute(runtime: SessionRuntime, english: Bool) {
        guard canToggleMute else { return }
        isMuted.toggle()
        session?.setMuted(isMuted)
        if backend == .agy && startKeySent && session?.agyKeysAllowed == true {
            #if DEBUG
            if !fixtureMode { sendFunctionKey(6, to: runtime) }
            #else
            sendFunctionKey(6, to: runtime)
            #endif
            ghostState = isMuted ? .muted : .listening(level: 0.25)
            showToast(isMuted ? (english ? "Muted (F6)" : "已静音（F6）") : (english ? "Microphone resumed" : "已恢复麦克风"))
        } else {
            ghostState = isMuted ? .muted : .listening(level: 0.25)
            showToast(isMuted ? (english ? "Muted" : "已静音") : (english ? "Microphone resumed" : "已恢复麦克风"))
        }
    }

    func cycleAudioRoute(english: Bool) {
        let routes: [VoiceAudioRoute]
        #if DEBUG
        routes = (fixtureMode || VoiceAudioEngine.hasBluetoothRoute) ? [.speaker, .earpiece, .bluetooth] : [.speaker, .earpiece]
        #else
        routes = VoiceAudioEngine.hasBluetoothRoute ? [.speaker, .earpiece, .bluetooth] : [.speaker, .earpiece]
        #endif
        let idx = routes.firstIndex(of: audioRoute) ?? 0
        let next = routes[(idx + 1) % routes.count]
        #if DEBUG
        if fixtureMode { audioRoute = next; return }
        #endif
        audioEngine?.setAudioRoute(next)
    }

    func hangup(runtime: SessionRuntime, model: AppModel) {
        showToast(model.text("通话已结束", "Call ended"))
        stopInternal(sendHangup: true, runtime: runtime, reason: "hangup")
    }

    func networkChanged(_ change: NetworkChange) { session?.networkChanged(change) }
    func shutdown() { stopInternal(sendHangup: false, reason: "shutdown") }
}
