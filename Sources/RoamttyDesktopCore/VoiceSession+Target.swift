import Foundation

extension VoiceSession {
    private struct CodexPane {
        let id: String, session: String, thread: String, cwd: String
        var boundThread: String? {
            session == thread && VoiceProtocol.validThread(thread) ? thread : nil
        }
    }

    func resolveCodexTarget(_ remote: DesktopHost) -> (thread: String, cwd: String?)? {
        guard let name = config.tmuxSession, !name.isEmpty else {
            guard let id = readCodexStatus(), VoiceProtocol.validThread(id) else { return nil }
            return (id, nil)
        }
        guard let pane = codexPane(remote, name: name) else { return nil }
        guard let thread = readCodexStatus(), VoiceProtocol.validThread(thread), !isClosing,
              let current = codexPane(remote, name: name), current.id == pane.id else { return nil }
        if current.boundThread == thread { return (thread, current.cwd) }
        // A TUI switch can leave even two matching pane fields stale. A concurrent hook update
        // for a third thread means the user switched again while /status was being read.
        guard current.boundThread == pane.boundThread, prepareCodexBind(remote), !isClosing else { return nil }
        let bind = "sh \"$HOME/.roamtty/agent-hook.sh\" codex bind '\(pane.id)' '\(thread)'\n"
        guard remote.run(bind, timeout: 4, onLine: { _ in }) == 0,
              let verified = codexPane(remote, name: name), verified.id == pane.id, verified.boundThread == thread else { return nil }
        return (thread, verified.cwd)
    }

    private func codexPane(_ remote: DesktopHost, name: String) -> CodexPane? {
        let safe = name.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/home/linuxbrew/.linuxbrew/bin:/snap/bin"; export PATH
        tmux -u display-message -p -t '=\(safe):' '#{pane_id}|#{@roamtty_session}|#{@roamtty_codex_thread}|#{pane_current_path}'
        """
        var line: String?
        guard remote.run(script + "\n", timeout: 4, onLine: { if line == nil { line = $0 } }) == 0, let line else { return nil }
        let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4, fields[0].first == "%", fields[0].count > 1,
              fields[0].dropFirst().utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return CodexPane(id: fields[0], session: fields[1], thread: fields[2], cwd: fields[3])
    }

    enum AgyKeyTarget: Equatable {
        case terminal
        case pane(String)
    }

    func agyKeyTarget(_ remote: DesktopHost, _ port: Int, windows: Bool) -> AgyKeyTarget? {
        let legacyDefault = port == VoiceProtocol.defaultPort
        guard let session = config.tmuxSession, !session.isEmpty else { return legacyDefault ? .terminal : nil }
        var line = ""
        let capture: (String) -> Void = { line = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let format = "'#{pane_id}|#{@roamtty_agy_mic}'"
        let status: Int?
        if windows {
            let target = session.replacingOccurrences(of: "'", with: "''")
            let cmd = PowerShell.command("psmux display-message -p -t '=\(target):' \(format); exit $LASTEXITCODE")
            status = remote.runCommand(cmd, timeout: 4, onLine: capture)
        } else {
            let target = session.replacingOccurrences(of: "'", with: "'\\''")
            let script = """
            PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/home/linuxbrew/.linuxbrew/bin:/snap/bin"; export PATH
            tmux -u display-message -p -t '=\(target):' \(format)
            """
            status = remote.run(script + "\n", timeout: 4, onLine: capture)
        }
        let fields = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard status == 0, fields.count == 2, fields[0].first == "%", fields[0].count > 1,
              fields[0].dropFirst().utf8.allSatisfy({ (48...57).contains($0) }),
              fields[1].isEmpty ? legacyDefault : fields[1] == "127.0.0.1:\(port)" else { return nil }
        return .pane(String(fields[0]))
    }
}
