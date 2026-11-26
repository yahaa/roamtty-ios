// Behavioral port of Roamtty Android's Tmux helpers: the shell commands the app runs on a host.
import Foundation

public enum RemoteCommands {
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// `script` as one command line for `/bin/sh`, whatever the login shell is.
    public static func shell(_ script: String) -> String { "/bin/sh -c " + shellQuote(script) }
    /// Runs the script sent on standard input, which keeps it out of the command line and the process list.
    public static let stdinShell = "/bin/sh -s"
    public static let extraPath = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/home/linuxbrew/.linuxbrew/bin:/snap/bin"
    public static let pathSetup = "PATH=\"$PATH:\(extraPath)\"; export PATH"
    public static let tmuxProbe = shell(pathSetup + "; command -v tmux >/dev/null 2>&1")
    public static func sanitizeSessionName(_ name: String) -> String {
        let safe = String(name.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "-" || $0 == "_" }.prefix(64))
        return safe.isEmpty ? "roamtty" : safe
    }
    // swiftlint:disable:next line_length - one shell script line
    private static let bottomPromptPane = ##"n=$(tmux display-message -p "#{pane_height}" 2>/dev/null); [ -n "$n" ] || { set -- $(stty size 2>/dev/null); n=${1:-0}; }; while [ "$n" -gt 1 ]; do echo; n=$((n - 1)); done; s=${SHELL:-/bin/sh}; c=$(tmux show-options -gv default-command 2>/dev/null); [ -n "$c" ] && exec "$s" -c "$c"; exec "$s" -l"##

    /// `existing`: a session that was already on the server, attached as it is: never created, its other clients stay
    /// attached and its status line stays; only mouse mode goes on, so swipes scroll its history. The client runs with
    /// `-u` because sshd may start the command without a UTF-8 locale (macOS does), and tmux then draws every
    /// non-ASCII character as "_".
    public static func tmuxAttach(_ name: String, existing: Bool = false) -> String {
        let name = sanitizeSessionName(name)
        if existing { return "exec " + shell(pathSetup + "; exec tmux -u attach-session -t =\(name) \\; set-option -t \(name) mouse on") }
        let pane = bottomPromptPane.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "$", with: "\\$")
        let options = "\\; set-option -t \(name) mouse on \\; set-option -t \(name) status off"
        let script = pathSetup + "; " +
            "if [ \"$(tmux display-message -p -t \(name) \"#{pane_mode}\" 2>/dev/null)\" = copy-mode ]; then " +
            "tmux send-keys -t \(name) -X cancel || true; fi; " +
            "case \"$(tmux -V 2>/dev/null)\" in \"tmux \"[0-2].*) exec tmux -u new-session -A -D -s \(name) \(options);; esac; " +
            "exec tmux -u new-session -A -D -s \(name) /bin/sh -c \"\(pane)\" \(options)"
        return "exec " + shell(script)
    }
    /// One line per tmux session on the server, `windows<TAB>attached clients<TAB>last activity<TAB>pane command<TAB>
    /// agent report<TAB>name<TAB>folder`, the report as `agentStatus` reads it (see `TmuxSessionInfo.parse`); nothing
    /// when no tmux server runs, and exit status 127 without tmux. The hook strips tabs from what it records.
    public static let tmuxSessions = shell(pathSetup + "; command -v tmux >/dev/null 2>&1 || exit 127; " +
        // swiftlint:disable:next line_length - the tmux format string is one argument
        "tmux -u list-sessions -F '#{session_windows}\t#{session_attached}\t#{session_activity}\t#{pane_current_command}\t#{@roamtty_agent}|#{@roamtty_worked}|#{@roamtty_task}|#{@roamtty_reply}\t#{session_name}\t#{pane_current_path}' 2>/dev/null; exit 0")
    public static func killTmux(_ name: String) -> String {
        let name = sanitizeSessionName(name)
        return pathSetup + "\ntmux has-session -t =\(name) 2>/dev/null || exit 0\nexec tmux kill-session -t =\(name)\n"
    }
    /// One line `pane_command|state|since|agent|tool|detail|worked|task|reply` of what an agent reports through the
    /// session options `@roamtty_agent`, `@roamtty_worked`, `@roamtty_task` and `@roamtty_reply` (empty when it
    /// reports nothing), the pane's folder, then the host's clock for the elapsed time. `-u`: sshd on macOS runs
    /// commands without a UTF-8 locale, and tmux then prints each non-ASCII character of a prompt or a folder as "_".
    public static func agentStatus(_ name: String) -> String {
        let name = sanitizeSessionName(name)
        return shell(pathSetup + "; tmux -u display-message -p -t \(name) " +
            "\"#{pane_current_command}|#{@roamtty_agent}|#{@roamtty_worked}|#{@roamtty_task}|#{@roamtty_reply}\" 2>/dev/null && " +
            "tmux -u display-message -p -t \(name) \"#{pane_current_path}\" 2>/dev/null; date +%s")
    }
    /// Restarts `name`'s pane in the folder it is in, ending whatever runs there. Prints the command line of the pane's
    /// foreground program (nothing when only the shell ran) so it can be typed into the fresh shell. tmux before 2.6
    /// has no `respawn-pane -c`, so it falls back to a plain respawn.
    public static func restartPane(_ name: String) -> String {
        let name = sanitizeSessionName(name)
        return shell(pathSetup + "; " +
            "p=$(tmux display-message -p -t \(name) \"#{pane_pid}\") && [ -n \"$p\" ] || exit 1; " +
            "d=$(tmux display-message -p -t \(name) \"#{pane_current_path}\"); " +
            "ps -A -ww -o ppid= -o stat= -o args= | while read q s a; do [ \"$q\" = \"$p\" ] || continue; " +
            "case \"$s\" in *+*) printf \"%s\\n\" \"$a\"; break;; esac; done; " +
            "tmux respawn-pane -k ${d:+-c \"$d\"} -t \(name) 2>/dev/null || exec tmux respawn-pane -k -t \(name)")
    }
    /// Writes its standard input to `~/.roamtty/<name>`, replacing it; `name` is a plain file name.
    public static func writeHostFile(_ name: String, executable: Bool = false) -> String? {
        guard !name.isEmpty, !name.hasPrefix("."), name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }) else { return nil }
        let chmod = executable ? " && chmod +x \"$HOME/.roamtty/\(name)\"" : ""
        return shell("mkdir -p \"$HOME/.roamtty\" && cat > \"$HOME/.roamtty/\(name)\"" + chmod)
    }
    /// Prints the folder the terminal is in: the tmux pane's, or for a plain shell the login shell of this same SSH
    /// connection (found by its `SSH_CONNECTION` and `SSH_TTY`), without typing anything into its terminal.
    public static func workingDirectory(tmux name: String?) -> String {
        if let name {
            return shell(pathSetup + "; tmux -u display-message -p -t " + shellQuote("=" + sanitizeSessionName(name) + ":") + " '#{pane_current_path}'")
        }
        return shell(#"""
            test -n "$SSH_CONNECTION" || exit 1
            for pid in $(ps -u "$(id -u)" -o pid=,sid= | awk '$1 == $2 { print $1 }'); do
                p=/proc/$pid
                test -r "$p/environ" || continue
                env_lines=$(tr '\000' '\n' < "$p/environ" 2>/dev/null) || continue
                printf '%s\n' "$env_lines" | grep -Fxq "SSH_CONNECTION=$SSH_CONNECTION" || continue
                printf '%s\n' "$env_lines" | grep -q '^SSH_TTY=/dev/' || continue
                readlink "$p/cwd" && exit 0
            done
            exit 1
            """#)
    }
    public static func tmuxAlternateScreen(_ name: String) -> String {
        // The colon selects the active pane. A session-only target produces an empty format value.
        let target = "=" + sanitizeSessionName(name) + ":"
        return shell(pathSetup + "; tmux display-message -p -t " + shellQuote(target) + " '#{alternate_on}'")
    }
    /// Sets a tmux session environment variable (e.g. `ANTIGRAVITY_MIC` for `agy /voice`).
    public static func tmuxSetEnvironment(session: String, name: String, value: String) -> String? {
        guard isValidEnvName(name) else { return nil }
        let safe = sanitizeSessionName(session)
        return shell(pathSetup + "; tmux set-environment -t \(safe) \(name) " + shellQuote(value))
    }
    /// Unsets a tmux session environment variable.
    public static func tmuxUnsetEnvironment(session: String, name: String) -> String? {
        guard isValidEnvName(name) else { return nil }
        let safe = sanitizeSessionName(session)
        return shell(pathSetup + "; tmux set-environment -u -t \(safe) \(name) 2>/dev/null || true")
    }
    /// Injects `ANTIGRAVITY_MIC=127.0.0.1:<micPort>` into `~/.roamtty/voice-mic`, keeps `~/.roamtty/agy` on the
    /// dynamic default template, and (when attached to tmux) sets `ANTIGRAVITY_MIC` in the tmux session environment.
    public static func injectAntigravityMicScript(micPort: Int, tmuxSession: String? = nil) -> String? {
        guard let addr = AgentHooks.voiceMicAddress(port: micPort) else { return nil }
        let launcher = AgentHooks.agyLauncher(micPort: nil)
        var parts = [
            pathSetup,
            "mkdir -p \"$HOME/.roamtty\"",
            "printf '%s\\n' \(shellQuote(addr)) > \"$HOME/.roamtty/voice-mic\"",
            "printf '%s' \(shellQuote(launcher)) > \"$HOME/.roamtty/agy\" && chmod +x \"$HOME/.roamtty/agy\""
        ]
        if let session = tmuxSession, !session.isEmpty {
            let safe = sanitizeSessionName(session)
            parts.append("tmux set-environment -t \(safe) ANTIGRAVITY_MIC \(shellQuote(addr)) 2>/dev/null || true")
        }
        return parts.joined(separator: "\n") + "\n"
    }
    /// Clears transient `~/.roamtty/voice-mic` and tmux override on clean hangup while keeping the default `24713` launcher.
    public static func clearAntigravityMicScript(tmuxSession: String? = nil) -> String {
        let launcher = AgentHooks.agyLauncher(micPort: nil)
        var parts = [
            pathSetup,
            "mkdir -p \"$HOME/.roamtty\"",
            "rm -f \"$HOME/.roamtty/voice-mic\"",
            "printf '%s' \(shellQuote(launcher)) > \"$HOME/.roamtty/agy\" && chmod +x \"$HOME/.roamtty/agy\""
        ]
        if let session = tmuxSession, !session.isEmpty {
            let safe = sanitizeSessionName(session)
            parts.append("tmux set-environment -u -t \(safe) ANTIGRAVITY_MIC 2>/dev/null || true")
        }
        return parts.joined(separator: "\n") + "\n"
    }
    private static func isValidEnvName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.isASCII,
              CharacterSet.letters.contains(first) || first == "_" else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }
    }
}
