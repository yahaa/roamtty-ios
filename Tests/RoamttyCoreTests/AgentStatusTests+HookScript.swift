import Foundation
import XCTest
@testable import RoamttyCore

/// The hook script against a stand-in tmux.
extension AgentStatusTests {
    final class HookFixture {
        let dir: URL
        let script: URL
        init(listPanes: Bool = false) throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-hook-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            script = dir.appendingPathComponent("agent-hook.sh")
            try AgentHooks.script.write(to: script, atomically: true, encoding: .utf8)
            // A stand-in tmux keeping each option in a file: `show-options -qv -t P NAME`, `set-option -q -t P NAME VALUE`,
            // `set-option -u -q -t P NAME`.
            var tmux = "#!/bin/sh\ncase \"$1\" in\n  show-options) cat \"\(dir.path)/opt$5\" 2>/dev/null ;;\n" +
                "  set-option) if [ \"$2\" = -u ]; then rm -f \"\(dir.path)/opt$6\"; else printf '%s' \"$6\" > \"\(dir.path)/opt$5\"; fi ;;\n"
            if listPanes { tmux += "  list-panes) printf '%%1 %s\\n' \"$(cat \"\(dir.path)/opt@roamtty_session\" 2>/dev/null)\" ;;\n" }
            // Every tmux session lives but one.
            tmux += "  has-session) [ \"$3\" != =gone ] ;;\n"
            tmux += "esac\n"
            let tool = dir.appendingPathComponent("tmux")
            try tmux.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        deinit { try? FileManager.default.removeItem(at: dir) }
        @discardableResult
        func run(_ arguments: [String], json: String, pane: String?, marker: String? = nil) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = dir.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            environment.removeValue(forKey: "TMUX_PANE")
            environment.removeValue(forKey: "ROAMTTY_AGENT")
            if let pane { environment["TMUX_PANE"] = pane }
            if let marker { environment["ROAMTTY_AGENT"] = marker }
            environment["COLUMNS"] = "20"
            process.environment = environment
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data(json.utf8)); try input.fileHandleForWriting.close()
            let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return stdout
        }
        @discardableResult
        func hook(_ event: String, _ json: String = "{}", agent: String = "claude", grok: Bool = false) throws -> String {
            try run([script.path, agent, event], json: json, pane: "%1", marker: grok ? "grok" : nil)
        }
        func agyHook(_ event: String, _ json: String = "{}", marker: String? = "agy") throws -> String {
            try run([script.path, "agy", event], json: json, pane: "%1", marker: marker)
        }
        func option(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent("opt" + name), encoding: .utf8) }
        func reported() -> String {
            let fields = (option("@roamtty_agent") ?? "").components(separatedBy: "|")
            return fields.count >= 5 ? "\(fields[0])|\(fields[3])|\(fields[4])" : ""
        }
    }

    func testAFinishedToolStaysShownUntilTheNextOneOrTheTurnsEnd() throws {
        let fixture = try HookFixture()
        try fixture.hook("prompt", #"{"prompt":"fix the bug"}"#)
        XCTAssertEqual(fixture.reported(), "working||")
        try fixture.hook("tool", #"{"tool_name":"Bash","tool_input":{"command":"make test"}}"#)
        XCTAssertEqual(fixture.reported(), "working|Bash|make test")
        try fixture.hook("post")
        XCTAssertEqual(fixture.reported(), "working|Bash|make test")
        try fixture.hook("tool", #"{"tool_name":"Read","tool_input":{"file_path":"src/a.kt"}}"#)
        try fixture.hook("post")
        XCTAssertEqual(fixture.reported(), "working|Read|src/a.kt")
        XCTAssertNil(fixture.option("@roamtty_worked"), "no turn has stopped yet")
        try fixture.hook("stop")
        XCTAssertEqual(fixture.reported(), "idle||")
        let worked = try XCTUnwrap(fixture.option("@roamtty_worked").flatMap(Int.init))
        XCTAssertTrue((0...60).contains(worked))
        try fixture.hook("prompt", #"{"prompt":"again"}"#)
        XCTAssertNil(fixture.option("@roamtty_worked"))
        try fixture.hook("end")
        XCTAssertNil(fixture.option("@roamtty_turn"))
    }

    func testAStoppedTurnLeavesTheStartOfItsAnswerUntilTheNextPrompt() throws {
        let fixture = try HookFixture()
        try fixture.hook("prompt", #"{"prompt":"fix the bug"}"#, agent: "claude", grok: true)
        try fixture.hook("stop", #"{"stop_hook_active":false,"last_assistant_message":"**Fixed** it.\nTests pass | 3/3"}"#, agent: "claude", grok: true)
        XCTAssertEqual(fixture.option("@roamtty_reply"), "**Fixed** it. Tests pass / 3/3")
        try fixture.hook("prompt", #"{"prompt":"again"}"#, agent: "claude", grok: true)
        XCTAssertNil(fixture.option("@roamtty_reply"))
        try fixture.hook("stop", #"{"stopHookActive":false,"lastAssistantMessage":"Done."}"#, agent: "grok", grok: true)
        XCTAssertEqual(fixture.option("@roamtty_reply"), "Done.")
        try fixture.hook("end", agent: "grok", grok: true)
        XCTAssertNil(fixture.option("@roamtty_reply"))
    }

    func testATurnWaitingForBackgroundWorkGoesOnUntilThatWorkWakesItAndEnds() throws {
        let fixture = try HookFixture()
        try fixture.hook("prompt", #"{"prompt":"run the suite"}"#)
        let turn = fixture.option("@roamtty_turn")
        // Claude Code's Stop as it comes while a background shell runs (an answer quoting the key changes nothing).
        try fixture.hook("stop", #"{"stop_hook_active":false,"last_assistant_message":"started \"background_tasks\":[{}]","#
            + #""background_tasks":[{"id":"b1","type":"shell","status":"running","description":"Run the suite","command":"make test"}],"session_crons":[]}"#)
        XCTAssertEqual(fixture.reported(), "working|Background|make test")
        XCTAssertNil(fixture.option("@roamtty_worked"))
        // Idle for a minute only to look at: it stays at work.
        try fixture.hook("notify", #"{"notification_type":"idle_prompt","message":"Claude is waiting for your input"}"#)
        XCTAssertEqual(fixture.reported(), "working|Background|make test")
        // The work ends and wakes it: the same turn and task go on, then end.
        try fixture.hook("prompt", #"{"prompt":"<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n</task-notification>"}"#)
        XCTAssertEqual(fixture.option("@roamtty_turn"), turn)
        XCTAssertEqual(fixture.option("@roamtty_task"), "run the suite")
        try fixture.hook("stop", #"{"last_assistant_message":"All green.","background_tasks":[],"session_crons":[]}"#)
        XCTAssertEqual(fixture.reported(), "idle||")
        XCTAssertNotNil(fixture.option("@roamtty_worked"))
        XCTAssertEqual(fixture.option("@roamtty_reply"), "All green.")
        // Grok names it in camelCase; a subagent says what it does. Only a scheduled wakeup is no work in flight.
        try fixture.hook("prompt", #"{"prompt":"review"}"#, agent: "grok", grok: true)
        try fixture.hook("stop",
            #"{"lastAssistantMessage":"spawned","backgroundTasks":[{"id":"a1","type":"subagent","status":"running","description":"Review the diff","agentType":"general"}],"sessionCrons":[]}"#,
            agent: "grok", grok: true)
        XCTAssertEqual(fixture.reported(), "working|Background|Review the diff")
        try fixture.hook("stop", #"{"lastAssistantMessage":"ok","backgroundTasks":[],"sessionCrons":[{"id":"c1","schedule":"*/5 * * * *"}]}"#, agent: "grok", grok: true)
        XCTAssertEqual(fixture.reported(), "idle||")
        // A new prompt of the user's while work runs in the background starts a turn of its own.
        try fixture.hook("stop", #"{"background_tasks":[{"id":"b2","type":"shell","status":"running","command":"sleep 60"}]}"#)
        try FileManager.default.removeItem(at: fixture.dir.appendingPathComponent("opt@roamtty_turn"))
        try fixture.hook("prompt", #"{"prompt":"something else"}"#)
        XCTAssertNotNil(fixture.option("@roamtty_turn"), "the user's prompt starts a turn")
        XCTAssertEqual(fixture.option("@roamtty_task"), "something else")
    }

    func testASessionSentToTheBackgroundStillReportsToItsPane() throws {
        let fixture = try HookFixture(listPanes: true)
        let id = "32c4597e-61a4-4ddd-ba0a-51f68f9d1148"
        // In the pane, or (pane = nil) under a process resuming the session, as Claude Code's background job runs.
        func hook(_ event: String, _ json: String, pane: String?, resumed: String = id) throws {
            if pane != nil {
                try fixture.run([fixture.script.path, "claude", event], json: json, pane: pane)
            } else {
                try fixture.run(["-c", "sh '\(fixture.script.path)' claude \(event); :", "--resume", "/p/\(resumed).jsonl", "--reply-on-resume"], json: json, pane: nil)
            }
        }
        try hook("tool", #"{"session_id":"\#(id)","tool_name":"Bash","tool_input":{"command":"make"}}"#, pane: "%1")
        XCTAssertEqual(fixture.option("@roamtty_session"), id)
        try hook("post", #"{"session_id":"forked"}"#, pane: nil)
        try hook("stop", #"{"session_id":"forked"}"#, pane: nil)
        XCTAssertEqual(fixture.reported(), "idle||")
        try hook("prompt", #"{"session_id":"forked","prompt":"next"}"#, pane: nil)
        XCTAssertEqual(fixture.reported(), "working||")
        XCTAssertEqual(fixture.option("@roamtty_task"), "next")
        try hook("end", #"{"session_id":"forked"}"#, pane: nil)
        try hook("start", #"{"session_id":"cleared"}"#, pane: nil)
        XCTAssertEqual(fixture.reported(), "idle||")
        XCTAssertEqual(fixture.option("@roamtty_session"), id)
        try hook("prompt", #"{"session_id":"other","prompt":"elsewhere"}"#, pane: nil, resumed: "00000000-0000-0000-0000-000000000000")
        XCTAssertEqual(fixture.reported(), "idle||")
    }

    func testABackgroundJobReportsToTheTmuxSessionItsSettingsName() throws {
        let fixture = try HookFixture()
        func job(_ event: String, _ json: String) throws { try fixture.run([fixture.script.path, "claude", event, "roamtty-a"], json: json, pane: nil) }
        try fixture.run([fixture.script.path, "claude", "start", "roamtty-a"], json: #"{"session_id":"pane"}"#, pane: "%1")
        XCTAssertEqual(fixture.reported(), "idle||")
        XCTAssertEqual(fixture.option("@roamtty_session"), "pane")
        // A spare process starts before any task: nothing changes until a job has one.
        try job("start", #"{"session_id":"spare"}"#)
        XCTAssertEqual(fixture.option("@roamtty_owner"), "pane")
        try job("prompt", #"{"session_id":"job","prompt":"fix it"}"#)
        XCTAssertEqual(fixture.reported(), "working||")
        XCTAssertEqual(fixture.option("@roamtty_task"), "fix it")
        try job("tool", #"{"session_id":"job","tool_name":"Bash","tool_input":{"command":"make"}}"#)
        XCTAssertEqual(fixture.reported(), "working|Bash|make")
        XCTAssertEqual(fixture.option("@roamtty_session"), "pane", "a job's id never replaces the pane's")
        // The session left in the pane has nothing to say about the job's work.
        try fixture.run([fixture.script.path, "claude", "notify", "roamtty-a"], json: #"{"session_id":"pane","notification_type":"idle_prompt"}"#, pane: "%1")
        XCTAssertEqual(fixture.reported(), "working|Bash|make")
        try job("notify", #"{"session_id":"job","notification_type":"permission_prompt","message":"needs permission"}"#)
        XCTAssertEqual(fixture.reported(), "waiting|Bash|make")
        try job("post", #"{"session_id":"job"}"#)
        try job("stop", #"{"session_id":"job","last_assistant_message":"done"}"#)
        XCTAssertEqual(fixture.reported(), "idle||")
        XCTAssertEqual(fixture.option("@roamtty_reply"), "done")
    }

    func testAJobThatEndsMidTurnStopsTheWorkButLeavesThePanesOptions() throws {
        let fixture = try HookFixture()
        func job(_ event: String, _ json: String) throws { try fixture.run([fixture.script.path, "claude", event, "s"], json: json, pane: nil) }
        try job("prompt", #"{"session_id":"job","prompt":"long"}"#)
        try job("tool", #"{"session_id":"job","tool_name":"Bash","tool_input":{"command":"make"}}"#)
        try job("end", #"{"session_id":"other"}"#)
        XCTAssertEqual(fixture.reported(), "working|Bash|make", "another session's end says nothing about this work")
        try job("end", #"{"session_id":"job"}"#)
        XCTAssertEqual(fixture.reported(), "idle||")
        XCTAssertEqual(fixture.option("@roamtty_task"), "long")
    }

    func testOnlyTheSessionThatReportedLastSaysTheWorkStopped() throws {
        let fixture = try HookFixture()
        func job(_ event: String, _ id: String) throws { try fixture.run([fixture.script.path, "claude", event, "s"], json: #"{"session_id":"\#(id)","prompt":"go"}"#, pane: nil) }
        try job("prompt", "a")
        try job("prompt", "b")
        try job("stop", "a")
        XCTAssertEqual(fixture.reported(), "working||")
        try job("stop", "b")
        XCTAssertEqual(fixture.reported(), "idle||")
    }

    func testAJobLeavesAPaneRunningAnotherAgentAndAnEndedSessionAlone() throws {
        let fixture = try HookFixture()
        try fixture.hook("prompt", #"{"prompt":"codex work"}"#, agent: "codex")
        let codex = fixture.option("@roamtty_agent")
        try fixture.run([fixture.script.path, "claude", "prompt", "s"], json: #"{"session_id":"job","prompt":"not yours"}"#, pane: nil)
        XCTAssertEqual(fixture.option("@roamtty_agent"), codex)
        XCTAssertEqual(fixture.option("@roamtty_task"), "codex work")

        let ended = try HookFixture()
        try ended.run([ended.script.path, "claude", "prompt", "gone"], json: #"{"session_id":"job","prompt":"late"}"#, pane: nil)
        XCTAssertNil(ended.option("@roamtty_agent"))
    }

    func testCodexKeepsReportingWhateverSessionIdsItSends() throws {
        let fixture = try HookFixture()
        try fixture.hook("prompt", #"{"session_id":"a","prompt":"go"}"#, agent: "codex")
        try fixture.hook("stop", #"{"session_id":"b"}"#, agent: "codex")
        XCTAssertEqual(fixture.reported(), "idle||")
        XCTAssertNil(fixture.option("@roamtty_owner"))
    }

    func testPruningKeepsSettingsOfLiveSessionsAndRecentFiles() throws {
        let fixture = try HookFixture()
        let folder = fixture.dir.appendingPathComponent(".roamtty")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = Date(timeIntervalSinceNow: -40 * 86_400)
        for (name, date) in [("claude-hooks-gone.json", old), ("claude-hooks-live.json", old), ("claude-hooks.json", old), ("claude-hooks-new.json", Date())] {
            let file = folder.appendingPathComponent(name)
            try Data().write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        // The stand-in tmux takes `has-session -t =name` as $3; a pruned name other than "gone" counts as alive.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AgentHooks.pruneSettings]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fixture.dir.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["HOME"] = fixture.dir.path
        process.environment = environment
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(left, ["claude-hooks-live.json", "claude-hooks-new.json", "claude-hooks.json"])
    }

    func testClaudeStartedInATmuxSessionNamesItInItsSettings() {
        let launch = AgentLaunch(agent: .claude, directory: "/home/v/app")
        XCTAssertEqual(launch.commandLine(session: "roamtty-AB12"), "cd -- '/home/v/app' && claude --settings ~/.roamtty/claude-hooks-roamtty-AB12.json")
        let file = AgentHooks.hostFile(.claude, session: "roamtty-AB12")
        XCTAssertEqual(file.name, "claude-hooks-roamtty-AB12.json")
        XCTAssertFalse(file.executable)
        XCTAssertTrue(file.content.contains(#""command":"sh ~/.roamtty/agent-hook.sh claude stop roamtty-AB12""#))
        // Without a tmux session, or with a name that cannot go into a command as it is, as before.
        for session in [nil, "", "a b", "a;b", "会话"] as [String?] {
            XCTAssertEqual(launch.commandLine(session: session), launch.commandLine)
            XCTAssertEqual(AgentHooks.hostFile(.claude, session: session).name, "claude-hooks.json")
        }
        XCTAssertEqual(AgentHooks.hostFile(.claude).content, AgentHooks.claudeSettings)
        // Other agents have one launcher and report from inside the pane.
        XCTAssertEqual(AgentLaunch(agent: .codex, directory: "~").commandLine(session: "s"), AgentLaunch(agent: .codex, directory: "~").commandLine)
        XCTAssertEqual(AgentHooks.hostFile(.codex, session: "s").name, "codex")
    }

    func testAStatusThatOnlyAgedIsTheSameButARestartedOneIsNot() {
        let working = AgentStatus(state: .working, agent: "claude", tool: "Bash", elapsedMillis: 10_000)
        var aged = working; aged.elapsedMillis = 13_200
        XCTAssertTrue(AgentStatus.sameExceptAge(working, aged, after: 3))
        var restarted = working; restarted.elapsedMillis = 400
        XCTAssertFalse(AgentStatus.sameExceptAge(working, restarted, after: 3))
        // A turn that restarted just after the last poll went back by less than the slack, but it is a new state.
        var young = working; young.elapsedMillis = 1_000
        var restartedYoung = working; restartedYoung.elapsedMillis = 0
        XCTAssertFalse(AgentStatus.sameExceptAge(young, restartedYoung, after: 3))
        var otherTool = aged; otherTool.tool = "Edit"
        XCTAssertFalse(AgentStatus.sameExceptAge(working, otherTool, after: 3))
        XCTAssertFalse(AgentStatus.sameExceptAge(working, nil, after: 3))
        XCTAssertFalse(AgentStatus.sameExceptAge(nil, working, after: 3))
        XCTAssertTrue(AgentStatus.sameExceptAge(nil, nil, after: 3))
    }
}
