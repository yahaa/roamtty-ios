import Foundation
import XCTest
@testable import RoamttyCore

/// Antigravity CLI (agy) hook script behavior against a stand-in tmux.
extension AgentStatusTests {
    func testAgyHooksReportTurnToolsAndQuestions() throws {
        let fixture = try HookFixture()
        // Outside Roamtty (no ROAMTTY_AGENT): ignored, empty stdout so PreToolUse never blocks.
        XCTAssertEqual(try fixture.agyHook("tool", #"{"toolCall":{"args":{"CommandLine":"ls"},"id":"c0","name":"run_command"}}"#, marker: nil), "")
        XCTAssertNil(fixture.option("@roamtty_agent"))

        // Launcher reports idle on start.
        XCTAssertEqual(try fixture.agyHook("start"), "")
        XCTAssertEqual(fixture.reported(), "idle||")

        // PreInvocation invocationNum 0 starts a turn.
        XCTAssertEqual(try fixture.agyHook("prompt", #"{"invocationNum":0,"lastUserInput":"fix the build"}"#), "")
        XCTAssertEqual(fixture.reported(), "working||")
        XCTAssertEqual(fixture.option("@roamtty_task"), "fix the build")
        let turn = try XCTUnwrap(fixture.option("@roamtty_turn"))

        // PreToolUse reads toolCall.name and CommandLine, with empty stdout so agy keeps normal permissions.
        XCTAssertEqual(try fixture.agyHook("tool",
            #"{"lastUserInput":"fix the build","toolCall":{"args":{"CommandLine":"./gradlew test","toolSummary":"Run tests"},"id":"c1","name":"run_command"}}"#), "")
        XCTAssertEqual(fixture.reported(), "working|run_command|./gradlew test")
        XCTAssertEqual(try fixture.agyHook("post", #"{"toolCall":{"args":{"CommandLine":"./gradlew test"},"id":"c1","name":"run_command"}}"#), "")
        // PreInvocation invocationNum 1 keeps the turn and finished tool.
        XCTAssertEqual(try fixture.agyHook("prompt", #"{"invocationNum":1,"lastUserInput":"fix the build"}"#), "")
        XCTAssertEqual(fixture.reported(), "working|run_command|./gradlew test")
        XCTAssertEqual(fixture.option("@roamtty_turn"), turn)

        // write_file uses Path; escaped keys inside Content must not hijack CommandLine or Path.
        XCTAssertEqual(try fixture.agyHook("tool",
            #"{"toolCall":{"args":{"Content":"{\"CommandLine\":\"fake\"}","Path":"/repo/src/Main.kt"},"id":"c2","name":"write_file"}}"#), "")
        XCTAssertEqual(fixture.reported(), "working|write_file|/repo/src/Main.kt")

        // ask_question waits for the user; PostToolUse returns to working.
        XCTAssertEqual(try fixture.agyHook("tool",
            #"{"toolCall":{"args":{"questions":[{"question":"Which option?","options":["A","B"]}]},"id":"c3","name":"ask_question"}}"#), "")
        XCTAssertEqual(fixture.reported(), "waiting|ask_question|Which option?")
        XCTAssertEqual(try fixture.agyHook("post"), "")
        XCTAssertEqual(fixture.reported(), "working|ask_question|Which option?")
    }

    func testAgyHooksReadTranscriptAndKeepBackgroundWork() throws {
        let fixture = try HookFixture()
        let transcript = fixture.dir.appendingPathComponent("transcript_full.jsonl")
        XCTAssertEqual(try fixture.agyHook("prompt", #"{"invocationNum":0,"lastUserInput":"fix the build"}"#), "")
        let turn = try XCTUnwrap(fixture.option("@roamtty_turn"))

        // Stop with fullyIdle:false stays working on background tasks.
        XCTAssertEqual(try fixture.agyHook("stop", #"{"fullyIdle":false,"terminationReason":"NO_TOOL_CALL","transcriptPath":"\#(transcript.path)"}"#), "")
        XCTAssertEqual(fixture.reported(), "working|Background|")
        XCTAssertNil(fixture.option("@roamtty_worked"))

        // Background wakeup with same lastUserInput keeps the turn clock.
        XCTAssertEqual(try fixture.agyHook("prompt", #"{"invocationNum":0,"lastUserInput":"fix the build"}"#), "")
        XCTAssertEqual(fixture.option("@roamtty_turn"), turn)

        // Stop with fullyIdle:true reads the final PLANNER_RESPONSE content from transcriptPath.
        let lines = [
            #"{"step_index":1,"type":"PLANNER_RESPONSE","thinking":"check \"content\":\"ignored\"","tool_calls":[{"name":"run_command"}]}"#,
            #"{"step_index":2,"type":"GENERIC","content":"tool output"}"#,
            #"{"step_index":3,"type":"PLANNER_RESPONSE","thinking":"done","content":"**All** tests pass.\nReady | green"}"#
        ].joined(separator: "\n") + "\n"
        try lines.write(to: transcript, atomically: true, encoding: .utf8)
        XCTAssertEqual(try fixture.agyHook("stop", #"{"fullyIdle":true,"terminationReason":"NO_TOOL_CALL","transcriptPath":"\#(transcript.path)"}"#), "")
        XCTAssertEqual(fixture.reported(), "idle||")
        XCTAssertNotNil(fixture.option("@roamtty_worked"))
        XCTAssertEqual(fixture.option("@roamtty_reply"), "**All** tests pass. Ready / green")

        // End clears options.
        XCTAssertEqual(try fixture.agyHook("end"), "")
        XCTAssertNil(fixture.option("@roamtty_agent"))
        XCTAssertNil(fixture.option("@roamtty_reply"))
    }

    func testAgyLauncherExecutesWritesValidPluginAndPropagatesExitCode() throws {
        let fixture = try HookFixture()
        let roamtty = fixture.dir.appendingPathComponent(".roamtty")
        try FileManager.default.createDirectory(at: roamtty, withIntermediateDirectories: true)
        try AgentHooks.script.write(to: roamtty.appendingPathComponent(AgentHooks.scriptName), atomically: true, encoding: .utf8)
        let launcher = roamtty.appendingPathComponent("agy")
        try AgentHooks.agyLauncher.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let fakeAgy = fixture.dir.appendingPathComponent("agy")
        let seen = fixture.dir.appendingPathComponent("seen.txt")
        let fakeBody = "#!/bin/sh\nprintf '%s|%s|%s' \"$ROAMTTY_AGENT\" \"$*\" \"$(cat '\(fixture.dir.path)/opt@roamtty_agent')\" > '\(seen.path)'\nexit 7\n"
        try fakeBody.write(to: fakeAgy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeAgy.path)

        let process = Process()
        process.executableURL = launcher
        process.arguments = ["--mode", "plan"]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = fixture.dir.path
        env["PATH"] = fixture.dir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["TMUX_PANE"] = "%1"
        process.environment = env
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 7)

        let pluginDir = fixture.dir.appendingPathComponent(".gemini/config/plugins/roamtty")
        let pluginJSON = try JSONSerialization.jsonObject(with: try Data(contentsOf: pluginDir.appendingPathComponent("plugin.json"))) as? [String: Any]
        let hooksJSON = try JSONSerialization.jsonObject(with: try Data(contentsOf: pluginDir.appendingPathComponent("hooks.json"))) as? [String: Any]
        XCTAssertEqual(pluginJSON?["name"] as? String, "roamtty")
        XCTAssertNotNil(hooksJSON?["roamtty"] as? [String: Any])
        let recorded = try String(contentsOf: seen, encoding: .utf8)
        XCTAssertTrue(recorded.hasPrefix("agy|--mode plan|idle|"), recorded)
        XCTAssertNil(fixture.option("@roamtty_agent"), "end hook clears state after agy exits")
    }
}
