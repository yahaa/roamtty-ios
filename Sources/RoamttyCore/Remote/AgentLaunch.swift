// Behavioral port of Roamtty Android's AgentLaunch helpers.
import Foundation

public enum CodingAgent: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude = "CLAUDE", codex = "CODEX", grok = "GROK"
    public var id: String { rawValue }
    public var label: String { self == .claude ? "Claude Code" : shortLabel }
    public var shortLabel: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        }
    }
    public var command: String { rawValue.lowercased() }
    public var readOnlyFlag: String { self == .claude ? "--permission-mode plan" : "--sandbox read-only" }
    public var yoloFlag: String {
        switch self {
        case .claude: return "--dangerously-skip-permissions"
        case .codex: return "--dangerously-bypass-approvals-and-sandbox"
        case .grok: return "--always-approve"
        }
    }
    public static func from(_ value: String?) -> Self { value.flatMap(Self.init(rawValue:)) ?? .codex }
    /// The agent a hook reported itself as (its `command`), or nil for one this app does not know.
    public static func fromCommand(_ value: String?) -> Self? { allCases.first { $0.command == value } }
    /// The agent a session named by `AgentLaunch.title` was started for, or nil for any other title.
    public static func fromTitle(_ title: String) -> Self? { allCases.first { title.hasPrefix($0.shortLabel + " · ") || title.hasPrefix($0.label + " · ") } }
}

public enum AgentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case readOnly = "READ_ONLY", standard = "STANDARD", yolo = "YOLO"
    public var id: String { rawValue }
    public static func from(_ value: String?) -> Self { value.flatMap(Self.init(rawValue:)) ?? .standard }
}

public struct AgentLaunch: Equatable, Sendable {
    public var agent: CodingAgent
    public var directory: String
    public var mode: AgentMode
    public init(agent: CodingAgent, directory: String, mode: AgentMode = .standard) { self.agent = agent; self.directory = directory; self.mode = mode }
    public var agentCommand: String {
        switch mode {
        case .standard: return agent.command
        case .readOnly: return agent.command + " " + agent.readOnlyFlag
        case .yolo: return agent.command + " " + agent.yoloFlag
        }
    }
    /// Agents report their state through hooks on hosts that run POSIX scripts.
    public var reportsStatus: Bool { true }
    /// `agentCommand` as typed: with the hooks `AgentHooks.hostFile` puts on the host, which Claude Code reads from its
    /// settings and the other agents get from their launcher.
    public var typedCommand: String { typedCommand(session: nil) }
    /// As `typedCommand`, in tmux session `session`, which Claude Code's hooks then report to from outside tmux too.
    public func typedCommand(session: String?) -> String {
        if agent == .claude { return agentCommand + " --settings " + AgentHooks.settingsPath(session: session) }
        return AgentHooks.command(agent) + agentCommand.dropFirst(agent.command.count)
    }
    public var commandLine: String { commandLine(session: nil) }
    public func commandLine(session: String?) -> String {
        guard StartDirectory.isSupported(directory) else { return "printf '%s\\n' 'Unsupported directory control characters' >&2; false" }
        let typed = typedCommand(session: session)
        return StartDirectory.command(directory).map { $0 + " && " + typed } ?? typed
    }
    public var title: String {
        var value = directory; while value.hasSuffix("/") { value.removeLast() }
        let name = value.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return agent.shortLabel + " · " + (name.isEmpty ? "/" : name)
    }
}
