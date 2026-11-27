import XCTest
@testable import RoamttyCore

final class AgentUsageTests: XCTestCase {
    func testParsesSessionUsageWithQuotasAndContext() {
        let raw = """
        agent=codex
        model=gpt-5.4
        effort=xhigh
        ctx_used=164000
        ctx_limit=200000
        ctx_cache_read=104000
        ctx_cache_create=24000
        ctx_turn=36000
        sess_input=78000
        sess_output=44000
        sess_cache_read=1060000
        sess_cache_create=0
        q5h_rem=38.0
        q5h_reset=1795608000
        q7d_rem=59.2
        q7d_reset=1795900000
        """
        let u = AgentUsage.parseSession(raw)
        XCTAssertEqual(u?.agent, .codex)
        XCTAssertEqual(u?.formattedModel, "gpt-5.4")
        XCTAssertEqual(u?.reasoningEffort, .xhigh)
        XCTAssertEqual(u?.reasoningEffort?.bars, 4)
        XCTAssertEqual(u?.contextPercent, 82)
        XCTAssertEqual(u?.contextRemaining, 36_000)
        XCTAssertEqual(u?.sessionTotalTokens, 1_182_000)
        XCTAssertEqual(u?.cacheHitPercent, 93)
        XCTAssertEqual(u?.quota5h?.remainingRounded, 38)
        XCTAssertEqual(u?.quota5h?.usedRounded, 62)
        XCTAssertEqual(u?.quota7d?.remainingRounded, 59)
        XCTAssertEqual(u?.quota7d?.usedRounded, 41)
    }

    func testDegradesGracefullyWithoutQuotasOrContext() {
        let raw = """
        agent=grok
        model=grok-4.7
        sess_input=120000
        sess_output=8000
        sess_cache_read=252000
        sess_cache_create=0
        """
        let u = AgentUsage.parseSession(raw)
        XCTAssertEqual(u?.agent, .grok)
        XCTAssertNil(u?.contextPercent)
        XCTAssertNil(u?.quota5h)
        XCTAssertNil(u?.quota7d)
        XCTAssertEqual(u?.sessionTotalTokens, 380_000)
        XCTAssertEqual(CodingAgent.grok.compactCommand, "/compact")
        XCTAssertEqual(CodingAgent.claude.compactCommand, "/compact")
        XCTAssertEqual(CodingAgent.codex.compactCommand, "/compact")
        XCTAssertEqual(CodingAgent.agy.compactCommand, "/compact")
    }

    func testParsesHostMultiAgentUsageSortedByTotalTokens() {
        let output = """
        range=7d
        agent=grok|1|120000|10000|250000|0||||
        agent=claude|3|200000|100000|3160000|0||||
        agent=codex|2|100000|50000|1650000|0|66.0|1795608000|81.0|1795900000
        """
        let host = AgentUsage.parseHost(output, requestedRange: .today)
        XCTAssertEqual(host.range, .week)
        XCTAssertEqual(host.agents.map(\.agent), [.claude, .codex, .grok])
        XCTAssertEqual(host.totalTokens, 5_640_000)
        XCTAssertEqual(host.cacheHitPercent, 92)
        XCTAssertEqual(host.agents[1].quota5h?.remainingRounded, 66)
        XCTAssertEqual(host.agents[1].quota7d?.remainingRounded, 81)
        XCTAssertNil(host.agents[2].quota5h)
    }

    func testFormatsTokensModelsAndResets() {
        XCTAssertEqual(AgentUsage.formatTokens(840), "840")
        XCTAssertEqual(AgentUsage.formatTokens(4_200), "4.2k")
        XCTAssertEqual(AgentUsage.formatTokens(164_000), "164k")
        XCTAssertEqual(AgentUsage.formatTokens(1_180_000), "1.18M")
        XCTAssertEqual(AgentUsage.formatTokens(1_540_000_000), "1.54B")
        XCTAssertEqual(AgentUsage.formatModelName("claude-opus-4-6-20260301"), "Opus 4.6")
        XCTAssertEqual(AgentUsage.formatModelName("claude-fable-5-2"), "Fable 5.2")
        XCTAssertEqual(AgentUsage.formatModelName("gemini-4-neon-xhigh"), "Gemini 4 Neon")
        XCTAssertEqual(ReasoningEffort.fromRaw("med"), .medium)
        XCTAssertEqual(ReasoningEffort.medium.bars, 2)
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(AgentUsage.formatQuotaReset(18_040, now: now, english: false), "2h 14m 后重置")
        XCTAssertEqual(AgentUsage.formatQuotaReset(18_040, now: now, english: true), "Resets in 2h 14m")
        XCTAssertEqual(AgentUsage.formatQuotaReset(18_040, now: now, compact: true), "2h14m")
    }

