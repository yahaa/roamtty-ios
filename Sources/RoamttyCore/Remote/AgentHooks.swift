import Foundation
import CNative

/// Hooks of the coding agents that report to `AgentStatus` through a script kept on the host. Claude Code reads its
/// hooks from `--settings`; Codex, Grok and Antigravity start through a launcher in the same folder that adds theirs.
public enum AgentHooks {
    /// Where the script and the agents' hook files live on the host; the shell expands the home.
    public static let scriptPath = "~/.roamtty/agent-hook.sh"
    public static let settingsPath = "~/.roamtty/claude-hooks.json"
    public static let scriptName = "agent-hook.sh"

    public static var script: String {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "agent-hook", withExtension: "sh"), let source = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("agent-hook.sh is missing from the app resources")
        }
        return source
    }

    /// The hook file `agent` needs on the host: a name in `~/.roamtty`, its contents and whether it must run.
    /// With `session`, Claude Code's file names the tmux session it reports to.
    public static func hostFile(_ agent: CodingAgent, session: String? = nil) -> (name: String, content: String, executable: Bool) {
        switch agent {
        case .claude:
            if let session = reportingSession(session) { return (settingsPrefix + session + ".json", claudeSettings(session: session), false) }
            return ("claude-hooks.json", claudeSettings, false)
        case .codex: return ("codex", codexLauncher, true)
        case .grok: return ("grok", grokLauncher, true)
        case .agy: return ("agy", agyLauncher, true)
        }
    }

    /// What `agent` is typed as: Claude Code with its settings, the others through their launcher.
    public static func command(_ agent: CodingAgent) -> String { agent == .claude ? agent.command : "~/.roamtty/" + hostFile(agent).name }

    /// Where Claude Code started for tmux session `session` reads its hooks.
    public static func settingsPath(session: String?) -> String {
        reportingSession(session).map { "~/.roamtty/" + settingsPrefix + $0 + ".json" } ?? settingsPath
    }

    private static let settingsPrefix = "claude-hooks-"

    /// `session` when it can go into a hook command and a file name as it is; anything else reports as before.
    private static func reportingSession(_ session: String?) -> String? {
        guard let session, !session.isEmpty, session.count <= 64,
              session.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }) else { return nil }
        return session
    }

    /// Removes the settings of tmux sessions that ended long ago. A file stays while its session lives, and for a month
    /// after: a background job outlives its pane, and restarting one fails without its settings.
    public static let pruneSettings = RemoteCommands.shell(RemoteCommands.pathSetup + "; " +
        "find \"$HOME/.roamtty\" -maxdepth 1 -name '\(settingsPrefix)*.json' -mtime +30 2>/dev/null | while IFS= read -r file; do " +
        "name=${file##*/\(settingsPrefix)}; tmux has-session -t \"=${name%.json}\" 2>/dev/null || rm -f \"$file\"; done; exit 0")

    private static func hookCommand(_ agent: CodingAgent, _ action: String, session: String? = nil) -> String {
        "sh \(scriptPath) \(agent.command) \(action)" + (session.map { " " + $0 } ?? "")
    }

    /// Contents of `settingsPath`, for Claude Code's `--settings`: merged with the user's own settings and hooks.
    public static var claudeSettings: String { claudeSettings(session: nil) }

    /// As `claudeSettings`, for an agent started in tmux session `session`. Background jobs inherit `--settings`, which
    /// is all that tells them the session they belong to: they run outside tmux.
    public static func claudeSettings(session: String?) -> String {
        let events = [("SessionStart", "start"), ("UserPromptSubmit", "prompt"), ("PreToolUse", "tool"), ("PostToolUse", "post"),
                      ("Notification", "notify"), ("Stop", "stop"), ("SessionEnd", "end")]
        let hooks = events.map { event, action in
            "\"\(event)\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\(hookCommand(.claude, action, session: session))\"}]}]"
        }.joined(separator: ",")
        let statusLine = "\"statusLine\":{\"type\":\"command\",\"command\":\"\(hookCommand(.claude, "statusline"))\"}"
        return "{\"hooks\":{\(hooks)},\(statusLine)}"
    }

    /// Codex events, their key in Codex's hook state, and what the script makes of them.
    private static let codexEvents = [
        ("SessionStart", "session_start", "start"), ("UserPromptSubmit", "user_prompt_submit", "prompt"),
        ("PreToolUse", "pre_tool_use", "tool"), ("PermissionRequest", "permission_request", "ask"),
        ("PostToolUse", "post_tool_use", "post"), ("Stop", "stop", "stop"),
        ("Interrupt", "interrupt", "stop"), ("SessionEnd", "session_end", "end")]

    /// Seconds a Codex hook may take; within Codex's limit for SessionEnd and Interrupt hooks, so it hashes as written.
    private static let codexTimeout = 3

    /// The hash Codex trusts a hook by: SHA-256 of its normalized definition as sorted, compact JSON (codex-rs hooks
    /// `hook_hash`). Codex runs a session's hooks only once trusted, a trust it keeps in its config.toml.
    public static func codexHookHash(eventKey: String, command: String) -> String {
        let json = "{\"event_name\":\"\(eventKey)\",\"hooks\":[{\"async\":false,\"command\":\"\(command)\"," +
            "\"timeout\":\(codexTimeout),\"type\":\"command\"}]}"
        let input = Array(json.utf8)
        var digest = [UInt8](repeating: 0, count: 32)
        input.withUnsafeBufferPointer { roam_sha256($0.baseAddress, input.count, &digest) }
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A launcher ends the report however its agent ended, as the agent's own end hook would, and exits as the agent did.
    private static func launcherEnd(_ agent: CodingAgent) -> [String] { ["status=$?", hookCommand(agent, "end") + " </dev/null", "exit $status"] }

    /// `~/.roamtty/codex`: records the trust Codex's own "Trust all" would for the hooks it adds (once; a different
    /// trust already there is left for the user), then runs Codex with them. It stays the pane's program, so restarting
    /// the pane types it again.
    public static var codexLauncher: String {
        let trust = codexEvents.map { _, key, action in "trust \(key) \(codexHookHash(eventKey: key, command: hookCommand(.codex, action)))" }
        let hooks = codexEvents.map { event, _, action in
            "  -c 'hooks.\(event)=[{hooks=[{type=\"command\",command=\"\(hookCommand(.codex, action))\",timeout=\(codexTimeout)}]}]' \\"
        }
        let head = [
            "#!/bin/sh",
            "# Roamtty: starts Codex with hooks that report its state to agent-hook.sh.",
            "config=\"${CODEX_HOME:-$HOME/.codex}/config.toml\"",
            "trust() {",
            "  header=\"[hooks.state.\\\"/<session-flags>/config.toml:$1:0:0\\\"]\"",
            "  grep -qF \"$header\" \"$config\" 2>/dev/null || printf '\\n%s\\ntrusted_hash = \"%s\"\\n' \"$header\" \"$2\" >> \"$config\"",
            "}",
            "mkdir -p \"$(dirname \"$config\")\""
        ]
        return (head + trust + ["codex \\"] + hooks + ["  \"$@\""] + launcherEnd(.codex)).joined(separator: "\n") + "\n"
    }

    /// Grok events and what the script makes of them.
    private static let grokEvents = [("SessionStart", "start"), ("UserPromptSubmit", "prompt"), ("PreToolUse", "tool"),
        ("PostToolUse", "post"), ("PostToolUseFailure", "post"), ("Notification", "notify"), ("Stop", "stop"),
        ("StopFailure", "stop"), ("StopCancelled", "stop"), ("SessionEnd", "end")]

    /// `~/.roamtty/grok`: Grok reads hooks only from its own folders, so this puts them in `~/.grok/hooks`, where they
    /// act only for a Grok started here (the script checks `ROAMTTY_AGENT`), then runs Grok.
    public static var grokLauncher: String {
        let hooks = grokEvents.map { event, action in
            "\"\(event)\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\(hookCommand(.grok, action))\"}]}]"
        }.joined(separator: ",")
        let lines = [
            "#!/bin/sh",
            "# Roamtty: starts Grok with hooks that report its state to agent-hook.sh.",
            "dir=\"${GROK_HOME:-$HOME/.grok}/hooks\"",
            "mkdir -p \"$dir\" && printf '%s\\n' '{\"hooks\":{\(hooks)}}' > \"$dir/roamtty.json\"",
            "export ROAMTTY_AGENT=grok",
            "grok \"$@\""
        ]
        return (lines + launcherEnd(.grok)).joined(separator: "\n") + "\n"
    }

    /// `~/.roamtty/agy`: Antigravity CLI loads global hooks from plugins under `~/.gemini/config/plugins/`, so this
    /// writes a small `roamtty` plugin whose hooks act only for an `agy` started here (`script` checks `ROAMTTY_AGENT`),
    /// reports the initial idle state (Antigravity fires `SessionStart` only on the first prompt), then runs `agy`.
    public static var agyLauncher: String { agyLauncher(micPort: nil) }

    /// `~/.roamtty/agy` with optional `ANTIGRAVITY_MIC=127.0.0.1:<micPort>` injection for `/voice`.
    /// When `micPort` is nil, also honors an existing `ANTIGRAVITY_MIC` or `~/.roamtty/voice-mic` file if present.
    public static func agyLauncher(micPort: Int?) -> String {
        let plugin = "{\"name\":\"roamtty\",\"displayName\":\"Roamtty\",\"version\":\"1.0.0\"," +
            "\"description\":\"Reports Antigravity CLI status to Roamtty.\"}"
        let hooks = "{\"roamtty\":{" +
            "\"PreInvocation\":[{\"type\":\"command\",\"command\":\"\(hookCommand(.agy, "prompt"))\"}]," +
            "\"PreToolUse\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"\(hookCommand(.agy, "tool"))\"}]}]," +
            "\"PostToolUse\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"\(hookCommand(.agy, "post"))\"}]}]," +
            "\"Stop\":[{\"type\":\"command\",\"command\":\"\(hookCommand(.agy, "stop"))\"}]" +
            "}}"
        var lines = [
            "#!/bin/sh",
            "# Roamtty: starts Antigravity CLI with hooks that report its state to agent-hook.sh.",
            "dir=\"$HOME/.gemini/config/plugins/roamtty\"",
            "mkdir -p \"$dir\" && printf '%s\\n' '\(plugin)' > \"$dir/plugin.json\" && printf '%s\\n' '\(hooks)' > \"$dir/hooks.json\""
        ]
        if let addr = voiceMicAddress(port: micPort) {
            lines.append("export ANTIGRAVITY_MIC=\(addr)")
        } else {
            lines.append("[ -n \"${ANTIGRAVITY_MIC:-}\" ] || { [ -s \"$HOME/.roamtty/voice-mic\" ] && export ANTIGRAVITY_MIC=\"$(cat \"$HOME/.roamtty/voice-mic\")\"; }")
        }
        lines.append("export ROAMTTY_AGENT=agy")
        lines.append("\(hookCommand(.agy, "start")) </dev/null")
        lines.append("agy \"$@\"")
        return (lines + launcherEnd(.agy)).joined(separator: "\n") + "\n"
    }

    /// Windows PowerShell launcher (`%USERPROFILE%\.roamtty\agy.ps1`) with optional `ANTIGRAVITY_MIC` injection.
    public static func agyWindowsLauncher(micPort: Int?) -> String {
        var lines = [
            "# Roamtty: starts Antigravity CLI with voice mic forwarding when active.",
            "$env:ROAMTTY_AGENT = 'agy'"
        ]
        if let addr = voiceMicAddress(port: micPort) {
            lines.append("$env:ANTIGRAVITY_MIC = '\(addr)'")
        } else {
            lines.append("if (-not $env:ANTIGRAVITY_MIC -and (Test-Path \"$env:USERPROFILE\\.roamtty\\voice-mic\")) {")
            lines.append("  $env:ANTIGRAVITY_MIC = (Get-Content \"$env:USERPROFILE\\.roamtty\\voice-mic\" -Raw).Trim()")
            lines.append("}")
        }
        lines.append("& agy @args")
        lines.append("exit $LASTEXITCODE")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Loopback `ANTIGRAVITY_MIC` address for a valid port, nil otherwise.
    public static func voiceMicAddress(port: Int?) -> String? {
        guard let port, (1...65535).contains(port) else { return nil }
        return "127.0.0.1:\(port)"
    }
}
