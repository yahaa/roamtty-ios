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

/// Android `ImageInsertDialog`: progress while gallery photos upload into the terminal, then, unless every photo went
/// in, where each one ended up. When every photo is in, only a short notice drops in from the top; a cancel closes quietly.
struct ImageInsertStatus: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var transfers: FileTransferModel
    @Binding var jobs: [UUID]
    let topInset: CGFloat
    /// Paths the terminal refused go into the editor once the batch ends, so no photo is lost.
    let onEditor: (String) -> Void
    @State private var inEditor: Set<UUID> = []
    @State private var notice: String?

    private enum Outcome { case inserted, editor, failed(String?), cancelled }
    private func followed(in all: [TransferJob]) -> [TransferJob] { jobs.compactMap { id in all.first { $0.id == id } } }
    private func outcome(_ job: TransferJob, editor: Set<UUID>) -> Outcome {
        switch job.state {
        case .cancelled: return .cancelled
        case .failed: return .failed(job.message)
        default: return editor.contains(job.id) ? .editor : .inserted
        }
    }

    var body: some View {
        let followed = followed(in: transfers.jobs)
        ZStack(alignment: .top) {
            if !followed.isEmpty {
                // Modal like Android's dialog: the terminal under it takes no touches until it closes.
                Color.black.opacity(0.32).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { }
                card(followed).padding(.horizontal, 28).frame(maxWidth: 440).frame(maxHeight: .infinity)
            }
            if let notice {
                InsertedNotice(message: notice) { self.notice = nil }.padding(.top, topInset + 64)
            }
        }
        .animation(.easeOut(duration: 0.2), value: jobs)
        .animation(.easeOut(duration: 0.25), value: notice)
        .onReceive(transfers.$jobs) { settle($0) }
    }

    /// `$jobs` publishes before the change lands, so the batch is judged on the jobs it hands over.
    private func settle(_ all: [TransferJob]) {
        let followed = followed(in: all)
        guard !followed.isEmpty, !followed.contains(where: { $0.state == .running }) else { return }
        let refused = followed.filter { $0.state == .complete && $0.pendingInsertion != nil && !inEditor.contains($0.id) }
        let editor = inEditor.union(refused.map(\.id))
        if !refused.isEmpty {
            inEditor = editor
            onEditor(refused.compactMap(\.pendingInsertion).joined(separator: " "))
            let ids = refused.map(\.id)
            DispatchQueue.main.async { transfers.discardPendingInsertions(ids) }
        }
        let outcomes = followed.map { outcome($0, editor: editor) }
        if outcomes.contains(where: { if case .cancelled = $0 { return true }; return false }) { close() }
        else if outcomes.allSatisfy({ if case .inserted = $0 { return true }; return false }) {
            notice = model.text("已插入 \(followed.count) 张图片", followed.count == 1 ? "Photo inserted" : "\(followed.count) photos inserted")
            close()
        }
    }
    private func close() { jobs = []; inEditor = [] }

    private func card(_ followed: [TransferJob]) -> some View {
        let total = followed.count
        let current = followed.first { $0.state == .running }
        let done = followed.filter { $0.state != .running }.count
        let outcomes = followed.map { outcome($0, editor: inEditor) }
        let failed = outcomes.filter { if case .failed = $0 { return true }; return false }.count
        let editor = outcomes.filter { if case .editor = $0 { return true }; return false }.count
        let running = current != nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                badge(running ? "ic_image" : failed > 0 ? "ic_alert" : "ic_check",
                      background: running ? Palette.raised : failed > 0 ? Palette.danger.opacity(0.18) : Palette.accentPanel,
                      tint: running ? Palette.foreground : failed > 0 ? Palette.danger : Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(running ? model.text("正在插入图片", "Inserting photos") : failed == total ? model.text("图片插入失败", "Photos not inserted") : model.text("图片插入结果", "Photo results"))
                        .font(.title3.weight(.semibold))
                    let subtitle = running ? (total > 1 ? model.text("第 \(min(done + 1, total)) 张，共 \(total) 张", "Photo \(min(done + 1, total)) of \(total)") : nil)
                        : [total - failed > 0 ? model.text("成功 \(total - failed) 张", "\(total - failed) inserted") : nil,
                           failed > 0 ? model.text("失败 \(failed) 张", "\(failed) failed") : nil].compactMap { $0 }.joined(separator: " · ")
                    if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Palette.secondary).accessibilityIdentifier("image-insert-count") }
                }
            }
            if let current {
                let fraction = current.fraction ?? 0
                ProgressView(value: (Double(done) + fraction) / Double(total)).tint(Palette.accent).padding(.top, 20).accessibilityIdentifier("image-insert-progress")
                HStack {
                    Text(current.total == nil ? model.text("正在处理图片…", "Preparing photo…") : model.text("正在上传…", "Uploading…"))
                    Spacer()
                    if let bytes = current.total { Text("\(formattedBytes(current.bytes)) / \(formattedBytes(bytes))").monospacedDigit() }
                }.font(.subheadline).foregroundStyle(Palette.secondary).padding(.top, 12)
            } else {
                let results = VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(followed.enumerated()), id: \.element.id) { index, job in
                        if index > 0 { Divider().padding(.leading, 32) }
                        row(job, outcomes[index]).accessibilityIdentifier("image-insert-row-\(index)")
                    }
                    if editor > 0 {
                        Text(model.text("终端暂时无法接收粘贴，这些图片路径已放入编辑区，确认后再发送。", "The terminal could not take the paste, so these paths are in the editor. Send them from there."))
                            .font(.footnote).foregroundStyle(Palette.secondary).padding(.top, 8)
                    }
                }.padding(.top, 12)
                // A short list sits in the card as it is; a long one scrolls within about half the screen.
                ViewThatFits(in: .vertical) { results; ScrollView { results } }.frame(maxHeight: UIScreen.main.bounds.height * 0.52)
            }
            HStack {
                Spacer()
                if running {
                    Button(model.text("取消", "Cancel")) { followed.filter { $0.state == .running }.forEach(transfers.cancel) }
                        .buttonStyle(TextActionStyle()).foregroundStyle(Palette.danger).accessibilityIdentifier("image-insert-cancel")
                } else {
                    Button(model.text("完成", "Done")) { close() }.buttonStyle(FilledButtonStyle()).accessibilityIdentifier("image-insert-done")
                }
            }.padding(.top, 20)
        }
        .padding(24).foregroundStyle(Palette.foreground)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .accessibilityElement(children: .contain).accessibilityIdentifier("image-insert-dialog")
    }

    private func badge(_ icon: String, background: Color, tint: Color) -> some View {
        AppIcon(icon).foregroundStyle(tint).frame(width: 40, height: 40).background(background, in: Circle())
    }

    private func row(_ job: TransferJob, _ outcome: Outcome) -> some View {
        let failed: Bool = { if case .failed = outcome { return true }; return false }()
        let (icon, tint, label): (Image, Color, String) = {
            switch outcome {
            case .inserted: return (Image("ic_check"), Palette.accent, model.text("已插入终端", "In the terminal"))
            case .editor: return (Image(systemName: "square.and.pencil"), Palette.secondary, model.text("已放入编辑区", "In the editor"))
            case .failed(let message): return (Image("ic_alert"), Palette.danger, message ?? model.text("上传失败", "Upload failed"))
            case .cancelled: return (Image(systemName: "xmark"), Palette.secondary, model.text("已取消", "Cancelled"))
            }
        }()
        return HStack(spacing: 12) {
            icon.renderingMode(.template).resizable().scaledToFit().frame(width: 20, height: 20).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).lineLimit(1).truncationMode(.middle)
                Text(label).font(.footnote).foregroundStyle(failed ? Palette.danger : Palette.secondary)
            }
        }.padding(.vertical, 10)
    }
}

/// Android `TopNotice`: a toast-like confirmation that drops in under the status bar for two seconds.
private struct InsertedNotice: View {
    let message: String
    let onDismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            AppIcon("ic_check", size: 20).foregroundStyle(Palette.accent)
            Text(message).font(.subheadline)
        }
        .padding(.leading, 12).padding(.trailing, 16).padding(.vertical, 10)
        .foregroundStyle(Palette.foreground)
        .background(Palette.surface, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .transition(.move(edge: .top).combined(with: .opacity))
        .allowsHitTesting(false).accessibilityIdentifier("top-notice")
        .task(id: message) { try? await Task.sleep(nanoseconds: 2_000_000_000); onDismiss() }
    }
}
