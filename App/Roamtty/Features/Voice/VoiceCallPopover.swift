import SwiftUI
import RoamttyCore
import RoamttyDesktopCore

/// Compact call control bubble popping to the left of the phone-holding ghost pet.
/// Tapping outside dismisses the bubble without ending the active call.
struct VoiceCallPopover: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var voice: VoiceController
    let anchor: CGPoint
    let viewport: CGSize
    let safeArea: EdgeInsets
    let onMute: () -> Void
    let onCycleRoute: () -> Void
    let onOpenDock: () -> Void
    let onHangup: () -> Void
    let onDismiss: () -> Void

    private static let hangupTint = Color(red: 1.0, green: 0.48, blue: 0.44)
    private let bubbleWidth: CGFloat = 236

    private var statusColor: Color {
        voice.networkUnstable ? Palette.warning : Palette.success
    }

    private var routeIcon: String {
        switch voice.audioRoute {
        case .speaker: return "speaker.wave.2.fill"
        case .earpiece: return "ear"
        case .bluetooth: return "wave.3.right"
        }
    }

    var body: some View {
        let halfW = bubbleWidth / 2
        let minX = safeArea.leading + halfW + 12
        let maxX = max(minX, viewport.width - safeArea.trailing - halfW - 12)
        let x = max(minX, min(anchor.x - 34 - halfW, maxX))
        let topMin = safeArea.top + 56
        let bottomMax = max(topMin, viewport.height - safeArea.bottom - 56)
        let y = max(topMin, min(anchor.y, bottomMax))
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .accessibilityIdentifier("voice-popover-backdrop")

            VStack(spacing: 10) {
                headerRow
                actionsRow
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 10)
            .frame(width: bubbleWidth)
            .background(Palette.surface.opacity(0.95), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.foreground.opacity(0.09), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            .position(x: x, y: y)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("voice-call-popover")
        }
        .frame(width: viewport.width, height: viewport.height)
    }

    private var headerRow: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(statusColor.opacity(0.28), lineWidth: 3))
                Text(voice.popoverStatusLabel(english: model.english))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.foreground)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(voice.formattedElapsed)
                .font(.system(size: 11.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Palette.secondary)
                .accessibilityIdentifier("voice-pop-timer")
        }
        .padding(.horizontal, 2)
    }

    private var actionsRow: some View {
        HStack(spacing: 6) {
            actionTile(
                icon: voice.isMuted ? "mic.slash.fill" : "mic.fill",
                label: voice.isMuted ? model.text("取消静音", "Unmute") : model.text("静音", "Mute"),
                fg: voice.isMuted ? Palette.warning : Palette.foreground,
                bg: voice.isMuted ? Palette.warning.opacity(0.2) : Palette.raised,
                enabled: voice.canToggleMute,
                id: "voice-pop-mute",
                action: onMute
            )
            actionTile(
                icon: routeIcon,
                label: voice.routeLabel(voice.audioRoute, english: model.english),
                fg: Palette.foreground,
                bg: Palette.raised,
                enabled: true,
                id: "voice-pop-route",
                action: onCycleRoute
            )
            actionTile(
                icon: "ellipsis.rectangle",
                label: model.text("操作栏", "Dock"),
                fg: Palette.foreground,
                bg: Palette.raised,
                enabled: true,
                id: "voice-pop-dock",
                action: onOpenDock
            )
            actionTile(
                icon: "phone.down.fill",
                label: model.text("挂断", "Hang up"),
                fg: Self.hangupTint,
                bg: Self.hangupTint.opacity(0.2),
                enabled: true,
                id: "voice-pop-hangup",
                action: onHangup
            )
        }
    }

    private func actionTile(icon: String, label: String, fg: Color, bg: Color, enabled: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(label).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: 13))
            .opacity(enabled ? 1 : 0.42)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
