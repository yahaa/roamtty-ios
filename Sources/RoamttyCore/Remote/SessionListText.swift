// Behavioral port of Roamtty Android's AgentStatus.kt: how the session list names and describes a session and its agent.
import Foundation

/// An agent's `AgentStatus.reply` as the session list shows it: the Markdown it answers in read as plain text (no
/// emphasis, code ticks, heading marks, a leading list mark, links as their text), on one line.
public func replyPreview(_ reply: String) -> String {
    var text = reply.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\*\*|`+"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"(^|\s)#{1,6}\s+"#, with: "$1", options: .regularExpression)
    // The hook joins the lines, so only the first line's list or quote mark is known for one; a dash further on may be text.
    text = text.replacingOccurrences(of: #"^\s*([-*+>]|\d+\.)\s+"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespaces)
}

/// The tools agents run shell commands with.
private let shellTools: Set<String> = ["Bash", "PowerShell", "run_terminal_command", "shell", "exec_command", "local_shell"]

/// What the agent is running, for the session list: a shell command as `Running command`, as Claude Code says it,
/// another tool by its name and what it works on; empty while it runs nothing.
public func agentActivity(_ status: AgentStatus?) -> String {
    guard let status, status.state != .idle else { return "" }
    if status.detail.isEmpty { return status.tool }
    if status.tool.isEmpty { return status.detail }
    if shellTools.contains(status.tool) { return "Running " + status.detail }
    return status.tool + " " + status.detail
}

/// The last component of a session-list path, keeping `~` and `/` whole.
public func sessionListFolder(_ path: String) -> String {
    if path == "~" || path == "/" { return path }
    var trimmed = path; while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
    return trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? trimmed
}

/// A session's name in the session list: the task its agent was given, else the agent's name and the name of the
/// folder it works in ("Claude · roamtty", the home as `~`), else `title` (one saved as "Claude Code · roamtty"
/// shortened to "Claude · roamtty"). Without a known agent the folder stands alone. Empty when there is none of these.
public func sessionListTitle(_ title: String, status: AgentStatus?, agent: CodingAgent?, username: String) -> String {
    if let task = status?.task, !task.trimmingCharacters(in: .whitespaces).isEmpty { return task }
    let path = sessionListPath(status, username: username)
    if !path.isEmpty {
        let folder = sessionListFolder(path)
        return agent.map { $0.shortLabel + " · " + folder } ?? folder
    }
    guard let agent else { return title }
    let prefix = agent.label + " · "
    return title.hasPrefix(prefix) ? agent.shortLabel + " · " + title.dropFirst(prefix.count) : title
}

/// The folder the session's agent works in, the home as `~`; empty when tmux did not say.
public func sessionListPath(_ status: AgentStatus?, username: String) -> String { sessionListPath(status?.directory ?? "", username: username) }

/// `directory` as the session list shows it, the home as `~`; empty for none.
public func sessionListPath(_ directory: String, username: String) -> String {
    guard !directory.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
    let homes = username == "root" ? ["/root"] : ["/home/" + username, "/Users/" + username]
    guard let home = homes.first(where: { directory == $0 || directory.hasPrefix($0 + "/") }) else { return directory }
    return "~" + directory.dropFirst(home.count)
}

/// The session list's groups, in its order: what waits for the user first, sessions without an agent last.
public enum SessionGroup: String, CaseIterable, Sendable { case waiting, working, done, other }

/// The group of a session whose agent reports `status`: by its state while connected, else with the plain terminals.
public func sessionGroup(connected: Bool, status: AgentStatus?) -> SessionGroup {
    guard connected, let status else { return .other }
    switch status.state {
    case .waiting: return .waiting
    case .working: return .working
    case .idle: return .done
    }
}

/// A running state's length, short as Claude Code's own: "12s", "4m20s", "1h05m".
public func shortDuration(_ seconds: Int64) -> String {
    func two(_ value: Int64) -> String { value < 10 ? "0\(value)" : "\(value)" }
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m\(two(seconds % 60))s" }
    return "\(seconds / 3600)h\(two(seconds % 3600 / 60))m"
}

/// How long ago an agent finished, without spaces so it never breaks across lines: "刚刚", "3分钟前".
public func agoText(_ seconds: Int64, english: Bool) -> String {
    if seconds < 60 { return english ? "now" : "刚刚" }
    if seconds < 3600 { return english ? "\(seconds / 60)m ago" : "\(seconds / 60)分钟前" }
    if seconds < 86_400 { return english ? "\(seconds / 3600)h ago" : "\(seconds / 3600)小时前" }
    return english ? "\(seconds / 86_400)d ago" : "\(seconds / 86_400)天前"
}

/// A turn's length in words: "15 秒", "3 分钟", "1 小时 5 分钟".
public func durationText(_ seconds: Int64, english: Bool) -> String {
    if seconds < 60 { return english ? "\(seconds) s" : "\(seconds) 秒" }
    if seconds < 3600 { return english ? "\(seconds / 60) min" : "\(seconds / 60) 分钟" }
    return english ? "\(seconds / 3600) h \(seconds % 3600 / 60) min" : "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分钟"
}

/// The tags a session card shows beside its status, like a host card's: tmux for a resumable session and mosh while
/// mosh carries it. A plain SSH shell has none.
public func sessionTransportTags(mode: SessionMode, mosh: Bool) -> [String] {
    (mode == .tmux ? ["tmux"] : []) + (mosh ? ["mosh"] : [])
}
