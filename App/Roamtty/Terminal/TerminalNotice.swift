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
    /// The connection dropped and the terminal is about to log in again.
    var reconnecting = false
    let onCancel: () -> Void
    private var label: String {
        if reconnecting { return model.text("连接已断开，正在重新连接", "Connection lost, reconnecting") }
        switch phase {
        case .verifying: return model.text("等待核对主机指纹", "Waiting for host-key verification")
        case .authenticating: return model.text("正在进行 SSH 认证", "Authenticating")
        default: return model.text("连接中", "Connecting")
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            RoamttyLogoArt(animated: !reduceMotion).frame(width: 52, height: 52)
                .accessibilityElement().accessibilityLabel(label).accessibilityIdentifier("terminal-connection-motion")
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
    let onReconnect: () -> Void
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
                Button(model.text("重新连接", "Reconnect"), action: onReconnect).buttonStyle(FilledButtonStyle()).accessibilityIdentifier("terminal-reconnect")
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

/// A pill at the top of the terminal while inserted photos upload. Tapping it opens the transfers page; once every
/// path is in the terminal it says so briefly and goes away. A failure stays until it is dismissed or looked at.
struct ImageUploadStatus: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var transfers: FileTransferModel
    @Binding var jobs: [UUID]
    let onOpen: () -> Void
    @State private var inserted = 0

    private var followed: [TransferJob] { jobs.compactMap { id in transfers.jobs.first { $0.id == id } }.filter { $0.state != .cancelled } }
    private func done(_ job: TransferJob) -> Bool { job.state == .complete && job.pendingInsertion == nil }
    /// Failed uploads, and uploads whose path could not go into the terminal.
    private func stuck(_ job: TransferJob) -> Bool { job.state == .failed || (job.state == .complete && job.pendingInsertion != nil) }

    var body: some View {
        let followed = followed
        Group {
            if followed.contains(where: stuck) {
                pill(model.text("图片上传失败，点按查看", "Photo upload failed. Tap for details"), color: Palette.danger) {
                    Image(systemName: "exclamationmark.circle.fill")
                } trailing: {
                    Button { jobs = [] } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 28, height: 28) }
                        .buttonStyle(.plain).accessibilityLabel(model.text("关闭", "Dismiss")).accessibilityIdentifier("image-upload-dismiss")
                }
            } else if !followed.isEmpty {
                let finished = followed.filter(done).count
                let percent = followed.first { $0.state == .running }?.fraction.map { " · \(Int($0 * 100))%" } ?? ""
                pill(model.text("正在插入图片 \(finished + 1)/\(followed.count)", "Inserting photo \(finished + 1) of \(followed.count)") + percent, color: Palette.foreground) {
                    ProgressView().controlSize(.small)
                } trailing: { EmptyView() }
            } else if inserted > 0 {
                pill(model.text("已插入 \(inserted) 张图片", inserted == 1 ? "Photo inserted" : "\(inserted) photos inserted"), color: Palette.foreground) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                } trailing: { EmptyView() }
                .task { try? await Task.sleep(nanoseconds: 1_500_000_000); withAnimation(.easeOut(duration: 0.3)) { inserted = 0 } }
            }
        }
        .animation(.easeOut(duration: 0.2), value: jobs)
        .onReceive(transfers.$jobs) { _ in
            let followed = self.followed
            // Cancelled jobs simply drop out; the batch is over once every remaining photo is in the terminal.
            if !jobs.isEmpty, followed.allSatisfy(done) { inserted = followed.count; jobs = [] }
        }
    }

    private func pill<Leading: View, Trailing: View>(_ text: String, color: Color, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            leading()
            Text(text).font(.subheadline.weight(.medium)).foregroundStyle(color).lineLimit(1).monospacedDigit()
            trailing()
        }
        .padding(.leading, 14).padding(.trailing, 10).frame(minHeight: 40)
        .background(Palette.surface.opacity(0.97), in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .contentShape(Capsule()).onTapGesture(perform: onOpen)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain).accessibilityIdentifier("image-upload-status")
    }
}
