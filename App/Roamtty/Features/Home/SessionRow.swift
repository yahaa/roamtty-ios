import SwiftUI
import RoamttyCore
import RoamttyDesktopCore

/// One session: its tile beside its name, the chip of the host it runs on and the last prompt ("你: …", or "等待输入中…"
/// while an idle agent has had none), then, across the whole row, what the agent answered or runs and a status line with
/// how long it has been at it, its folder and what the agent needs (allow a request, or a follow-up typed right here). A
/// plain terminal has its folder beneath its name. Long press for its menu.
struct SessionRow: View {
    @EnvironmentObject var model: AppModel
    let record: SessionRecord
    var divider = false
    @State private var replying = false
    @State private var draft = ""
    @State private var sending = false
    @State private var failure: String?
    @State private var forceDelete = false
    @FocusState private var draftFocused: Bool

    var body: some View {
        let runtime = model.runtimes[record.id]
        let host = model.host(record.hostID)
        let phase = runtime?.phase ?? .disconnected
        let connected = phase == .connected
        // While it reconnects, what the agent reported last; nothing it offers can be done until it answers again.
        let (status, live) = model.listedAgentStatus(record)
        let kind = model.sessionAgent(record)
        let username = host?.username ?? ""
        // The agent's folder while it reports, else the pane's, so a session without hooks or agent says it too.
        let agentPath = sessionListPath(status, username: username)
        let path = agentPath.isEmpty ? sessionListPath(runtime?.paneDirectory ?? "", username: username) : agentPath
        let name = rowName(status: status, path: path, kind: kind)
        // Where it runs: the whole folder (the name holds only its last part); the host has its chip beside the name.
        let location = path == name ? "" : path
        let prompt = status?.task ?? ""
        let activity = agentActivity(status)
        let reply = replyPreview(status?.reply ?? "")
        let waiting = status?.state == .waiting, idle = status?.state == .idle
        // The line under the name holds the prompt, or says an idle agent awaits one, so every agent row reads alike;
        // where it runs then moves to the status line.
        let promptLine = !prompt.isEmpty || idle
        VStack(alignment: .leading, spacing: 0) {
            if divider { Rectangle().fill(Palette.foreground.opacity(0.07)).frame(height: 1).padding(.leading, 14) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    SessionIcon(record: record, size: 40, state: status?.state)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let kind { AgentNameBadge(agent: kind) }
                            MarqueeTitle(text: name).accessibilityIdentifier("home-session-title-\(record.id)")
                            if let host { HostChip(name: host.name, id: host.id, offline: model.hostOffline(record) && !phase.active).padding(.leading, 2)
                                .accessibilityIdentifier("home-session-host-\(record.id)") }
                        }
                        if !prompt.isEmpty {
                            (Text(model.text("你: ", "You: ")).foregroundColor(Palette.secondary.opacity(0.7)) + Text(prompt))
                                .font(.system(size: 13)).foregroundStyle(Palette.secondary).lineLimit(1).accessibilityIdentifier("home-session-prompt-\(record.id)")
                        } else if idle {
                            Text(model.text("等待输入中…", "Awaiting input…")).font(.system(size: 13)).italic().foregroundStyle(Palette.secondary.opacity(0.7)).lineLimit(1)
                                .accessibilityIdentifier("home-session-awaiting-\(record.id)")
                        } else if !location.isEmpty {
                            Text(location).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
                                .accessibilityIdentifier("home-session-location-\(record.id)")
                        }
                    }
                }
                // What the agent runs or asks to run, else what it answered last.
                if !activity.isEmpty {
                    Text(activity).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.secondary.opacity(0.8)).lineLimit(1).padding(.top, 8)
                        .accessibilityIdentifier("home-session-activity-\(record.id)")
                } else if idle && !reply.isEmpty {
                    Text(reply).font(.system(size: 13)).foregroundStyle(Palette.secondary.opacity(0.8)).lineLimit(2).padding(.top, 8)
                        .accessibilityIdentifier("home-session-reply-\(record.id)")
                }
                HStack(spacing: 8) {
                    // A dropped or restored session the list is about to reconnect says so, not "已断开".
                    statusView(status: live ? status : nil, phase: !phase.active && model.sessionComingBack(record) ? .connecting : phase, kind: kind, activity: activity, waiting: waiting, idle: idle)
                    if let status, let runtime, live { elapsed(status, since: runtime.agentStatusAt).padding(.leading, -2) }
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        // Cut from its start, so the folder's own name stays.
                        if promptLine && !location.isEmpty { Text(location).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.secondary.opacity(0.8)).lineLimit(1).truncationMode(.head)
                            .accessibilityIdentifier("home-session-location-\(record.id)") }
                        ForEach(sessionTransportTags(mode: record.mode, mosh: connected && runtime?.transportName == "mosh"), id: \.self) { MetaTag(text: $0) }
                        desktopButton(host: host, connected: connected)
                        if waiting && live {
                            RowAction(label: model.text("查看", "View"), plain: true) { model.openSession(record) }.accessibilityIdentifier("home-session-view-\(record.id)")
                            RowAction(label: model.text("允许", "Allow"), fill: Palette.warning) { approve(runtime) }.accessibilityIdentifier("home-session-approve-\(record.id)")
                        } else if idle && live {
                            RowAction(label: model.text("追问", "Reply"), icon: "ic_reply", iconOnly: true) { replying.toggle(); draftFocused = replying }.accessibilityIdentifier("home-session-follow-up-\(record.id)")
                        }
                    }
                }.frame(minHeight: 28).padding(.top, 8)
                if replying { followUpField(kind: kind, runtime: runtime) }
                if let failure { Text(failure).font(.system(size: 12)).foregroundStyle(Palette.danger).lineLimit(2).padding(.top, 6) }
            }.padding(.horizontal, 14).padding(.vertical, 12)
        }
        .overlay(alignment: .leading) { if waiting { Rectangle().fill(Palette.warning).frame(width: 3) } }
        .foregroundStyle(Palette.foreground)
        .contentShape(Rectangle())
        .onTapGesture { model.openSession(record) }
        .contextMenu {
            // Close ends everything it runs, without asking; a tmux session that was already on the server is only detached.
            Button(role: .destructive) { model.closeSession(record) } label: { Label { Text(record.external ? model.text("断开", "Detach") : model.text("关闭", "Close")) } icon: { Image("ic_delete") } }
                .accessibilityIdentifier("home-session-close-\(record.id)")
            // Closing a tmux session waits for the server to end it, which an offline or unanswering host never allows;
            // force delete removes the card first and ends the session if the host answers.
            if record.mode == .tmux && !record.external {
                Button(role: .destructive) { forceDelete = true } label: { Label { Text(model.text("强制删除", "Force delete")) } icon: { Image("ic_delete") } }
                    .accessibilityIdentifier("home-session-forget-\(record.id)")
            }
        }
        .alert(model.text("强制删除会话？", "Force delete this session?"), isPresented: $forceDelete) {
            Button(model.text("删除", "Delete"), role: .destructive) { model.forceDeleteSession(record) }.accessibilityIdentifier("home-session-forget-confirm-\(record.id)")
            Button(model.text("取消", "Cancel"), role: .cancel) { }
        } message: { Text(model.text("立即移除会话卡片，并用已保存的登录结束远端 tmux 会话；主机无法连接时，远端会话会继续保留。", "Removes the card at once and ends the remote tmux session with the saved login; if the host can't be reached, the remote session keeps running.")) }
        .onChange(of: status?.state) { state in failure = nil; if state != .idle { replying = false } }
        .accessibilityElement(children: .contain).accessibilityIdentifier("home-session-\(record.id)")
    }

    /// An agent's session is named by its folder, the agent's badge before it (the prompt has its own line); others by
    /// `sessionListTitle`.
    private func rowName(status: AgentStatus?, path: String, kind: CodingAgent?) -> String {
        var name: String
        if status != nil { name = path.isEmpty ? (kind?.label ?? "") : sessionListFolder(path) }
        else {
            let shown = sessionListTitle(record.title, status: nil, agent: kind, username: model.host(record.hostID)?.username ?? "")
            name = kind.map { shown.hasPrefix($0.shortLabel + " · ") ? String(shown.dropFirst($0.shortLabel.count + 3)) : shown } ?? shown
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = model.text("会话 \(record.number)", "Session \(record.number)") }
        return name
    }

    @ViewBuilder private func statusView(status: AgentStatus?, phase: ConnectionPhase, kind: CodingAgent?, activity: String, waiting: Bool, idle: Bool) -> some View {
        Group {
            if status == nil { SessionStatusLabel(phase: phase, hostOffline: model.hostOffline(record)) }
            else if waiting { DotLabel(label: model.text("等待确认", "Needs approval"), color: Palette.warning) }
            else if !idle { WorkingSpinner(color: kind?.brand ?? Palette.accent, label: activity.isEmpty ? model.text("思考中…", "Thinking…") : model.text("运行中", "Running")) }
            else if let worked = status?.workedSeconds { TurnDone(seconds: worked) }
            else { DotLabel(label: model.text("空闲", "Idle"), color: Palette.success) }
        }.accessibilityIdentifier("home-session-status-\(record.id)")
    }

    /// Seconds the agent has been in its state, moved on between polls by a clock of its own.
    private func elapsed(_ status: AgentStatus, since: Date) -> some View {
        TimelineView(.periodic(from: since, by: 10)) { context in
            let seconds = status.elapsedMillis / 1000 + Int64(max(0, context.date.timeIntervalSince(since)))
            Text("· " + (status.state == .idle ? agoText(seconds, english: model.english) : shortDuration(seconds)))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary.opacity(0.8)).lineLimit(1).fixedSize()
        }.accessibilityIdentifier("home-session-time-\(record.id)")
    }


    @ViewBuilder private func desktopButton(host: Host?, connected: Bool) -> some View {
        // Experimental flag off (default): render nothing and do not touch PluginManifest / DesktopCore.
        if model.settings.desktopEnabled, let host {
            let button = model.desktopButton(for: host, sessionConnected: connected)
            if case .hidden = button {
                EmptyView()
            } else {
                Button { model.openDesktop(host) } label: {
                    ZStack(alignment: .topTrailing) {
                        AppIcon("ic_desktop", size: 18)
                            .foregroundStyle(desktopTint(button))
                            .frame(width: 34, height: 30)
                            .background(desktopBackground(button), in: RoundedRectangle(cornerRadius: 8))
                        if let dot = desktopDot(button) {
                            Circle().fill(dot).frame(width: 7, height: 7).offset(x: 3, y: -3)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.text("打开桌面", "Open desktop"))
                .accessibilityIdentifier("home-session-desktop-\(record.id)")
            }
        }
    }
    private func desktopTint(_ b: DesktopButton) -> Color {
        switch b {
        case .connected, .poor, .recovering: return .white
        default: return Palette.secondary
        }
    }
    private func desktopBackground(_ b: DesktopButton) -> Color {
        switch b {
        case .connected, .poor, .recovering: return Palette.accent
        case .connecting: return Palette.accent.opacity(0.35)
        default: return Palette.raised
        }
    }
    private func desktopDot(_ b: DesktopButton) -> Color? {
        switch b {
        case .connected: return Palette.success
        case .poor, .needsAction: return Palette.warning
        case .recovering, .connecting: return Palette.accent
        default: return nil
        }
    }

    private func approve(_ runtime: SessionRuntime?) {
        guard let runtime else { return }
        Task { if !(await runtime.approveAgent()) { failure = model.text("未发送：Agent 已不在等待确认", "Not sent: the agent no longer waits for approval") } }
    }

    /// The follow-up typed on the row: a line and a send button; the keyboard's send works too.
    private func followUpField(kind: CodingAgent?, runtime: SessionRuntime?) -> some View {
        HStack(spacing: 8) {
            TextField(model.text("继续问 \(kind?.shortLabel ?? "Agent")…", "Ask \(kind?.shortLabel ?? "Agent")…"), text: $draft)
                .focused($draftFocused).submitLabel(.send).onSubmit { send(runtime) }
                .font(.system(size: 15)).padding(.horizontal, 10).frame(minHeight: 38)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(Palette.foreground.opacity(0.1), lineWidth: 1) }
                .accessibilityIdentifier("home-session-follow-up-input-\(record.id)")
            let blank = draft.trimmingCharacters(in: .whitespaces).isEmpty
            Button { send(runtime) } label: {
                AppIcon("ic_arrow_up", size: 18).foregroundStyle(Palette.surface).frame(width: 38, height: 38)
                    .background(blank || sending ? Palette.foreground.opacity(0.3) : Palette.foreground, in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).disabled(blank || sending).accessibilityLabel(model.text("发送", "Send")).accessibilityIdentifier("home-session-follow-up-send-\(record.id)")
        }.padding(.top, 10)
    }
    private func send(_ runtime: SessionRuntime?) {
        guard let runtime, !sending, !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        sending = true
        Task {
            let sent = await runtime.followUpAgent(draft)
            sending = false
            if sent { draft = ""; replying = false; draftFocused = false }
            else { failure = model.text("未发送：Agent 不在等待输入", "Not sent: the agent is not waiting for input") }
        }
    }
}

/// The host a session runs on: its name on a wash of `Palette.host`, grey around a hollow dot while the host is offline.
private struct HostChip: View {
    let name: String
    let id: String
    let offline: Bool

    var body: some View {
        let tint = offline ? Palette.secondary.opacity(0.7) : Palette.host(id)
        HStack(spacing: 5) {
            Circle().fill(offline ? Color.clear : tint).overlay { if offline { Circle().stroke(tint, lineWidth: 1.5) } }.frame(width: 6, height: 6)
            Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).lineLimit(1).truncationMode(.tail)
        }
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 2)
        .background(offline ? Palette.foreground.opacity(0.06) : tint.opacity(0.14), in: Capsule())
        .frame(maxWidth: 140).fixedSize()
    }
}
