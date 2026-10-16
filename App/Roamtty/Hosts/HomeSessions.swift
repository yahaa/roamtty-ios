import SwiftUI
import RoamttyCore

/// Android `HomeSessions.kt`: every session the app holds, grouped by what its agent is doing.
struct HomeSessionsTab: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let search: String
    private func searched(_ sessions: [SessionRecord]) -> [SessionRecord] {
        guard !search.isEmpty else { return sessions }
        return sessions.filter { record in
            let host = model.host(record.hostID)
            return "\(model.sessionTitle(record)) \(host?.name ?? "") \(host?.address ?? "") \(host?.username ?? "")".localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        // Sorted and searched once per update; every line below reads these.
        let sessions = model.sessionsByActivity, matching = searched(sessions)
        VStack(spacing: 0) {
            HomeListHeader(label: model.text("会话 · \(sessions.count)", "Sessions · \(sessions.count)"), addLabel: model.text("新建会话", "New session"), id: "add-session") { model.sheet = .newSession }
            if model.hosts.isEmpty && sessions.isEmpty {
                // No host is needed first: the new-session sheet fills one in on the way.
                HomeEmptyState(logo: true, title: model.text("从第一个会话开始", "Start your first session"),
                               message: model.text("填写远端主机，运行 AI 编程工具。\n可直连，也可使用手机已有 VPN。", "Fill in a remote host to run AI coding tools.\nConnect directly or through your phone's VPN.")) {
                    AccentCapsuleButton(title: model.text("新建会话", "New session"), id: "empty-new-session") { model.sheet = .newSession }
                }.accessibilityIdentifier("home-sessions-empty")
            } else if sessions.isEmpty {
                HomeEmptyState(title: model.text("暂无会话", "No sessions"), message: model.text("选择主机，打开终端或 AI Agent。", "Pick a host, then open a terminal or an AI Agent.")) {
                    AccentCapsuleButton(title: model.text("新建会话", "New session"), id: "empty-new-session") { model.sheet = .newSession }
                }.accessibilityIdentifier("home-sessions-empty")
            } else if matching.isEmpty {
                HomeEmptyState(title: model.text("没有匹配的会话", "No matching sessions"), message: model.text("试试其他标题或主机信息", "Try another title or host")) { EmptyView() }
            } else {
                HomeSessionsList(sessions: matching)
            }
        }
        // While the list is on screen, dropped and restored sessions reconnect by themselves.
        .onAppear { model.beginSessionListVisit() }
        .task(id: model.homeTab == .sessions && scenePhase == .active) {
            guard model.homeTab == .sessions, scenePhase == .active else { return }
            model.beginSessionListVisit()
            while !Task.isCancelled {
                if model.path.isEmpty { model.reconnectFromList() }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }
}

struct HomeSessionsList: View {
    @EnvironmentObject var model: AppModel
    let sessions: [SessionRecord]
    @State private var filter: SessionGroup?
    /// A group that holds sessions, in the list's order.
    private struct Members {
        let group: SessionGroup
        let records: [SessionRecord]
        /// The last group is "终端" while it holds plain terminals only.
        let plainOnly: Bool
    }
    /// A session coming back stays in the group its agent was last seen in.
    private func group(_ record: SessionRecord) -> SessionGroup {
        sessionGroup(connected: true, status: model.listedAgentStatus(record).status)
    }
    private func plainOnly(_ members: [SessionRecord]) -> Bool {
        !members.contains { model.listedAgentStatus($0).status != nil || model.sessionAgent($0) != nil }
    }
    var body: some View {
        // Each session is placed once per update, not once per group.
        let placed = Dictionary(grouping: sessions, by: group)
        let groups = SessionGroup.allCases.compactMap { value in placed[value].map { Members(group: value, records: $0, plainOnly: plainOnly($0)) } }
        // A filter whose group has emptied shows everything again.
        let only = groups.first { $0.group == filter }?.group
        GeometryReader { geometry in
            let columns = max(1, Int((geometry.size.width - 32 + 12) / (320 + 12)))
            let joined = columns == 1
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if groups.count > 1 { filters(groups, selected: only) }
                    ForEach(groups.filter { only == nil || $0.group == only }, id: \.group) { members in
                        header(members.group, count: members.records.count, plainOnly: members.plainOnly)
                        if joined {
                            VStack(spacing: 0) {
                                ForEach(Array(members.records.enumerated()), id: \.element.id) { index, record in
                                    SessionRow(record: record, divider: index > 0)
                                }
                            }.background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 18))
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                                ForEach(members.records) { record in SessionRow(record: record).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 18)) }
                            }
                        }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }.accessibilityIdentifier("home-sessions-list")
        }
    }
    /// The chips above the groups: all sessions, then each group with how many it holds.
    private func filters(_ groups: [Members], selected: SessionGroup?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                pill(model.text("全部", "All"), count: sessions.count, dot: nil, selected: selected == nil, id: "home-session-filter-all") { filter = nil }
                ForEach(groups, id: \.group) { members in
                    let value = members.group
                    pill(value.label(model, plainOnly: members.plainOnly), count: members.records.count, dot: value.color, selected: selected == value,
                         id: "home-session-filter-\(value.rawValue)") { filter = selected == value ? nil : value }
                }
            }
        }.padding(.bottom, 2)
    }
    private func pill(_ label: String, count: Int, dot: Color?, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7).padding(.trailing, 6) }
                Text(label).font(.system(size: 14)).foregroundStyle(selected ? Palette.foreground : Palette.secondary)
                Text("\(count)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.foreground).padding(.leading, 5)
            }.lineLimit(1).padding(.horizontal, 12).frame(height: 32)
                .background(Palette.foreground.opacity(selected ? 0.12 : 0.06), in: Capsule())
                .overlay { Capsule().stroke(selected ? Palette.foreground.opacity(0.3) : Color.clear, lineWidth: 1) }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier(id)
    }
    /// A group's line: a ring in its colour (filled for the one waiting on the user), its name and how many it holds.
    private func header(_ value: SessionGroup, count: Int, plainOnly: Bool) -> some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(value.color, lineWidth: 2).background(Circle().fill(value == .waiting ? value.color : Color.clear)).frame(width: 12, height: 12)
            Text(value.label(model, plainOnly: plainOnly)).font(.system(size: 14, weight: .medium)).foregroundStyle(value.color).padding(.leading, 8)
            Text("\(count)").font(.system(size: 14, weight: .medium)).foregroundStyle(value.color.opacity(0.8)).padding(.leading, 6)
        }.padding(.leading, 6).padding(.top, 14).padding(.bottom, 8).accessibilityIdentifier("home-session-group-\(value.rawValue)")
    }
}

