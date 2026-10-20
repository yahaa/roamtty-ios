import SwiftUI
import RoamttyCore

/// The tmux sessions on a host's server, one row each with what runs there; tapping one calls `onTap`. `selected`
/// is checked, and a session that already has a card is badged 已打开. `home` shows folders as `~/…`.
struct TmuxSessionList: View {
    @EnvironmentObject var model: AppModel
    let hostID: String
    let sessions: [TmuxSessionInfo]
    var home: String?
    var selected: String?
    /// Prefixes the rows' and the list's accessibility identifiers.
    var idPrefix = "launch"
    let onTap: (TmuxSessionInfo) -> Void
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sessions) { session in
                    let picked = session.name == selected
                    let open = model.records.contains { $0.hostID == hostID && $0.mode == .tmux && $0.remoteName == session.name }
                    let agent = tmuxAgent(session)
                    let headline = tmuxHeadline(session, agent: agent)
                    Button { onTap(session) } label: {
                        HStack(spacing: 12) {
                            if let agent { AgentIcon(agent: agent, size: 32, state: session.agent?.state) } else { TerminalTile(size: 32) }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(headline).font(.body.weight(.medium)).lineLimit(1)
                                    if open { Badge(text: model.text("已打开", "Open")) }
                                }
                                if let doing = tmuxDoing(session) {
                                    Text(doing).font(.caption).foregroundStyle(session.agent?.state.color ?? Palette.secondary).lineLimit(1)
                                }
                                Text(tmuxDetail(session, headline: headline)).font(.caption).foregroundStyle(session.attachable ? Palette.secondary : Palette.danger).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if picked { Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accent) }
                        }.padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 52).contentShape(Rectangle())
                            .background(picked ? Palette.accent.opacity(0.1) : Color.clear)
                    }.buttonStyle(.plain).disabled(!session.attachable).opacity(session.attachable ? 1 : 0.5)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.outline).frame(height: 0.5).padding(.leading, 60) }
                        .accessibilityIdentifier("\(idPrefix)-tmux-\(session.name)")
                }
            }
        }.accessibilityIdentifier("\(idPrefix)-tmux-sessions")
    }
    /// The agent in the session: the one its hooks report, else one running without them, by its program's name.
    private func tmuxAgent(_ session: TmuxSessionInfo) -> CodingAgent? {
        CodingAgent.fromCommand(session.agent?.agent) ?? CodingAgent.fromCommand(session.command)
    }
    /// What the session is for: its agent's task, else the agent or the program it runs and the folder
    /// ("Claude · roamtty", "vim · roamtty"), else the folder of the shell; the session's own name when tmux said none.
    private func tmuxHeadline(_ session: TmuxSessionInfo, agent: CodingAgent?) -> String {
        if let task = session.agent?.task, !task.isEmpty { return task }
        let path = tmuxPath(session.directory)
        let program = agent?.shortLabel ?? (session.idleShell ? nil : session.command)
        if let program { return path.isEmpty ? program : program + " · " + sessionListFolder(path) }
        return path.isEmpty ? session.name : path
    }
    /// The agent's state and what it runs or last answered: "运行中 · Running npm test", "空闲 · 已修复…".
    private func tmuxDoing(_ session: TmuxSessionInfo) -> String? {
        guard let status = session.agent else { return nil }
        let state: String
        switch status.state {
        case .working: state = model.text("运行中", "Running")
        case .waiting: state = model.text("等待确认", "Needs approval")
        case .idle: state = model.text("空闲", "Idle")
        }
        let more = status.state == .idle ? replyPreview(status.reply) : agentActivity(status)
        return more.isEmpty ? state : state + " · " + more
    }
    /// The home as `~`.
    private func tmuxPath(_ directory: String) -> String {
        if let home, home != "/", directory == home || directory.hasPrefix(home + "/") { return "~" + directory.dropFirst(home.count) }
        return directory
    }
    /// "~/work/app · 5分钟前 · 3 个窗口 · 2 个客户端已连接 · roamtty-1a2b": the folder unless the headline is it; a name
    /// the app made up goes last, as it says least, one somebody chose first.
    private func tmuxDetail(_ session: TmuxSessionInfo, headline: String) -> String {
        guard session.attachable else { return model.text("名称含有特殊字符，暂不支持打开", "Its name has special characters, so it can't be opened") }
        var parts: [String] = []
        let path = tmuxPath(session.directory)
        if !path.isEmpty && path != headline { parts.append(path) }
        if let activity = session.activity { parts.append(ago(activity)) }
        if session.windows > 1 { parts.append(model.text("\(session.windows) 个窗口", "\(session.windows) windows")) }
        if session.attached > 0 { parts.append(model.text("\(session.attached) 个客户端已连接", session.attached == 1 ? "1 client attached" : "\(session.attached) clients attached")) }
        if headline != session.name {
            if session.name.hasPrefix("roamtty-") { parts.append(session.name) } else { parts.insert(session.name, at: 0) }
        }
        return parts.joined(separator: " · ")
    }
    /// How long ago, as the session list says it on Android: "刚刚", "3分钟前".
    private func ago(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return model.text("刚刚", "now") }
        if seconds < 3600 { return model.text("\(seconds / 60)分钟前", "\(seconds / 60)m ago") }
        if seconds < 86400 { return model.text("\(seconds / 3600)小时前", "\(seconds / 3600)h ago") }
        return model.text("\(seconds / 86400)天前", "\(seconds / 86400)d ago")
    }
}
