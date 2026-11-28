// Behavioral port of Roamtty Android's AgentStatus.kt: what a coding agent started with the app's hooks reports
// through its tmux session's options.
import Foundation

/// What an AI agent in a tmux session reports through the hooks `AgentHooks` adds: its state, the tool it is running
/// and the task (the last prompt), and the folder the pane is in. Read with `RemoteCommands.agentStatus`; see `parse`.
public struct AgentStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable { case working, waiting, idle }
    public var state: State
    public var agent: String
    public var tool: String
    public var detail: String
    public var task: String
    /// Elapsed milliseconds the state has lasted, on the host's clock.
    public var elapsedMillis: Int64
    /// The pane's working directory; empty when tmux did not say.
    public var directory: String
    /// Seconds the last turn worked, once it stopped; nil while one runs, or before the first.
    public var workedSeconds: Int64?
    /// The start of the agent's last answer, on one line; empty while a turn runs, or when it gave none.
    public var reply: String

    public init(state: State, agent: String, tool: String = "", detail: String = "", task: String = "", elapsedMillis: Int64 = 0,
                directory: String = "", workedSeconds: Int64? = nil, reply: String = "") {
        self.state = state; self.agent = agent; self.tool = tool; self.detail = detail; self.task = task
        self.elapsedMillis = elapsedMillis; self.directory = directory; self.workedSeconds = workedSeconds; self.reply = reply
    }

    static let shells: Set<String> = ["bash", "zsh", "fish", "dash", "ash", "ksh", "csh", "tcsh", "nu", "pwsh", "login"]

    /// Agents that run under their `/bin/sh` launcher, which ends the report itself: the pane shows the launcher's
    /// shell while they run, "sh" on Linux but "bash" on macOS, whose `/bin/sh` is bash.
    private static let launched: Set<String> = ["codex", "grok", "agy"]

    private static func lines(_ output: String?) -> [String]? {
        output?.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Whether `new` is `old` read again `seconds` later: the same in all but its age, which moved on by about as
    /// much (within `slack` seconds). A state that restarted, such as a new turn, does not count, even when its age
    /// went back by less than the slack: an age only grows while its state lasts.
    public static func sameExceptAge(_ old: AgentStatus?, _ new: AgentStatus?, after seconds: TimeInterval, slack: TimeInterval = 5) -> Bool {
        guard var old, let new else { return old == nil && new == nil }
        guard new.elapsedMillis >= old.elapsedMillis else { return false }
        let expected = Double(old.elapsedMillis) + seconds * 1000
        old.elapsedMillis = new.elapsedMillis
        return old == new && abs(Double(new.elapsedMillis) - expected) <= slack * 1000
    }

    /// Output of the status command: `pane_command|state|since|agent|tool|detail|worked|task|reply` (`worked` and
    /// `reply` missing in older reports), the pane's path, then the host's time. The state counts only while the pane
    /// still runs a program: an agent killed before it could report leaves its last state behind, but the pane is back
    /// at a shell.
    public static func parse(_ output: String?) -> AgentStatus? {
        guard let lines = lines(output), let first = lines.first else { return nil }
        let fields = first.split(separator: "|", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 7 else { return nil }
        let worked = fields.count >= 8 ? Int64(fields[6].trimmingCharacters(in: .whitespaces)) : nil
        let task = fields.count >= 8 ? fields[7] : fields[6]
        let reply = fields.count == 9 ? clean(fields[8]) : ""
        var command = Substring(fields[0]); while command.first == "-" { command.removeFirst() }
        if shells.contains(String(command)) && !launched.contains(fields[3]) { return nil }
        guard let state = State(rawValue: fields[1]) else { return nil }
        let since = Int64(fields[2])
        let now = lines.count > 1 ? Int64(lines[lines.count - 1].trimmingCharacters(in: .whitespaces)) : nil
        let elapsed = since.flatMap { since in now.map { max(0, ($0 - since) * 1000) } } ?? 0
        return AgentStatus(state: state, agent: fields[3], tool: fields[4].trimmingCharacters(in: .whitespaces),
                           detail: fields[5].trimmingCharacters(in: .whitespaces), task: clean(task), elapsedMillis: elapsed,
                           directory: directory(output), workedSeconds: state == .idle ? worked : nil, reply: state == .idle ? reply : "")
    }

    /// The folder the pane is in, from the same poll `parse` reads; known with or without an agent, empty when not.
    public static func directory(_ output: String?) -> String {
        guard let lines = lines(output), lines.count >= 3 else { return "" }
        return lines[1].trimmingCharacters(in: .whitespaces)
    }

    /// A byte-limited hook value may end in half a character.
    private static func clean(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespaces)
        while result.hasSuffix("\u{FFFD}") { result.removeLast() }
        return result
    }
}