/// One session: its tile beside its name and the last prompt ("你: …"), then, across the whole row, what the agent
/// answered or runs and a status line with where it runs and what the agent needs (allow a request, or a follow-up
/// typed right here). A plain terminal has its host and folder beneath its name. Long press for its menu.
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
        let location = orderedUnique([host?.name ?? "", path].filter { !$0.isEmpty && $0 != name }).joined(separator: " · ")
        let prompt = status?.task ?? ""
        let activity = agentActivity(status)
        let reply = replyPreview(status?.reply ?? "")
        let waiting = status?.state == .waiting, idle = status?.state == .idle
        VStack(alignment: .leading, spacing: 0) {
            if divider { Rectangle().fill(Palette.foreground.opacity(0.07)).frame(height: 1).padding(.leading, 14) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    SessionIcon(record: record, size: 40, state: status?.state)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let kind { AgentNameBadge(agent: kind) }
                            MarqueeTitle(text: name).accessibilityIdentifier("home-session-title-\(record.id)")
                            if let status, let runtime, live { elapsed(status, since: runtime.agentStatusAt) }
                        }
                        if !prompt.isEmpty {
                            (Text(model.text("你: ", "You: ")).foregroundColor(Palette.secondary.opacity(0.7)) + Text(prompt))
                                .font(.system(size: 13)).foregroundStyle(Palette.secondary).lineLimit(1).accessibilityIdentifier("home-session-prompt-\(record.id)")
                        } else {
                            Text(location).font(.system(size: 13)).foregroundStyle(Palette.secondary).lineLimit(1).truncationMode(.middle)
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
                    statusView(status: live ? status : nil, phase: phase, kind: kind, activity: activity, waiting: waiting, idle: idle)
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        if !prompt.isEmpty { Text(location).font(.system(size: 12)).foregroundStyle(Palette.secondary.opacity(0.8)).lineLimit(1).truncationMode(.middle) }
                        ForEach(sessionTransportTags(mode: record.mode, mosh: connected && runtime?.transportName == "mosh"), id: \.self) { MetaTag(text: $0) }
                        if waiting && live {
                            RowAction(label: model.text("查看", "View"), plain: true) { model.openSession(record) }.accessibilityIdentifier("home-session-view-\(record.id)")
                            RowAction(label: model.text("允许", "Allow"), fill: Palette.warning) { approve(runtime) }.accessibilityIdentifier("home-session-approve-\(record.id)")
                        } else if idle && live {
                            RowAction(label: model.text("追问", "Reply"), icon: "ic_reply") { replying.toggle(); draftFocused = replying }.accessibilityIdentifier("home-session-follow-up-\(record.id)")
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
            // Close ends everything it runs, without asking.
            Button(role: .destructive) { model.closeSession(record) } label: { Label { Text(model.text("关闭", "Close")) } icon: { Image("ic_delete") } }
                .accessibilityIdentifier("home-session-close-\(record.id)")
            // Closing a disconnected tmux session logs in to end it, which an offline host never allows.
            if record.mode == .tmux && !phase.active {
                Button(role: .destructive) { forceDelete = true } label: { Label { Text(model.text("强制删除", "Force delete")) } icon: { Image("ic_delete") } }
                    .accessibilityIdentifier("home-session-forget-\(record.id)")
            }
        }
        .alert(model.text("强制删除会话？", "Force delete this session?"), isPresented: $forceDelete) {
            Button(model.text("删除", "Delete"), role: .destructive) { model.forceDeleteSession(record) }.accessibilityIdentifier("home-session-forget-confirm-\(record.id)")
            Button(model.text("取消", "Cancel"), role: .cancel) { }
        } message: { Text(model.text("只移除本机的会话卡片，不登录主机；远端 tmux 会话若仍在运行，会继续保留。", "Removes the card from this phone without logging in to the host; the remote tmux session keeps running if it still is.")) }
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
    private func orderedUnique(_ values: [String]) -> [String] { var seen = Set<String>(); return values.filter { seen.insert($0).inserted } }

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
            Text(status.state == .idle ? agoText(seconds, english: model.english) : shortDuration(seconds))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary.opacity(0.8)).lineLimit(1).fixedSize()
        }.accessibilityIdentifier("home-session-time-\(record.id)")
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

