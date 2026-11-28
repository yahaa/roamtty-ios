import XCTest
@testable import RoamttyCore

extension AgentUsageTests {
    func testCodexPaneOnlyReadsItsConfirmedThread() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("roamtty-codex-start-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let binDir = home.appendingPathComponent("bin")
        let codexDir = home.appendingPathComponent(".codex/sessions/2026/11/28")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let oldRollout = [
            #"{"timestamp":"2026-11-28T12:00:00Z","type":"session_meta","payload":{"id":"sid-old","timestamp":"2026-11-28T12:00:00Z","cwd":"/work/app"}}"#,
            #"{"timestamp":"2026-11-28T12:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"#
                + #""total_token_usage":{"input_tokens":10000,"cached_input_tokens":0,"output_tokens":500},"#
                + #""last_token_usage":{"input_tokens":10000,"cached_input_tokens":0,"output_tokens":500},"model_context_window":200000}}}"#
        ].joined(separator: "\n") + "\n"
        let oldURL = codexDir.appendingPathComponent("rollout-old-aaa.jsonl")
        try oldRollout.write(to: oldURL, atomically: true, encoding: .utf8)

        let newRollout = [
            #"{"timestamp":"2026-11-28T12:48:25Z","type":"session_meta","payload":{"id":"sid-new","timestamp":"2026-11-28T12:47:55Z","cwd":"/work/app"}}"#,
            #"{"timestamp":"2026-11-28T12:48:30Z","type":"turn_context","payload":{"model":"gpt-6.2-astra","effort":"medium","cwd":"/work/app"}}"#,
            #"{"timestamp":"2026-11-28T12:49:00Z","type":"event_msg","payload":{"type":"token_count","info":{"#
                + #""total_token_usage":{"input_tokens":60000,"cached_input_tokens":40000,"output_tokens":1000},"#
                + #""last_token_usage":{"input_tokens":60000,"cached_input_tokens":40000,"output_tokens":1000},"model_context_window":258400}}}"#
        ].joined(separator: "\n") + "\n"
        let newURL = codexDir.appendingPathComponent("rollout-new-bbb.jsonl")
        try newRollout.write(to: newURL, atomically: true, encoding: .utf8)

        let fakeTmux = binDir.appendingPathComponent("tmux")
        let tmuxBody = """
        #!/bin/sh
        if [ "$1" = -u ]; then shift; fi
        case "$1" in
          display-message)
            target="$4"; fmt="$5"
            case "$target:$fmt" in
              *=sess-active:*) printf 'idle|1795870073|codex||\\tsid-new\\t\(newURL.path)\\t/work/app\\t100\\tsid-new\\n' ;;
              *=sess-gone:*) printf '\\tsid-new\\t\(newURL.path)\\t/work/app\\t101\\tsid-new\\n' ;;
              *=sess-fresh:*) printf 'idle|1795870073|codex||\\tsid-new\\t\(newURL.path)\\t/work/app\\t101\\t\\n' ;;
            esac ;;
          list-panes)
            printf 'sess-active\\t\\nsess-fresh\\t\\n' ;;
        esac
        """
        try tmuxBody.write(to: fakeTmux, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeTmux.path)

        func query(_ tmuxSession: String) throws -> AgentSessionUsage? {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", AgentUsage.sessionCommand(agent: .codex, tmuxSession: tmuxSession, directory: "/work/app")]
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = home.path
            env["PATH"] = binDir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            env["ROAMTTY_NO_LIVE_QUOTA"] = "1"
            proc.environment = env
            let stdinPipe = Pipe(), stdoutPipe = Pipe()
            proc.standardInput = stdinPipe
            proc.standardOutput = stdoutPipe
            try proc.run()
            stdinPipe.fileHandleForWriting.write(AgentUsage.scriptData)
            try stdinPipe.fileHandleForWriting.close()
            proc.waitUntilExit()
            XCTAssertEqual(proc.terminationStatus, 0)
            let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            return AgentUsage.parseSession(out)
        }

        let active = try XCTUnwrap(query("sess-active"))
        XCTAssertEqual(active.contextUsed, 60_000)
        XCTAssertEqual(active.contextLimit, 258_400)
        XCTAssertEqual(active.contextPercent, 23)
        XCTAssertEqual(active.formattedModel, "gpt-6.2-astra")

        let fresh = try query("sess-fresh")
        XCTAssertNil(fresh?.contextUsed)
        XCTAssertNil(fresh?.contextPercent)
        XCTAssertNil(try query("sess-missing")?.contextUsed)
        XCTAssertNil(try query("sess-gone")?.contextUsed)
    }
}