public extension CodingAgent {
    init?(screenApp: ScreenApp) {
        switch screenApp {
        case .claude: self = .claude
        case .codex: self = .codex
        case .grok: self = .grok
        case .agy: self = .agy
        case .gemini, .shell: return nil
        }
    }
}

/// Resolves whether a terminal session is currently running an AI agent, and how soon to poll again.
public enum AgentSessionPresence {
    /// How long a freshly launched agent gets to boot and emit its first hook before an empty status poll
    /// is treated as "not running" (covers login shell init, launcher setup, and CLI boot).
    public static let launchGraceSeconds: TimeInterval = 10

    /// Short pause before the first status poll after sending a fresh agent startup command, so the remote
    /// login shell and launcher have a moment to execute before the first round-trip.
    public static let launchInitialPollDelay: TimeInterval = 0.8

    /// Poll interval while waiting for a freshly launched agent's first hook report.
    public static let launchRetryPollInterval: TimeInterval = 1.0

    /// Regular poll interval once an agent is reporting, vs lazy interval for plain shells.
    public static let activePollInterval: TimeInterval = 3.0
    public static let idlePollInterval: TimeInterval = 10.0

    /// Whether a freshly launched agent is still inside its startup grace window (has not reported yet).
    public static func inLaunchGrace(launchDeadline: TimeInterval?, now: TimeInterval) -> Bool {
        guard let launchDeadline else { return false }
        return now < launchDeadline
    }

    /// Delay until the next status poll after receiving `status` at `now`.
    public static func nextPollInterval(status: AgentStatus?, launchDeadline: TimeInterval?, now: TimeInterval) -> TimeInterval {
        if status != nil { return activePollInterval }
        if inLaunchGrace(launchDeadline: launchDeadline, now: now) { return launchRetryPollInterval }
        return idlePollInterval
    }

    /// The coding agent active in a terminal session (for context usage ring, voice, and hiding shell-only controls):
    /// 1. What the agent's hooks currently report (`status`).
    /// 2. `launchedAgent` before the first poll answers OR while a fresh launch is still inside its startup grace window.
    /// 3. What is visibly drawn on the terminal screen (`detectedScreen`), so an agent without hooks (or before its
    ///    first hook fires) is still recognized, while exiting back to a plain shell returns `nil`.
    public static func activeAgent(
        status: AgentStatus?,
        launchedAgent: CodingAgent?,
        agentPolled: Bool,
        launchDeadline: TimeInterval?,
        now: TimeInterval,
        detectedScreen: ScreenApp
    ) -> CodingAgent? {
        if let reported = CodingAgent.fromCommand(status?.agent) { return reported }
        if !agentPolled || inLaunchGrace(launchDeadline: launchDeadline, now: now) {
            if let launchedAgent { return launchedAgent }
        }
        return CodingAgent(screenApp: detectedScreen)
    }

    /// Whether shell-only UI (such as shell history / common commands) should be hidden because an AI agent is active.
    /// Includes Gemini CLI visible on screen in addition to the four `CodingAgent`s.
    public static func isAgentActive(
        status: AgentStatus?,
        launchedAgent: CodingAgent?,
        agentPolled: Bool,
        launchDeadline: TimeInterval?,
        now: TimeInterval,
        detectedScreen: ScreenApp
    ) -> Bool {
        if activeAgent(
            status: status,
            launchedAgent: launchedAgent,
            agentPolled: agentPolled,
            launchDeadline: launchDeadline,
            now: now,
            detectedScreen: detectedScreen
        ) != nil {
            return true
        }
        return detectedScreen != .shell
    }
}