/// A new session in two steps: first what runs (an AI agent or a plain terminal), then the host it runs on; the
/// launch sheet that follows picks the folder. Saved hosts are shortcuts; the last row fills in a new host on the spot.
struct NewSessionSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Nil until picked; the terminal is its own choice, so it cannot share nil with "not picked yet".
    @State private var picked: CodingAgent??
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if picked != nil {
                    Button { withAnimation { picked = nil } } label: { AppIcon("ic_chevron_left", size: 22).frame(width: 44, height: 48) }
                        .accessibilityLabel(model.text("返回", "Back")).accessibilityIdentifier("new-session-back")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(picked == nil ? model.text("新建会话", "New session") : model.text("选择主机", "Choose a host")).font(.system(size: 20, weight: .semibold))
                    Text(picked == nil ? model.text("选择要运行的 AI Agent，或打开终端。", "Pick the AI Agent to run, or open a terminal.")
                         : model.text("在哪台主机上运行 \(pickedName)？", "Which host should run \(pickedName)?")).font(.subheadline).foregroundStyle(Palette.secondary)
                }.padding(.leading, picked == nil ? 12 : 0)
                Spacer()
                Button { dismiss() } label: { AppIcon("ic_close").frame(width: 48, height: 48) }.accessibilityLabel(model.text("关闭", "Close")).accessibilityIdentifier("new-session-close")
            }.padding(.leading, 12).padding(.trailing, 12).padding(.top, 16).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 0) {
                    if let picked {
                        ForEach(model.hosts) { host in
                            row(host.name, "\(host.username)@\(host.address):\(host.port)", id: "new-session-host-\(host.id)") { HostSystemMark(system: host.system).frame(width: 40, height: 40) } action: {
                                model.replaceSheet(with: .launch(host, picked != nil, agent: picked, newSession: true))
                            }
                        }
                        row(model.text("新主机", "New host"), model.text("填写地址和登录方式", "Enter its address and sign-in"), id: "new-session-new-host") {
                            AppIcon("ic_add", size: 22).foregroundStyle(Palette.secondary).frame(width: 40, height: 40).background(Palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 11))
                        } action: { model.replaceSheet(with: .newHost(forAgent: picked)) }
                    } else {
                        ForEach(CodingAgent.allCases) { agent in
                            row(agent.shortLabel, agent.command, id: "new-session-pick-\(agent.command)") { AgentIcon(agent: agent, size: 40) } action: { withAnimation { picked = .some(agent) } }
                        }
                        row(model.text("终端", "Terminal"), model.text("登录 shell", "Login shell"), id: "new-session-pick-terminal") { TerminalTile(size: 40) } action: { withAnimation { picked = .some(nil) } }
                    }
                }.padding(.bottom, 16)
            }.accessibilityIdentifier("new-session-sheet")
        }.foregroundStyle(Palette.foreground).background(Palette.sheet.ignoresSafeArea())
            .presentationDetents([.medium, .large])
    }
    private var pickedName: String { picked.flatMap { $0?.shortLabel } ?? model.text("终端", "Terminal") }
    private func row<Leading: View>(_ title: String, _ subtitle: String, id: String, @ViewBuilder leading: () -> Leading, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).lineLimit(1)
                    Text(subtitle).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                AppIcon("ic_chevron_right", size: 18).foregroundStyle(Palette.secondary)
            }.padding(.leading, 24).padding(.trailing, 20).padding(.vertical, 8).frame(minHeight: 64).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
}