    func testCollectorDropsContextUsageImmediatelyAfterCompactionAcrossAgents() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("roamtty-usage-compact-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        func runSession(_ agent: CodingAgent, cwd: String) throws -> AgentSessionUsage {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", AgentUsage.sessionCommand(agent: agent, tmuxSession: nil, directory: cwd)]
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = home.path
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
            return try XCTUnwrap(AgentUsage.parseSession(out))
        }

        // 1. Antigravity: CHECKPOINT drops 43% -> 2% before next PLANNER_RESPONSE.
        let agyDir = home.appendingPathComponent(".gemini/antigravity-cli/brain/conv-compact/.system_generated/logs")
        try fm.createDirectory(at: agyDir, withIntermediateDirectories: true)
        let agyFile = agyDir.appendingPathComponent("transcript.jsonl")
        let agyInitial = """
        {"type":"PLANNER_RESPONSE","created_at":"2099-01-01T00:00:01Z","model":"gemini-4-neon-xhigh","input_tokens":12180,"output_tokens":300,"cache_read_tokens":0}
        {"type":"PLANNER_RESPONSE","created_at":"2099-01-01T00:10:00Z","model":"gemini-4-neon-xhigh","input_tokens":2519,"output_tokens":1597,"cache_read_tokens":426997}
        {"type":"CHECKPOINT","created_at":"2099-01-01T00:15:00Z","input_tokens":2506,"output_tokens":5080,"cache_read_tokens":429517,"content":"# Resuming from a compaction"}

        """
        try agyInitial.write(to: agyFile, atomically: true, encoding: .utf8)
        let agyPost = try runSession(.agy, cwd: "/work/app")
        XCTAssertEqual(agyPost.contextUsed, 17_260)
        XCTAssertEqual(agyPost.contextLimit, 1_000_000)
        XCTAssertEqual(agyPost.contextPercent, 2)
        XCTAssertEqual(agyPost.contextCacheRead, 0)
        XCTAssertEqual(agyPost.contextTurn, 0)

        // 2. Claude Code: compact_boundary drops context immediately to postTokens and keeps 1M window.
        let claudeDir = home.appendingPathComponent(".claude/projects/-work-app")
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let claudeLines = [
            #"{"type":"assistant","effort":"high","cwd":"/work/app","timestamp":"2099-01-01T00:00:01Z","message":{"id":"m1","model":"claude-opus-4-6","#
                + #""usage":{"input_tokens":5000,"output_tokens":400,"cache_read_input_tokens":781844,"cache_creation_input_tokens":0}}}"#,
            #"{"type":"system","subtype":"compact_boundary","cwd":"/work/app","timestamp":"2099-01-01T00:05:00Z","#
                + #""compactMetadata":{"trigger":"manual","preTokens":786844,"postTokens":15880,"cumulativeDroppedTokens":770964}}"#
        ]
        try (claudeLines.joined(separator: "\n") + "\n")
            .write(to: claudeDir.appendingPathComponent("s-compact.jsonl"), atomically: true, encoding: .utf8)
        let claudePost = try runSession(.claude, cwd: "/work/app")
        XCTAssertEqual(claudePost.contextUsed, 15_880)
        XCTAssertEqual(claudePost.contextLimit, 1_000_000)
        XCTAssertEqual(claudePost.contextPercent, 2)

        // 3. Codex: post-compaction token_count has input_tokens=0 and retained context in total_tokens.
        let codexDir = home.appendingPathComponent(".codex/sessions/2026/11/25")
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let codexLines = [
            #"{"timestamp":"2099-01-01T00:00:00Z","type":"session_meta","payload":{"cwd":"/work/app"}}"#,
            #"{"timestamp":"2099-01-01T00:00:01Z","type":"turn_context","payload":{"model":"gpt-5.4","effort":"high","cwd":"/work/app"}}"#,
            #"{"timestamp":"2099-01-01T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":"#
                + #"{"input_tokens":243047,"cached_input_tokens":242944,"output_tokens":6845},"last_token_usage":"#
                + #"{"input_tokens":243047,"cached_input_tokens":242944,"output_tokens":6845,"total_tokens":249892},"model_context_window":258400}}}"#,
            #"{"timestamp":"2099-01-01T00:02:00Z","type":"compacted","payload":{"message":""}}"#,
            #"{"timestamp":"2099-01-01T00:02:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":"#
                + #"{"input_tokens":243047,"cached_input_tokens":242944,"output_tokens":6845},"last_token_usage":"#
                + #"{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"total_tokens":37754},"model_context_window":258400}}}"#
        ]
        try (codexLines.joined(separator: "\n") + "\n")
            .write(to: codexDir.appendingPathComponent("rollout-compact.jsonl"), atomically: true, encoding: .utf8)
        let codexPost = try runSession(.codex, cwd: "/work/app")
        XCTAssertEqual(codexPost.contextUsed, 37_754)
        XCTAssertEqual(codexPost.contextLimit, 258_400)
        XCTAssertEqual(codexPost.contextPercent, 15)
    }

    func testCollectorReadsGrokContextOnMultiCallTurns() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("roamtty-usage-grok-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let grokDir = home.appendingPathComponent(".grok/sessions/%2Fwork%2Fgrok/sess-multi")
        try fm.createDirectory(at: grokDir, withIntermediateDirectories: true)
        try #"{"current_model_id":"grok-4.7","reasoning_effort":"xhigh","context_window":500000}"#
            .write(to: grokDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        try #"{"contextTokensUsed":193909,"contextWindowTokens":500000,"contextWindowUsage":38}"#
            .write(to: grokDir.appendingPathComponent("signals.json"), atomically: true, encoding: .utf8)
        let updates = [
            #"{"timestamp":4070908800,"method":"session/update","params":{"_meta":{"totalTokens":193909},"update":{"sessionUpdate":"agent_message_chunk"}}}"#,
            #"{"timestamp":4070908801,"method":"_x.ai/session/update","params":{"update":{"sessionUpdate":"turn_completed","#
                + #""usage":{"inputTokens":1911236,"cachedReadTokens":1897344,"cacheCreationTokens":0,"outputTokens":6724,"modelCalls":10}}}}"#
        ]
        try (updates.joined(separator: "\n") + "\n")
            .write(to: grokDir.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", AgentUsage.sessionCommand(agent: .grok, tmuxSession: nil, directory: "/work/grok")]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
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
        let usage = try XCTUnwrap(AgentUsage.parseSession(out))
        XCTAssertEqual(usage.formattedModel, "grok-4.7")
        XCTAssertEqual(usage.reasoningEffort, .xhigh)
        XCTAssertEqual(usage.contextUsed, 193_909)
        XCTAssertEqual(usage.contextLimit, 500_000)
        XCTAssertEqual(usage.contextPercent, 39)
        XCTAssertEqual(usage.contextCacheRead, 0)
        XCTAssertEqual(usage.contextTurn, 0)
    }

    func testAgyQuotaNeverPollsAutomaticallyAndFetchesOnlyWhenRequested() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("roamtty-agy-manual-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let binDir = home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let marker = home.appendingPathComponent("agy-invoked.log")
        let fakeAgy = binDir.appendingPathComponent("agy")
        let quotaJSON = #"{"command":{"data":{"groups":[{"name":"Gemini Models","buckets":"#
            + #"[{"window":"5h","remaining_fraction":0.64,"reset_time":"2099-01-01T05:00:00Z"},"#
            + #"{"window":"weekly","remaining_fraction":0.52,"reset_time":"2099-01-07T00:00:00Z"}]}]}}}"#
        let scriptBody = """
        #!/bin/sh
        echo "$@" >> "\(marker.path)"
        printf '%s\\n' '\(quotaJSON)'
        """
        try scriptBody.write(to: fakeAgy, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeAgy.path)

        let agyDir = home.appendingPathComponent(".gemini/antigravity-cli/brain/conv-manual/.system_generated/logs")
        try fm.createDirectory(at: agyDir, withIntermediateDirectories: true)
        try #"{"type":"PLANNER_RESPONSE","created_at":"2099-01-01T00:00:01Z","model":"gemini-4-neon-xhigh","input_tokens":5000,"output_tokens":500,"cache_read_tokens":20000}"#
            .appending("\n")
            .write(to: agyDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        func run(_ cmd: String) throws -> String {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", cmd]
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = home.path
            env["PATH"] = "\(binDir.path):\(env["PATH"] ?? "/usr/bin:/bin")"
            env.removeValue(forKey: "ROAMTTY_NO_LIVE_QUOTA")
            proc.environment = env
            let stdinPipe = Pipe(), stdoutPipe = Pipe()
            proc.standardInput = stdinPipe
            proc.standardOutput = stdoutPipe
            try proc.run()
            stdinPipe.fileHandleForWriting.write(AgentUsage.scriptData)
            try stdinPipe.fileHandleForWriting.close()
            proc.waitUntilExit()
            XCTAssertEqual(proc.terminationStatus, 0)
            return String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }

        // 1. Default reads never invoke `agy -p /quota`.
        let autoSess = try XCTUnwrap(AgentUsage.parseSession(try run(AgentUsage.sessionCommand(agent: .agy, tmuxSession: nil, directory: "/work/app"))))
        XCTAssertNil(autoSess.quota5h)
        XCTAssertNil(autoSess.quota7d)
        XCTAssertFalse(fm.fileExists(atPath: marker.path))

        let autoHost = AgentUsage.parseHost(try run(AgentUsage.hostCommand(range: .today)), requestedRange: .today)
        XCTAssertEqual(autoHost.agents.count, 1)
        XCTAssertNil(autoHost.agents[0].quota5h)
        XCTAssertFalse(fm.fileExists(atPath: marker.path))

        // 2. Manual tap passes fetchAgyQuota: true -> invokes `agy -p /quota` once and caches result.
        let manualSess = try XCTUnwrap(AgentUsage.parseSession(
            try run(AgentUsage.sessionCommand(agent: .agy, tmuxSession: nil, directory: "/work/app", fetchAgyQuota: true))
        ))
        XCTAssertEqual(manualSess.quota5h?.remainingRounded, 64)
        XCTAssertEqual(manualSess.quota7d?.remainingRounded, 52)
        let linesAfterManual = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(linesAfterManual.count, 1)

        // 3. Subsequent default host read serves the cached snapshot without invoking `agy` again.
        let cachedHost = AgentUsage.parseHost(try run(AgentUsage.hostCommand(range: .today)), requestedRange: .today)
        XCTAssertEqual(cachedHost.agents[0].quota5h?.remainingRounded, 64)
        XCTAssertEqual(cachedHost.agents[0].quota7d?.remainingRounded, 52)
        let linesAfterCache = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(linesAfterCache.count, 1)
    }
}

extension AgentUsageTests {
    func testAgyStatusLineCachesQuotaAndCodexUsesNewestAccountQuota() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("roamtty-quota-fresh-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let nowSec = Int(Date().timeIntervalSince1970)
        let futureReset = nowSec + 7200

        // 1. agy statusLine hook writes ~/.roamtty/quota-agy.json atomically and keeps 1970-01-01 100% buckets.
        let hookFile = home.appendingPathComponent("agent-hook.sh")
        try AgentHooks.script.write(to: hookFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookFile.path)

        let sl = Process()
        sl.executableURL = URL(fileURLWithPath: "/bin/sh")
        sl.arguments = [hookFile.path, "agy", "statusline"]
        var slEnv = ProcessInfo.processInfo.environment
        slEnv["HOME"] = home.path
        slEnv["ROAMTTY_AGENT"] = "agy"
        sl.environment = slEnv
        let slIn = Pipe()
        sl.standardInput = slIn
        try sl.run()
        let slPayload = #"{"model":{"id":"Gemini 4 Neon (XHigh)"},"quota":{"#
            + #""gemini-5h":{"remaining_fraction":0.835,"reset_time":"2099-01-01T05:00:00Z","reset_in_seconds":5214},"#
            + #""gemini-weekly":{"remaining_fraction":0.798,"reset_time":"2099-01-07T00:00:00Z","reset_in_seconds":574014},"#
            + #""3p-5h":{"remaining_fraction":1.0,"reset_time":"1970-01-01T00:00:00Z","reset_in_seconds":0},"#
            + #""3p-weekly":{"remaining_fraction":1.0,"reset_time":"1970-01-01T00:00:00Z","reset_in_seconds":0}}}"#
        slIn.fileHandleForWriting.write(Data(slPayload.utf8))
        try slIn.fileHandleForWriting.close()
        sl.waitUntilExit()
        XCTAssertEqual(sl.terminationStatus, 0)

        let agyDir = home.appendingPathComponent(".gemini/antigravity-cli/brain/conv-sl/.system_generated/logs")
        try fm.createDirectory(at: agyDir, withIntermediateDirectories: true)
        let transcript = agyDir.appendingPathComponent("transcript.jsonl")

        func runSession(_ agent: CodingAgent, cwd: String) throws -> AgentSessionUsage {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", AgentUsage.sessionCommand(agent: agent, tmuxSession: nil, directory: cwd)]
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = home.path
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
            return try XCTUnwrap(AgentUsage.parseSession(out))
        }

        let claudeLine = #"{"type":"PLANNER_RESPONSE","created_at":"2099-01-01T00:00:01Z","model":"claude-opus-4-6","#
            + #""input_tokens":1000,"output_tokens":200,"cache_read_tokens":5000}"# + "\n"
        try claudeLine.write(to: transcript, atomically: true, encoding: .utf8)
        let claude3p = try runSession(.agy, cwd: "/work/app")
        XCTAssertEqual(claude3p.quota5h?.remainingRounded, 100)
        XCTAssertNil(claude3p.quota5h?.resetsAtEpochSeconds)
        XCTAssertEqual(claude3p.quota7d?.remainingRounded, 100)

        let geminiLine = #"{"type":"PLANNER_RESPONSE","created_at":"2099-01-01T00:00:01Z","model":"gemini-4-neon-xhigh","#
            + #""input_tokens":1000,"output_tokens":200,"cache_read_tokens":5000}"# + "\n"
        try geminiLine.write(to: transcript, atomically: true, encoding: .utf8)
        let geminiSess = try runSession(.agy, cwd: "/work/app")
        XCTAssertEqual(geminiSess.quota5h?.remainingRounded, 84)
        XCTAssertEqual(geminiSess.quota7d?.remainingRounded, 80)

        // 2. Codex older session refreshes with the newer rollout's account-wide quota.
        let codexDir = home.appendingPathComponent(".codex/sessions/2026/11/26")
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let oldTokenEvent = #"{"timestamp":"2099-01-01T00:01:00Z","type":"event_msg","payload":{"type":"token_count","#
            + #""info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":100},"#
            + #""last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":100},"model_context_window":200000},"#
            + #""rate_limits":{"limit_id":"codex","primary":{"used_percent":10.0,"window_minutes":300,"resets_at":\#(futureReset)},"#
            + #""secondary":{"used_percent":5.0,"window_minutes":10080,"resets_at":\#(futureReset + 100000)}}}}"#
        let oldRollout = [#"{"timestamp":"2099-01-01T00:00:00Z","type":"session_meta","payload":{"cwd":"/work/old"}}"#, oldTokenEvent]
            .joined(separator: "\n") + "\n"
        try oldRollout.write(to: codexDir.appendingPathComponent("rollout-old.jsonl"), atomically: true, encoding: .utf8)
        let newTokenEvent = #"{"timestamp":"2099-01-01T01:05:00Z","type":"event_msg","payload":{"type":"token_count","#
            + #""info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":0,"output_tokens":200},"#
            + #""last_token_usage":{"input_tokens":2000,"cached_input_tokens":0,"output_tokens":200},"model_context_window":200000},"#
            + #""rate_limits":{"limit_id":"codex","primary":{"used_percent":55.0,"window_minutes":300,"resets_at":\#(futureReset)},"#
            + #""secondary":{"used_percent":40.0,"window_minutes":10080,"resets_at":\#(futureReset + 100000)}}}}"#
        let newRollout = [#"{"timestamp":"2099-01-01T01:00:00Z","type":"session_meta","payload":{"cwd":"/work/new"}}"#, newTokenEvent]
            .joined(separator: "\n") + "\n"
        try newRollout.write(to: codexDir.appendingPathComponent("rollout-new.jsonl"), atomically: true, encoding: .utf8)

        let oldCodex = try runSession(.codex, cwd: "/work/old")
        XCTAssertEqual(oldCodex.quota5h?.remainingRounded, 45)
        XCTAssertEqual(oldCodex.quota7d?.remainingRounded, 60)
    }
}
