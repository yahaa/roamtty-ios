import SwiftUI
import RoamttyCore
import RoamttyDesktopCore

/// Terminal voice dock button, confirmation sheet, floating call popover, and toast overlay.
extension TerminalScreen {
    var isAgySession: Bool {
        runtime.activeAgentKind == .agy || runtime.launchedAgent == .agy
    }

    /// Shown in `agy` sessions (or while a voice call is active), right beside the Desktop button.
    var showVoiceDock: Bool { isAgySession || runtime.voice.active }

    var voiceDockButton: some View {
        let inCall = runtime.voice.active
        let muted = runtime.voice.isMuted
        let tint: Color = inCall ? (muted ? Palette.warning : Palette.success) : Palette.foreground
        return Button {
            toolbox.touchDock(at: now)
            runtime.controlArmed = false
            runtime.shiftArmed = false
            if inCall {
                collapseDockSyncingPin()
                withAnimation(.easeOut(duration: 0.18)) { runtime.voice.popoverOpen = true }
            } else {
                _ = runtime.terminalView.resignFirstResponder()
                voiceSheet = true
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if inCall {
                        Circle().fill(tint.opacity(0.16)).frame(width: 34, height: 34)
                    }
                    Image(systemName: inCall ? "phone.fill" : "phone")
                        .font(.system(size: 18, weight: .medium))
                }
                if inCall {
                    VoiceBreathingDot(color: tint)
                        .offset(x: 4, y: -2)
                }
            }
            .foregroundStyle(tint.opacity(connected || inCall ? 1 : 0.38))
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!connected && !inCall)
        .accessibilityLabel(inCall ? model.text("语音通话控制", "Voice call controls") : model.text("语音对话", "Voice chat"))
        .accessibilityValue(inCall ? runtime.voice.popoverStatusLabel(english: model.english) : "")
        .accessibilityIdentifier("terminal-voice")
    }

    @ViewBuilder
    func voiceCallOverlay(in viewport: CGSize, safeArea: EdgeInsets, center: CGPoint) -> some View {
        if runtime.voice.active && runtime.voice.popoverOpen && !toolbox.dockVisible && !toolbox.ringOpen {
            VoiceCallPopover(
                voice: runtime.voice,
                anchor: center,
                viewport: viewport,
                safeArea: safeArea,
                onMute: { runtime.voice.toggleMute(runtime: runtime, english: model.english) },
                onCycleRoute: { runtime.voice.cycleAudioRoute(english: model.english) },
                onOpenDock: {
                    runtime.voice.popoverOpen = false
                    withAnimation(.easeOut(duration: 0.18)) { toolbox.openDock(at: now) }
                },
                onHangup: { runtime.voice.hangup(runtime: runtime, model: model) },
                onDismiss: { withAnimation(.easeOut(duration: 0.16)) { runtime.voice.popoverOpen = false } }
            )
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
        }
    }

    @ViewBuilder
    func voiceToast(topInset: CGFloat) -> some View {
        if let toast = runtime.voice.toastMessage {
            Text(toast)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.inverseForeground)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Palette.inverseSurface.opacity(0.94), in: Capsule())
                .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
                .padding(.top, topInset + 10)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityIdentifier("voice-toast")
        }
    }

    var voiceConfirmationSheetContent: some View {
        let pluginMissing = model.desktopPluginInstalled[runtime.record.hostID] == false
        return VoiceConfirmationSheet(
            hostName: runtime.host.name,
            desktopPipActive: pipDesktop != nil,
            pluginMissing: pluginMissing,
            micPermission: VoiceAudioEngine.microphonePermission,
            onCancel: { voiceSheet = false },
            onConfirm: { mode, route in
                voiceSheet = false
                collapseDockSyncingPin()
                runtime.voice.startCall(mode: mode, route: route, runtime: runtime, model: model)
            }
        )
        .environmentObject(model)
        .onPreferenceChange(VoiceSheetHeightKey.self) { height in
            if height > 0 { voiceSheetHeight = ceil(height) }
        }
        .presentationDetents([.height(max(360, voiceSheetHeight)), .large])
        .presentationDragIndicator(.visible)
    }

    func collapseDockSyncingPin() {
        let wasPinned = toolbox.pinned
        toolbox.collapseDock(at: now)
        if wasPinned || model.settings.toolboxPinned {
            model.settings.toolboxPinned = false
            model.saveSettings()
        }
    }

    func handleGhostTap() {
        if runtime.voice.active {
            withAnimation(.easeOut(duration: 0.18)) { runtime.voice.popoverOpen.toggle() }
        } else {
            withAnimation(.easeOut(duration: 0.18)) { toolbox.openDock(at: now) }
        }
    }
}

/// Subtle breathing status dot on the dock phone button during an active voice call.
private struct VoiceBreathingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .scaleEffect(pulsing && !reduceMotion ? 1.25 : 0.9)
            .opacity(pulsing && !reduceMotion ? 1.0 : 0.72)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}
