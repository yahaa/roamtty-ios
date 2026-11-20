import Foundation
import XCTest
@testable import RoamttyCore

/// Ports Android's AgentStatusTest, AgentLaunchTest (hooks), SessionGroupsTest and SessionTransportTagsTest.
final class AgentStatusTests: XCTestCase {
    func testReadsTheStateTheToolAndTheTask() throws {
        let status = try XCTUnwrap(AgentStatus.parse("claude|working|1000|claude|Bash|npm test|fix the bug\n1042\n"))
        XCTAssertEqual(status.state, .working)
        XCTAssertEqual(status.tool, "Bash")
        XCTAssertEqual(status.detail, "npm test")
        XCTAssertEqual(status.task, "fix the bug")
        XCTAssertEqual(status.elapsedMillis, 42_000)
    }

    /// The list keeps what an agent reported last across launches, until its host answers again.
    func testALastReportSurvivesBeingSaved() throws {
        let status = AgentStatus(state: .idle, agent: "claude", task: "fix the bug", elapsedMillis: 42_000, directory: "~/app",
                                 workedSeconds: 75, reply: "Done.")
        XCTAssertEqual(try JSONDecoder().decode(AgentStatus.self, from: JSONEncoder().encode(status)), status)
    }

    func testAnAgentThatLeftLeavesNothing() {
        XCTAssertNil(AgentStatus.parse("zsh|working|1000|claude|Bash|x|task\n1042"))
        XCTAssertNil(AgentStatus.parse("-bash|idle|1000|claude|||task\n1042"))
        // Codex, Grok and Antigravity run under their launcher.
        XCTAssertEqual(AgentStatus.parse("sh|idle|1000|codex|||task\n1042")?.state, .idle)
        // On macOS /bin/sh is bash, so the launcher shows as "bash".
        XCTAssertEqual(AgentStatus.parse("bash|idle|1000|codex|||task\n1042")?.state, .idle)
        XCTAssertEqual(AgentStatus.parse("bash|working|1000|grok|||task\n1042")?.state, .working)
        XCTAssertEqual(AgentStatus.parse("sh|working|1000|agy|run_command|ls|task\n1042")?.state, .working)
        XCTAssertEqual(AgentStatus.parse("bash|idle|1000|agy|||task\n1042")?.state, .idle)
    }

    func testNoReportsOrUnknownStatesMeanNoStatus() {
        XCTAssertNil(AgentStatus.parse(nil))
        XCTAssertNil(AgentStatus.parse("claude|||||\n1042"))
        XCTAssertNil(AgentStatus.parse("claude|sleeping|1|claude|||\n2"))
        XCTAssertNil(AgentStatus.parse("garbage"))
    }

    func testHalfACharacterAtTheEndOfTheTaskIsDropped() {
        XCTAssertEqual(AgentStatus.parse("node|idle|1|claude|||修复\u{FFFD}\n2")?.task, "修复")
    }

    func testClockSkewNeverGivesNegativeTime() {
        XCTAssertEqual(AgentStatus.parse("node|waiting|50|claude|||\n40")?.elapsedMillis, 0)
    }

