import SwiftUI
import RoamttyCore
import RoamttyDesktopCore

/// Dialogue mode confirmation bottom sheet shown before starting `agy /voice`.
/// Matches `agy-voice-ui-design.md` §2.2 & `agy-voice-ui-design.html`.
struct VoiceConfirmationSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hostName: String
    let desktopPipActive: Bool
    let pluginMissing: Bool
    let micPermission: VoiceMicPermission
    let onCancel: () -> Void
    let onConfirm: (VoiceMode, VoiceAudioRoute) -> Void

    @State private var selectedMode: VoiceMode = .live
    @State private var selectedRoute: VoiceAudioRoute = VoiceAudioEngine.hasBluetoothRoute ? .bluetooth : .speaker

    private static let confirmInk = Color(red: 0x12 / 255, green: 0x2B / 255, blue: 0x1B / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            heroHeader
            modePicker
            if selectedMode == .live { routeRow }
            if let notice = contextualNotice { noticeRow(notice) }
            actionButtons
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.sheet.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-confirm-sheet")
    }

    private var heroHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        RadialGradient(
                            colors: [Palette.success.opacity(0.18), Palette.background.opacity(0.65)],
                            center: .center, startRadius: 4, endRadius: 34
                        )
                    )
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.success.opacity(0.26), lineWidth: 1))
                ToolboxPetArt(animated: !reduceMotion, voiceState: .listening(level: 0.36))
                    .frame(width: 54, height: 54)
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.text("开启语音对话", "Start Voice Session"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
                Text("agy · \(hostName)" + model.text("（通过主机插件低延迟通道）", " (host plugin low-latency)"))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var modePicker: some View {
        VStack(spacing: 8) {
            modeCard(
                mode: .live,
                title: model.text("实时通话", "Live Call"),
                tag: model.text("推荐", "Recommended"),
                shortcut: "F6",
                desc: model.text("双向连续语音对话，AI 语音回复，支持随时开口打断", "Two-way live voice conversation with AI speech & barge-in"),
                id: "voice-mode-live"
            )
            modeCard(
                mode: .dictate,
                title: model.text("语音听写", "Dictation"),
                tag: nil,
                shortcut: "F5",
                desc: model.text("说话转文字输入到终端，不播放语音", "Speech-to-text into the terminal, no voice playback"),
                id: "voice-mode-dictate"
            )
        }
    }

    private func modeCard(mode: VoiceMode, title: String, tag: String?, shortcut: String, desc: String, id: String) -> some View {
        let selected = selectedMode == mode
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { selectedMode = mode }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().stroke(selected ? Palette.success : Palette.secondary.opacity(0.6), lineWidth: 2)
                    if selected { Circle().fill(Palette.success).frame(width: 9, height: 9) }
                }
                .frame(width: 18, height: 18)
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.foreground)
                        if let tag {
                            Text(tag)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Palette.success)
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Palette.success.opacity(0.18), in: Capsule())
                        }
                        Spacer(minLength: 4)
                        Text(shortcut)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Palette.foreground.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                    }
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.success.opacity(0.11) : Palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selected ? Palette.success : Palette.outline, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var routeRow: some View {
        HStack {
            Text(model.text("音频出口", "Audio output"))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.secondary)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                routePill(.speaker, label: model.text("扬声器", "Speaker"), id: "voice-route-speaker")
                routePill(.earpiece, label: model.text("听筒", "Earpiece"), id: "voice-route-earpiece")
                routePill(.bluetooth, label: model.text("蓝牙", "Bluetooth"), id: "voice-route-bluetooth")
            }
        }
        .padding(.vertical, 2)
    }

    private func routePill(_ route: VoiceAudioRoute, label: String, id: String) -> some View {
        let on = selectedRoute == route
        return Button {
            withAnimation(.easeOut(duration: 0.14)) { selectedRoute = route }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Palette.accent : Palette.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(on ? Palette.raised : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(on ? Palette.accent : Palette.outline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var contextualNotice: (icon: String, text: String, tint: Color)? {
        if micPermission == .denied {
            return ("mic.slash.fill", model.text("麦克风权限未开启，请在系统设置中允许访问", "Microphone permission is off — enable it in Settings"), Palette.warning)
        }
        if desktopPipActive {
            return ("speaker.slash.fill", model.text("通话期间将自动静音远程桌面", "Remote desktop audio will be muted during the call"), Palette.accent)
        }
        if micPermission == .undetermined {
            return ("mic.fill", model.text("开始后将请求麦克风权限", "Microphone permission will be requested when starting"), Palette.secondary)
        }
        return nil
    }

    private func noticeRow(_ notice: (icon: String, text: String, tint: Color)) -> some View {
        HStack(spacing: 7) {
            Image(systemName: notice.icon).font(.system(size: 12)).foregroundStyle(notice.tint)
            Text(notice.text).font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceVariant.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("voice-sheet-notice")
    }

    private var confirmTitle: String {
        if pluginMissing {
            return selectedMode == .live
                ? model.text("安装插件并通话", "Install Plugin & Call")
                : model.text("安装插件并听写", "Install Plugin & Dictate")
        }
        return selectedMode == .live
            ? model.text("开始通话", "Start Call")
            : model.text("开始听写", "Start Dictation")
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Text(model.text("取消", "Cancel"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
                    .frame(width: 112, height: 44)
                    .background(Color.clear, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.outline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voice-sheet-cancel")

            Button { onConfirm(selectedMode, selectedRoute) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "phone.fill").font(.system(size: 14, weight: .semibold))
                    Text(confirmTitle).font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(Self.confirmInk)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Palette.success, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("voice-sheet-confirm")
        }
        .padding(.top, 2)
    }
}
