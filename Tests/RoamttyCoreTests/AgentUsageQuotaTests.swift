import Foundation
import XCTest
@testable import RoamttyCore

final class AgentUsageQuotaTests: XCTestCase {
    func testAgyStatusLineAvoidsDoubleRoundingAndNeverInvokesAgyOrTmux() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("roamtty-agy-ro-precision-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let binDir = home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let agyMarker = home.appendingPathComponent("agy-invoked.log")
        let tmuxMarker = home.appendingPathComponent("tmux-used.log")
        try writeGuardBinaries(binDir: binDir, agyMarker: agyMarker, tmuxMarker: tmuxMarker)

        let hookFile = home.appendingPathComponent("agent-hook.sh")
        try AgentHooks.script.write(to: hookFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookFile.path)

        let agyDir = home.appendingPathComponent(".gemini/antigravity-cli/brain/conv-ro/.system_generated/logs")
        try fm.createDirectory(at: agyDir, withIntermediateDirectories: true)
        try #"{"type":"PLANNER_RESPONSE","created_at":"2099-01-01T00:00:01Z","model":"gemini-4-neon-xhigh","input_tokens":5000,"output_tokens":500,"cache_read_tokens":20000}"#
            .appending("\n").write(to: agyDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        // Works even without ROAMTTY_AGENT (e.g. user-configured /statusline).
        try runStatusLine(
            hook: hookFile, home: home, convId: "conv-ro", f5h: 0.9454, f7d: 0.7648,
            r5h: "2099-01-01T05:00:00Z", r7d: "2099-01-07T00:00:00Z", sec: 5000, setRoamttyEnv: false
        )

        let out = try runSessionCommand(home: home, pathPrefix: binDir.path)
        let parsed = try XCTUnwrap(AgentUsage.parseSession(out))
        XCTAssertEqual(parsed.quota5h?.remainingRounded, 95)
        // 0.7648 -> 76.48% must round to 76%, not double-round 76.48 -> 76.5 -> 77%.
        XCTAssertEqual(parsed.quota7d?.remainingRounded, 76)
        XCTAssertFalse(fm.fileExists(atPath: agyMarker.path))
        XCTAssertFalse(fm.fileExists(atPath: tmuxMarker.path))
    }

    func testAgyStatusLineIdleRedrawAndOlderWindowDoNotClobberFresherQuotaCache() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("roamtty-agy-sl-stale-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let hookFile = home.appendingPathComponent("agent-hook.sh")
        try AgentHooks.script.write(to: hookFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookFile.path)

        let agyDir = home.appendingPathComponent(".gemini/antigravity-cli/brain/conv-guard/.system_generated/logs")
        try fm.createDirectory(at: agyDir, withIntermediateDirectories: true)
        try #"{"type":"PLANNER_RESPONSE","created_at":"2099-01-01T00:00:01Z","model":"gemini-4-neon-xhigh","input_tokens":1000,"output_tokens":200,"cache_read_tokens":5000}"#
            .appending("\n").write(to: agyDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        let r5h = "2099-01-01T05:00:00Z", r7d = "2099-01-07T00:00:00Z"
        try runStatusLine(hook: hookFile, home: home, convId: "sess-A", f5h: 0.978, f7d: 0.777, r5h: r5h, r7d: r7d, sec: 15600)
        XCTAssertEqual(try readCachedAgy(home: home).quota7d?.remainingRounded, 78)

        // Session B writes fresher quota (94% / 76%).
        try runStatusLine(hook: hookFile, home: home, convId: "sess-B", f5h: 0.942, f7d: 0.761, r5h: r5h, r7d: r7d, sec: 15000)
        XCTAssertEqual(try readCachedAgy(home: home).quota7d?.remainingRounded, 76)

        // Idle redraw from Session A and unseen stale Session C must not regress 94% / 76%.
        try runStatusLine(hook: hookFile, home: home, convId: "sess-A", f5h: 0.978, f7d: 0.777, r5h: r5h, r7d: r7d, sec: 14200)
        try runStatusLine(hook: hookFile, home: home, convId: "sess-C", f5h: 0.970, f7d: 0.776, r5h: r5h, r7d: r7d, sec: 14100)
        let kept = try readCachedAgy(home: home)
        XCTAssertEqual(kept.quota5h?.remainingRounded, 94)
        XCTAssertEqual(kept.quota7d?.remainingRounded, 76)

        // Real refresh on Session A updates cache; rollover to a newer 5h reset window updates cache.
        try runStatusLine(hook: hookFile, home: home, convId: "sess-A", f5h: 0.912, f7d: 0.748, r5h: r5h, r7d: r7d, sec: 13900)
        XCTAssertEqual(try readCachedAgy(home: home).quota7d?.remainingRounded, 75)
        try runStatusLine(hook: hookFile, home: home, convId: "sess-D", f5h: 1.0, f7d: 0.748, r5h: "2099-01-01T10:00:00Z", r7d: r7d, sec: 18000)
        XCTAssertEqual(try readCachedAgy(home: home).quota5h?.remainingRounded, 100)

        // Unseen idle Session E holding the older 05:00 window (40%) must NOT clobber rolled-over 10:00 window.
        try runStatusLine(hook: hookFile, home: home, convId: "sess-E", f5h: 0.40, f7d: 0.748, r5h: r5h, r7d: r7d, sec: 100)
        XCTAssertEqual(try readCachedAgy(home: home).quota5h?.remainingRounded, 100)
        XCTAssertEqual(try readCachedAgy(home: home).quota7d?.remainingRounded, 75)
    }

    private func writeGuardBinaries(binDir: URL, agyMarker: URL, tmuxMarker: URL) throws {
        let fm = FileManager.default
        let agyURL = binDir.appendingPathComponent("agy")
        try "#!/bin/sh\necho \"$@\" >> \"\(agyMarker.path)\"\nexit 0\n".write(to: agyURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agyURL.path)

        let tmuxURL = binDir.appendingPathComponent("tmux")
        try "#!/bin/sh\necho \"$@\" >> \"\(tmuxMarker.path)\"\nexit 0\n".write(to: tmuxURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmuxURL.path)
    }

    private func runSessionCommand(home: URL, pathPrefix: String?) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", AgentUsage.sessionCommand(agent: .agy, tmuxSession: nil, directory: "/work/app")]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        if let pathPrefix { env["PATH"] = "\(pathPrefix):\(env["PATH"] ?? "/usr/bin:/bin")" }
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

    private func readCachedAgy(home: URL) throws -> AgentSessionUsage {
        try XCTUnwrap(AgentUsage.parseSession(try runSessionCommand(home: home, pathPrefix: nil)))
    }

    private func runStatusLine(
        hook: URL, home: URL, convId: String, f5h: Double, f7d: Double,
        r5h: String, r7d: String, sec: Int, setRoamttyEnv: Bool = true
    ) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [hook.path, "agy", "statusline"]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        if setRoamttyEnv { env["ROAMTTY_AGENT"] = "agy" } else { env.removeValue(forKey: "ROAMTTY_AGENT") }
        proc.environment = env
        let pipe = Pipe()
        proc.standardInput = pipe
        try proc.run()
        let payload = #"{"conversation_id":"\#(convId)","model":{"id":"Gemini 4 Neon (XHigh)"},"quota":{"#
            + #""gemini-5h":{"remaining_fraction":\#(f5h),"reset_time":"\#(r5h)","reset_in_seconds":\#(sec)},"#
            + #""gemini-weekly":{"remaining_fraction":\#(f7d),"reset_time":"\#(r7d)","reset_in_seconds":500000}}}"#
        pipe.fileHandleForWriting.write(Data(payload.utf8))
        try pipe.fileHandleForWriting.close()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
    }
}
