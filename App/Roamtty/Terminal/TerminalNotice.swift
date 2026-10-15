import SwiftUI
import RoamttyCore

/// Android `TerminalNoticeOverlay`: one card centred on the upper golden section, clamped to a 16-point margin.
/// It floats over the preserved terminal grid, so a notice never resizes the remote PTY.
struct GoldenSectionLayout: Layout {
    var margin: CGFloat = 16
    var maxWidth: CGFloat = 400
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let margin = min(self.margin, min(bounds.width, bounds.height) / 2)
        let width = min(bounds.width - 2 * margin, maxWidth)
        let size = child.sizeThatFits(ProposedViewSize(width: width, height: bounds.height - 2 * margin))
        let top = min(max(margin, bounds.height * 0.382 - size.height / 2), max(margin, bounds.height - margin - size.height))
        child.place(at: CGPoint(x: bounds.minX + (bounds.width - size.width) / 2, y: bounds.minY + top), proposal: ProposedViewSize(width: width, height: size.height))
    }
}

struct TerminalNoticeCard<Content: View, Actions: View>: View {
    let title: String
    let id: String
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    content
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { Spacer(minLength: 0); actions }.padding(.top, 16)
        }.padding(20).frame(maxWidth: .infinity).foregroundStyle(Palette.foreground)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).stroke(Palette.outline.opacity(0.55), lineWidth: 1) }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .accessibilityElement(children: .contain).accessibilityIdentifier(id)
    }
}

/// Android `TerminalConnectionProgress`: the animated logo, "SSH", the phase and a cancel button.
struct TerminalConnectionProgress: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let phase: ConnectionPhase
    let onCancel: () -> Void
    @State private var lifted = false
    private var label: String {
        switch phase {
        case .verifying: return model.text("等待核对主机指纹", "Waiting for host-key verification")
        case .authenticating: return model.text("正在进行 SSH 认证", "Authenticating")
        default: return model.text("连接中", "Connecting")
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            Image("RoamttyLogo").resizable().scaledToFit().frame(width: 52, height: 52)
                .offset(y: lifted ? -2 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: lifted)
                .onAppear { lifted = true }
                .accessibilityLabel(label).accessibilityIdentifier("terminal-connection-motion")
            VStack(alignment: .leading, spacing: 4) {
                Text("SSH").font(.system(size: 10, design: .monospaced)).tracking(1.5).foregroundStyle(Palette.secondary)
                Text(label).font(.subheadline.weight(.medium)).animation(.easeInOut(duration: 0.18), value: label)
            }.padding(.leading, 14).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCancel) { AppIcon("ic_close", size: 20).foregroundStyle(Palette.secondary).frame(width: 48, height: 48) }
                .accessibilityLabel(model.text("取消连接", "Cancel connection")).accessibilityIdentifier("terminal-connection-cancel")
        }.padding(12).frame(maxWidth: 300).foregroundStyle(Palette.foreground)
            .background(Palette.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).stroke(Palette.outline.opacity(0.55), lineWidth: 1) }
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .accessibilityElement(children: .contain).accessibilityIdentifier("terminal-connection-progress")
    }
}

/// Android `TerminalConnectionNotice`: why the connection stopped and how to resume it.
struct TerminalConnectionNotice: View {
    @EnvironmentObject var model: AppModel
    let phase: ConnectionPhase
    let message: String?
    /// Nil while the terminal reconnects by itself.
    let onReconnect: (() -> Void)?
    let onShell: () -> Void
    let onReverify: () -> Void
    /// iOS has no Back button and the terminal no navigation bar: the notice leads back to where it was opened from.
    var onLeave: (() -> Void)? = nil
    var body: some View {
        TerminalNoticeCard(title: model.phaseText(phase), id: "terminal-connection-notice") {
            if let message, !message.isEmpty {
                Text(message).font(.subheadline).textSelection(.enabled).accessibilityIdentifier("terminal-notice")
            }
        } actions: {
            if let onLeave { Button(model.text("返回", "Back"), action: onLeave).buttonStyle(TextActionStyle()).accessibilityIdentifier("terminal-leave") }
            if phase == .hostKeyChanged {
                Button(model.text("重新核验…", "Verify again…"), action: onReverify).buttonStyle(FilledButtonStyle()).accessibilityIdentifier("terminal-reverify")
            } else {
                if phase == .tmuxMissing { Button(model.text("改用普通 SSH", "Use plain SSH"), action: onShell).buttonStyle(TextActionStyle()).accessibilityIdentifier("terminal-use-shell") }
                if let onReconnect { Button(model.text("重新连接", "Reconnect"), action: onReconnect).buttonStyle(FilledButtonStyle()).accessibilityIdentifier("terminal-reconnect") }
            }
        }
    }
}

struct TerminalInputNotice: View {
    @EnvironmentObject var model: AppModel
    let message: String
    let onDismiss: () -> Void
    var body: some View {
        TerminalNoticeCard(title: model.text("提示", "Notice"), id: "terminal-input-notice") {
            Text(message).font(.subheadline).accessibilityIdentifier("terminal-notice")
        } actions: {
            Button(model.text("知道了", "Got it"), action: onDismiss).buttonStyle(TextActionStyle()).accessibilityIdentifier("terminal-notice-dismiss")
        }
    }
}
