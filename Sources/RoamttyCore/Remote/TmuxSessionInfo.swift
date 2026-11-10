import Foundation

/// A tmux session already on the server, as the new-session sheet lists it to attach.
public struct TmuxSessionInfo: Equatable, Identifiable, Sendable {
    public var name: String
    public var windows: Int
    public var attached: Int
    public var activity: Date?
    /// The folder of its active pane.
    public var directory: String
    /// The program in the foreground of its active pane ("zsh", "vim", "claude"); empty when tmux did not say.
    public var command: String
    /// What an agent the app's hooks watch reports from it; nil without one, or once the pane is back at a shell.
    public var agent: AgentStatus?
    public var id: String { name }
    public init(name: String, windows: Int, attached: Int, activity: Date?, directory: String, command: String = "", agent: AgentStatus? = nil) {
        self.name = name; self.windows = windows; self.attached = attached; self.activity = activity; self.directory = directory
        self.command = command; self.agent = agent
    }
    /// Whether its pane is only at a shell prompt.
    public var idleShell: Bool {
        var program = Substring(command); while program.first == "-" { program.removeFirst() }
        return agent == nil && (program.isEmpty || AgentStatus.shells.contains(String(program)))
    }
    /// The app's tmux commands take only names `RemoteCommands.sanitizeSessionName` keeps as they are.
    public var attachable: Bool { RemoteCommands.sanitizeSessionName(name) == name }
    /// `RemoteCommands.tmuxSessions` output, most recently used first.
    public static func parse(_ output: String) -> [TmuxSessionInfo] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> TmuxSessionInfo? in
            let fields = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, !fields[5].isEmpty, let windows = Int(fields[0]), let attached = Int(fields[1]) else { return nil }
            let directory = fields.count > 6 ? fields[6] : ""
            // As `RemoteCommands.agentStatus` prints it; the clock is left out, as the list shows no elapsed time.
            let agent = AgentStatus.parse(fields[3] + "|" + fields[4] + (directory.isEmpty ? "" : "\n" + directory) + "\n0")
            return TmuxSessionInfo(name: fields[5], windows: windows, attached: attached,
                                   activity: TimeInterval(fields[2]).map(Date.init(timeIntervalSince1970:)), directory: directory,
                                   command: fields[3], agent: agent)
        }.sorted { ($0.activity ?? .distantPast) > ($1.activity ?? .distantPast) }
    }
}
