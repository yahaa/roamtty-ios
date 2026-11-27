import Foundation
import XCTest
@testable import RoamttyCore

final class AgentUsageQuotaTests: XCTestCase {
    func testAgyLiveFetchFallsBackToTmuxOnSshOAuthAndAvoidsDoubleRounding() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("roamtty-agy-tmux-fb-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let binDir = home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let tmuxMarker = home.appendingPathComponent("tmux-used.log")
        try writeFakeQuotaBinaries(binDir: binDir, tmuxMarker: tmuxMarker)

        let agyDir = home.appendingPathComponent(".gemini/antigravity-cli/brain/conv-ssh/.system_generated/logs")
        try fm.createDirectory(at: agyDir, withIntermediateDirectories: true)
        try #"{"type":"PLANNER_RESPONSE","created_at":"2099-01-01T00:00:01Z","model":"gemini-4-neon-xhigh","input_tokens":5000,"output_tokens":500,"cache_read_tokens":20000}"#
            .appending("\n").write(to: agyDir.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)

        let cacheDir = home.appendingPathComponent(".roamtty")
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let stale = #"{"_fetched_at":1,"quota":{"gemini-5h":{"remaining_fraction":0.98,"reset_time":"2099-01-01T05:00:00Z"},"#
            + #""gemini-weekly":{"remaining_fraction":0.78,"reset_time":"2099-01-07T00:00:00Z"}}}"#
        try stale.write(to: cacheDir.appendingPathComponent("quota-agy.json"), atomically: true, encoding: .utf8)

        let started = Date()
        let out = try runSessionCommand(home: home, pathPrefix: binDir.path, fetchAgyQuota: true)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 8.0, "OAuth abort + tmux fallback must not wait for sleep 10")
        XCTAssertTrue(fm.fileExists(atPath: tmuxMarker.path))

        let parsed = try XCTUnwrap(AgentUsage.parseSession(out))
        XCTAssertEqual(parsed.quota5h?.remainingRounded, 95)
        // 0.7648 -> 76.48% must round to 76%, not double-round 76.48 -> 76.5 -> 77%.
        XCTAssertEqual(parsed.quota7d?.remainingRounded, 76)
    }

    func testAgyStatusLineIdleRedrawDoesNotClobberFresherQuotaCache() throws {
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
    }

    private func writeFakeQuotaBinaries(binDir: URL, tmuxMarker: URL) throws {
        let fm = FileManager.default
        let payload = #"{"command":{"data":{"groups":[{"name":"Gemini Models","buckets":"#
            + #"[{"id":"gemini-5h","window":"5h","remaining_fraction":0.9454,"reset_time":"2099-01-01T05:00:00Z"},"#
            + #"{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.7648,"reset_time":"2099-01-07T00:00:00Z"}]}]}}}"#
        let fakeAgy = """
        #!/bin/sh
        if [ "${FAKE_TMUX_AQUA:-0}" != "1" ]; then
          echo "Authentication required. Please visit the URL to log in:" >&2
          echo "  https://accounts.google.com/o/oauth2/auth?client_id=test" >&2
          sleep 10
          exit 1
        fi
        printf '%s\\n' '\(payload)'
        """
        let agyURL = binDir.appendingPathComponent("agy")
        try fakeAgy.write(to: agyURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agyURL.path)

        let fakeTmux = """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "run-shell" ]; then
            shift
            echo "run-shell" >> "\(tmuxMarker.path)"
            FAKE_TMUX_AQUA=1 /bin/sh -c "$1"
            exit $?
          fi
          shift
        done
        exit 1
        """
        let tmuxURL = binDir.appendingPathComponent("tmux")
        try fakeTmux.write(to: tmuxURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmuxURL.path)
    }

    private func runSessionCommand(home: URL, pathPrefix: String?, fetchAgyQuota: Bool) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", AgentUsage.sessionCommand(agent: .agy, tmuxSession: nil, directory: "/work/app", fetchAgyQuota: fetchAgyQuota)]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        if let pathPrefix {
            env["PATH"] = "\(pathPrefix):\(env["PATH"] ?? "/usr/bin:/bin")"
            env.removeValue(forKey: "ROAMTTY_NO_LIVE_QUOTA")
        } else {
            env["ROAMTTY_NO_LIVE_QUOTA"] = "1"
        }
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
        try XCTUnwrap(AgentUsage.parseSession(try runSessionCommand(home: home, pathPrefix: nil, fetchAgyQuota: false)))
    }

    private func runStatusLine(hook: URL, home: URL, convId: String, f5h: Double, f7d: Double, r5h: String, r7d: String, sec: Int) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [hook.path, "agy", "statusline"]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["ROAMTTY_AGENT"] = "agy"
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