    func testHookSettingsNeedNoShellQuoting() {
        let json = AgentHooks.claudeSettings
        XCTAssertFalse(json.contains("'") || json.contains("\\"))
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"] {
            XCTAssertTrue(json.contains("\"\(event)\""), event)
        }
        XCTAssertTrue(json.contains("sh ~/.roamtty/agent-hook.sh claude prompt"))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    func testCodexTrustsItsHooksByTheHashCodexComputes() {
        // Codex 0.162 recorded these when its "Trust all" trusted the hooks, given with a 3 s timeout.
        let log = "sh /tmp/claude-1000/-home-v-work-roamtty/50a4e347-10a1-4c15-b785-1225642298e2/scratchpad/log.sh"
        XCTAssertEqual(AgentHooks.codexHookHash(eventKey: "stop", command: log + " stop"), "sha256:4f1b2dd4a5d87385b74e8495a0d38d8a4b88cccbd10f8b0b1efe806677c4e1ad")
        XCTAssertEqual(AgentHooks.codexHookHash(eventKey: "interrupt", command: log + " stop"), "sha256:9d388d80df6c839ca91447ad8ec4ad0b9b42f961b8d1d704b77381cd7e484800")
        let launcher = AgentHooks.codexLauncher
        XCTAssertTrue(launcher.hasPrefix("#!/bin/sh"))
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd"] {
            XCTAssertTrue(launcher.contains("-c 'hooks.\(event)=[{hooks=[{type=\"command\",command=\"sh ~/.roamtty/agent-hook.sh codex "), event)
        }
        XCTAssertTrue(launcher.contains("trust stop " + AgentHooks.codexHookHash(eventKey: "stop", command: "sh ~/.roamtty/agent-hook.sh codex stop")))
        XCTAssertTrue(launcher.contains("  \"$@\"\nstatus=$?\nsh ~/.roamtty/agent-hook.sh codex end </dev/null\nexit $status\n"))
    }

    func testGrokHooksActOnlyForAGrokStartedByTheApp() {
        let launcher = AgentHooks.grokLauncher
        XCTAssertTrue(launcher.contains("\"StopCancelled\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"sh ~/.roamtty/agent-hook.sh grok stop\"}]}]"))
        XCTAssertTrue(launcher.contains("export ROAMTTY_AGENT=grok\ngrok \"$@\"\n"))
        XCTAssertTrue(AgentHooks.script.contains("case \"$agent\" in grok|agy) [ \"$ROAMTTY_AGENT\" = \"$agent\" ] || exit 0 ;; esac"))
        XCTAssertTrue(AgentHooks.script.hasPrefix("#!/bin/sh"))
    }

    func testAgyLauncherInstallsPluginAndReportsStartAndEnd() {
        let (name, launcher, executable) = AgentHooks.hostFile(.agy)
        XCTAssertEqual(name, "agy")
        XCTAssertTrue(executable)
        XCTAssertTrue(launcher.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(launcher.contains("dir=\"$HOME/.gemini/config/plugins/roamtty\""))
        XCTAssertTrue(launcher.contains("\"PreInvocation\":[{\"type\":\"command\",\"command\":\"sh ~/.roamtty/agent-hook.sh agy prompt\"}]"))
        XCTAssertTrue(launcher.contains("\"PreToolUse\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"sh ~/.roamtty/agent-hook.sh agy tool\"}]}]"))
        XCTAssertTrue(launcher.contains("\"PostToolUse\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"sh ~/.roamtty/agent-hook.sh agy post\"}]}]"))
        XCTAssertTrue(launcher.contains("\"Stop\":[{\"type\":\"command\",\"command\":\"sh ~/.roamtty/agent-hook.sh agy stop\"}]"))
        XCTAssertTrue(launcher.contains("export ROAMTTY_AGENT=agy\nsh ~/.roamtty/agent-hook.sh agy start </dev/null\nagy \"$@\"\n"))
        XCTAssertTrue(launcher.contains("status=$?\nsh ~/.roamtty/agent-hook.sh agy end </dev/null\nexit $status\n"))
    }

    func testAgentsStartWithTheirHooks() {
        XCTAssertEqual(AgentLaunch(agent: .claude, directory: "/home/v/app").commandLine, "cd -- '/home/v/app' && claude --settings ~/.roamtty/claude-hooks.json")
        XCTAssertEqual(AgentLaunch(agent: .claude, directory: "~").commandLine, "claude --settings ~/.roamtty/claude-hooks.json")
        XCTAssertEqual(AgentLaunch(agent: .grok, directory: "~/work/app").commandLine, "cd -- ~/'work/app' && ~/.roamtty/grok")
        XCTAssertEqual(AgentLaunch(agent: .codex, directory: "/srv/it's $(x) dir").commandLine, "cd -- '/srv/it'\\''s $(x) dir' && ~/.roamtty/codex")
        XCTAssertEqual(AgentLaunch(agent: .codex, directory: "/a", mode: .readOnly).commandLine, "cd -- '/a' && ~/.roamtty/codex --sandbox read-only")
        XCTAssertEqual(AgentLaunch(agent: .grok, directory: "/a", mode: .yolo).commandLine, "cd -- '/a' && ~/.roamtty/grok --always-approve")
        XCTAssertEqual(AgentLaunch(agent: .agy, directory: "/a", mode: .readOnly).commandLine, "cd -- '/a' && ~/.roamtty/agy --mode plan")
        XCTAssertEqual(AgentLaunch(agent: .agy, directory: "~", mode: .yolo).commandLine, "~/.roamtty/agy --dangerously-skip-permissions")
        XCTAssertEqual(AgentHooks.hostFile(.claude).name, "claude-hooks.json")
        XCTAssertTrue(AgentHooks.hostFile(.codex).executable)
        XCTAssertTrue(AgentHooks.hostFile(.agy).executable)
    }

    func testRestoredSessionsTellTheirAgentByTitle() {
        XCTAssertEqual(CodingAgent.fromTitle(AgentLaunch(agent: .grok, directory: "/srv/roamtty").title), .grok)
        XCTAssertEqual(CodingAgent.fromTitle(AgentLaunch(agent: .agy, directory: "/srv/roamtty").title), .agy)
        XCTAssertEqual(CodingAgent.fromTitle("Antigravity CLI · roamtty"), .agy)
        XCTAssertEqual(CodingAgent.fromTitle("Codex · roamtty"), .codex)
        XCTAssertEqual(CodingAgent.fromTitle("Claude Code · roamtty"), .claude)
        XCTAssertNil(CodingAgent.fromTitle("部署脚本"))
        XCTAssertNil(CodingAgent.fromTitle("Grokking notes"))
        XCTAssertEqual(CodingAgent.fromCommand("claude"), .claude)
        XCTAssertEqual(CodingAgent.fromCommand("agy"), .agy)
        XCTAssertNil(CodingAgent.fromCommand("gemini"))
    }

    func testActivityShowsWhatTheAgentRuns() throws {
        let working = try XCTUnwrap(AgentStatus.parse("sh|working|1|codex|Bash|make test|t\n2"))
        func with(_ change: (inout AgentStatus) -> Void) -> AgentStatus { var copy = working; change(&copy); return copy }
        XCTAssertEqual(agentActivity(working), "Running make test")
        XCTAssertEqual(agentActivity(with { $0.tool = "run_terminal_command"; $0.detail = "sleep 6" }), "Running sleep 6")
        XCTAssertEqual(agentActivity(with { $0.agent = "agy"; $0.tool = "run_command"; $0.detail = "./gradlew test" }), "Running ./gradlew test")
        XCTAssertEqual(agentActivity(with { $0.tool = "Read"; $0.detail = "src/a.kt" }), "Read src/a.kt")
        XCTAssertEqual(agentActivity(with { $0.tool = "WebSearch"; $0.detail = "" }), "WebSearch")
        XCTAssertEqual(agentActivity(with { $0.state = .waiting; $0.tool = ""; $0.detail = "Claude needs your permission to use Bash" }), "Claude needs your permission to use Bash")
        XCTAssertEqual(agentActivity(with { $0.tool = ""; $0.detail = "" }), "")
        XCTAssertEqual(agentActivity(with { $0.state = .idle }), "")
        XCTAssertEqual(agentActivity(nil), "")
    }

    func testReadsTheReplyOfAnIdleAgentOnly() throws {
        let idle = try XCTUnwrap(AgentStatus.parse("claude|idle|1000|claude|||75|fix the bug|All fixed.\n/home/v\n1042\n"))
        XCTAssertEqual(idle.task, "fix the bug")
        XCTAssertEqual(idle.reply, "All fixed.")
        XCTAssertEqual(idle.workedSeconds, 75)
        XCTAssertEqual(AgentStatus.parse("claude|working|1000|claude|Bash|ls||fix the bug|old\n1042")?.reply, "")
        XCTAssertEqual(AgentStatus.parse("claude|working|1000|claude|Bash|ls||fix the bug|old\n1042")?.task, "fix the bug")
    }

    func testAReplyReadsAsPlainText() {
        XCTAssertEqual(replyPreview("## Fixed **the parser** in `AgentStatus.kt`, see [docs](https://x.y/z); ready   to merge."),
                       "Fixed the parser in AgentStatus.kt, see docs; ready to merge.")
        XCTAssertEqual(replyPreview("- Two branches - both fine"), "Two branches - both fine")
        XCTAssertEqual(replyPreview("__init__.py updated"), "__init__.py updated")
    }

    func testAStoppedTurnSaysHowLongItWorked() throws {
        let idle = try XCTUnwrap(AgentStatus.parse("claude|idle|1000|claude|||75|fix the bug\n/home/v\n1042\n"))
        XCTAssertEqual(idle.workedSeconds, 75)
        XCTAssertEqual(idle.task, "fix the bug")
        XCTAssertEqual(idle.directory, "/home/v")
        XCTAssertNil(AgentStatus.parse("claude|working|1000|claude|Bash|ls||fix the bug\n1042")?.workedSeconds)
        XCTAssertNil(AgentStatus.parse("claude|idle|1000|claude||||fix the bug\n1042")?.workedSeconds)
        XCTAssertNil(AgentStatus.parse("claude|idle|1000|claude|||fix the bug\n1042")?.workedSeconds)
    }

    func testReadsThePanesFolderBeforeTheClock() throws {
        let status = try XCTUnwrap(AgentStatus.parse("claude|idle|1000|claude|||\n/home/v/roamtty\n1042\n"))
        XCTAssertEqual(status.directory, "/home/v/roamtty")
        XCTAssertEqual(status.elapsedMillis, 42_000)
        XCTAssertEqual(AgentStatus.parse("claude|idle|1000|claude|||\n1042")?.directory, "")
    }

    func testReadsThePanesFolderWithoutAnAgent() {
        XCTAssertNil(AgentStatus.parse("bash||||||\n/home/v/work\n1042"))
        XCTAssertEqual(AgentStatus.directory("bash||||||\n/home/v/work\n1042"), "/home/v/work")
        XCTAssertEqual(sessionListPath("/home/v/work", username: "v"), "~/work")
        XCTAssertEqual(AgentStatus.directory("bash||||||\n1042"), "")
        XCTAssertEqual(AgentStatus.directory(nil), "")
        XCTAssertEqual(sessionListPath("", username: "v"), "")
    }

    func testListTitleIsTheTaskThenTheAgentAndFolderThenTheTitle() throws {
        let working = try XCTUnwrap(AgentStatus.parse("claude|working|1|claude|||fix the bug\n/home/v/roamtty\n2"))
        XCTAssertEqual(sessionListTitle("Claude · roamtty", status: working, agent: .claude, username: "v"), "fix the bug")
        var fresh = working; fresh.task = ""
        func at(_ directory: String) -> AgentStatus { var copy = fresh; copy.directory = directory; return copy }
        XCTAssertEqual(sessionListTitle("Claude · roamtty", status: fresh, agent: .claude, username: "v"), "Claude · roamtty")
        XCTAssertEqual(sessionListPath(fresh, username: "v"), "~/roamtty")
        XCTAssertEqual(sessionListTitle("", status: at("/Users/v"), agent: .claude, username: "v"), "Claude · ~")
        XCTAssertEqual(sessionListTitle("", status: at("/"), agent: .codex, username: "v"), "Codex · /")
        XCTAssertEqual(sessionListTitle("", status: at("/srv/web"), agent: nil, username: "v"), "web")
        XCTAssertEqual(sessionListPath(at("/srv/web"), username: "v"), "/srv/web")
        XCTAssertEqual(sessionListPath(at("/root/x"), username: "root"), "~/x")
        XCTAssertEqual(sessionListPath(nil as AgentStatus?, username: "v"), "")
        XCTAssertEqual(sessionListTitle("Claude · roamtty", status: nil, agent: .claude, username: "v"), "Claude · roamtty")
        XCTAssertEqual(sessionListTitle("Claude Code · roamtty", status: nil, agent: .claude, username: "v"), "Claude · roamtty")
        XCTAssertEqual(sessionListTitle("部署脚本", status: nil, agent: .claude, username: "v"), "部署脚本")
        XCTAssertEqual(sessionListTitle("Claude · roamtty", status: nil, agent: nil, username: "v"), "Claude · roamtty")
    }

    func testGroupsByWhatTheAgentDoesWhileConnected() {
        func status(_ state: AgentStatus.State) -> AgentStatus { AgentStatus(state: state, agent: "claude") }
        XCTAssertEqual(sessionGroup(connected: true, status: status(.waiting)), .waiting)
        XCTAssertEqual(sessionGroup(connected: true, status: status(.working)), .working)
        XCTAssertEqual(sessionGroup(connected: true, status: status(.idle)), .done)
        XCTAssertEqual(sessionGroup(connected: true, status: nil), .other)
        XCTAssertEqual(sessionGroup(connected: false, status: status(.waiting)), .other)
    }

    func testDurationsStayShortAndUnbroken() {
        XCTAssertEqual(shortDuration(12), "12s")
        XCTAssertEqual(shortDuration(174), "2m54s")
        XCTAssertEqual(shortDuration(245), "4m05s")
        XCTAssertEqual(shortDuration(3900), "1h05m")
        XCTAssertEqual(agoText(30, english: false), "刚刚")
        XCTAssertEqual(agoText(200, english: false), "3分钟前")
        XCTAssertEqual(agoText(7300, english: false), "2小时前")
        XCTAssertEqual(agoText(90_000, english: false), "1天前")
        XCTAssertEqual(agoText(200, english: true), "3m ago")
    }

    func testResumableSessionNamesItsMultiplexerAndMoshWhileMoshCarriesIt() {
        XCTAssertEqual(sessionTransportTags(mode: .tmux, mosh: true), ["tmux", "mosh"])
        XCTAssertEqual(sessionTransportTags(mode: .tmux, mosh: false), ["tmux"])
        XCTAssertEqual(sessionTransportTags(mode: .shell, mosh: false), [])
        XCTAssertEqual(sessionTransportTags(mode: .shell, mosh: true), ["mosh"])
    }

    func testTmuxCommandsAreSingleQuotedForSh() {
        let status = RemoteCommands.agentStatus("roamtty-abc;rm")
        XCTAssertTrue(status.hasPrefix("/bin/sh -c '"))
        XCTAssertTrue(status.contains("-t roamtty-abcrm "))
        XCTAssertTrue(status.contains("#{@roamtty_reply}"))
        // sshd on macOS runs commands without a UTF-8 locale: tmux would print each non-ASCII character as "_".
        XCTAssertTrue(status.contains("tmux -u display-message -p -t roamtty-abcrm \"#{pane_current_command}"))
        XCTAssertTrue(status.contains("tmux -u display-message -p -t roamtty-abcrm \"#{pane_current_path}"))
        XCTAssertTrue(RemoteCommands.restartPane("x").contains("respawn-pane -k ${d:+-c \"$d\"} -t x"))
        XCTAssertNil(RemoteCommands.writeHostFile("../evil"))
        XCTAssertNil(RemoteCommands.writeHostFile(".hidden"))
        XCTAssertEqual(RemoteCommands.writeHostFile("codex", executable: true),
                       "/bin/sh -c 'mkdir -p \"$HOME/.roamtty\" && cat > \"$HOME/.roamtty/codex\" && chmod +x \"$HOME/.roamtty/codex\"'")
    }

    // MARK: The hook script against a stand-in tmux
}
