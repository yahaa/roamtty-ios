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

    func testBrandNewHookedAgySessionDoesNotBorrowOtherSessionContextInSameDirectory() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("roamtty-agy-fresh-ctx-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let binDir = home.appendingPathComponent(".local/bin")
        let store = home.appendingPathComponent("tmux-store")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        try writeFakeTmux(binDir: binDir, store: store)

        let oldLogDir = home.appendingPathComponent(".gemini/antigravity-cli/brain/conv-old/.system_generated/logs")
        try fm.createDirectory(at: oldLogDir, withIntermediateDirectories: true)
        let oldTranscript = oldLogDir.appendingPathComponent("transcript.jsonl")
        try #"{"type":"PLANNER_RESPONSE","created_at":"2099-01-01T00:00:01Z","model":"gemini-4-neon-xhigh","input_tokens":10000,"output_tokens":500,"cache_read_tokens":450000}"#
            .appending("\n").write(to: oldTranscript, atomically: true, encoding: .utf8)

        let cacheDir = home.appendingPathComponent(".gemini/antigravity-cli/cache")
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try #"{"/work/roamtty":"conv-old"}"#.write(to: cacheDir.appendingPathComponent("last_conversations.json"), atomically: true, encoding: .utf8)
        try #"{"model":"Gemini 4 Neon (XHigh)"}"#.write(
            to: home.appendingPathComponent(".gemini/antigravity-cli/settings.json"), atomically: true, encoding: .utf8
        )
        let nowSec = Int(Date().timeIntervalSince1970)
        let roamDir = home.appendingPathComponent(".roamtty")
        try fm.createDirectory(at: roamDir, withIntermediateDirectories: true)
        let qJson = #"{"_fetched_at":\#(nowSec),"quota":{"gemini-5h":{"remaining_fraction":0.90,"reset_time":"2099-01-01T05:00:00Z"},"#
            + #""gemini-weekly":{"remaining_fraction":0.70,"reset_time":"2099-01-07T00:00:00Z"}}}"#
        try qJson.write(to: roamDir.appendingPathComponent("quota-agy.json"), atomically: true, encoding: .utf8)

        try "idle|\(nowSec)|agy||".write(to: store.appendingPathComponent("sess-new_@roamtty_agent"), atomically: true, encoding: .utf8)
        try "idle|\(nowSec)|agy||".write(to: store.appendingPathComponent("sess-old_@roamtty_agent"), atomically: true, encoding: .utf8)
        try "conv-old".write(to: store.appendingPathComponent("sess-old_@roamtty_session"), atomically: true, encoding: .utf8)

        let oldUsage = try XCTUnwrap(AgentUsage.parseSession(
            try runSessionCommand(home: home, pathPrefix: binDir.path, tmuxSession: "sess-old", directory: "/work/roamtty")
        ))
        XCTAssertEqual(oldUsage.contextPercent, 46)

        // Brand-new hooked pane in same cwd must NOT borrow conv-old's 46% context, while keeping model & quotas.
        let newUsage = try XCTUnwrap(AgentUsage.parseSession(
            try runSessionCommand(home: home, pathPrefix: binDir.path, tmuxSession: "sess-new", directory: "/work/roamtty")
        ))
        XCTAssertNil(newUsage.contextPercent)
        XCTAssertNil(newUsage.contextUsed)
        XCTAssertEqual(newUsage.sessionTotalTokens, 0)
        XCTAssertEqual(newUsage.formattedModel, "Gemini 4 Neon")
        XCTAssertEqual(newUsage.reasoningEffort, .xhigh)
        XCTAssertEqual(newUsage.quota5h?.remainingRounded, 90)
        XCTAssertEqual(newUsage.quota7d?.remainingRounded, 70)

        // statusLine binds /resume conversation_id and clears it on /clear (empty conversation_id).
        let hookFile = home.appendingPathComponent("agent-hook.sh")
        try AgentHooks.script.write(to: hookFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookFile.path)

        try runStatusLineInPane(hook: hookFile, home: home, pathPrefix: binDir.path, pane: "sess-new", convId: "conv-old", tpath: oldTranscript.path)
        let resumed = try XCTUnwrap(AgentUsage.parseSession(
            try runSessionCommand(home: home, pathPrefix: binDir.path, tmuxSession: "sess-new", directory: "/work/roamtty")
        ))
        XCTAssertEqual(resumed.contextPercent, 46)

        try runStatusLineInPane(hook: hookFile, home: home, pathPrefix: binDir.path, pane: "sess-new", convId: "", tpath: "")
        let cleared = try XCTUnwrap(AgentUsage.parseSession(
            try runSessionCommand(home: home, pathPrefix: binDir.path, tmuxSession: "sess-new", directory: "/work/roamtty")
        ))
        XCTAssertNil(cleared.contextPercent)
    }

    private func writeFakeTmux(binDir: URL, store: URL) throws {
        let fm = FileManager.default
        let script = """
        #!/bin/sh
        while [ "$1" = "-u" ]; do shift; done
        cmd="$1"; shift
        case "$cmd" in
          show-options)
            while [ "$#" -gt 0 ]; do
              case "$1" in -t) target="$2"; shift 2 ;; -*) shift ;; *) opt="$1"; shift ;; esac
            done
            cat "\(store.path)/${target}_${opt}" 2>/dev/null
            ;;
          set-option)
            unset_flag=0
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -u) unset_flag=1; shift ;;
                -t) target="$2"; shift 2 ;;
                -*) shift ;;
                *) if [ -z "$opt" ]; then opt="$1"; else val="$1"; fi; shift ;;
              esac
            done
            if [ "$unset_flag" = 1 ]; then rm -f "\(store.path)/${target}_${opt}"
            else printf '%s' "$val" > "\(store.path)/${target}_${opt}"; fi
            ;;
          display-message)
            while [ "$#" -gt 0 ]; do
              case "$1" in -t) target="$2"; shift 2 ;; *) shift ;; esac
            done
            sess="${target#=}"; sess="${sess%:}"
            a="$(cat "\(store.path)/${sess}_@roamtty_agent" 2>/dev/null)"
            s="$(cat "\(store.path)/${sess}_@roamtty_session" 2>/dev/null)"
            tp="$(cat "\(store.path)/${sess}_@roamtty_transcript" 2>/dev/null)"
            printf '%s\\t%s\\t%s\\t/work/roamtty\\t12345\\n' "$a" "$s" "$tp"
            ;;
        esac
        """
        let url = binDir.appendingPathComponent("tmux")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func runStatusLineInPane(hook: URL, home: URL, pathPrefix: String, pane: String, convId: String, tpath: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [hook.path, "agy", "statusline"]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["PATH"] = "\(pathPrefix):\(env["PATH"] ?? "/usr/bin:/bin")"
        env["ROAMTTY_AGENT"] = "agy"
        env["TMUX_PANE"] = pane
        proc.environment = env
        let pipe = Pipe()
        proc.standardInput = pipe
        try proc.run()
        let payload = #"{"conversation_id":"\#(convId)","transcript_path":"\#(tpath)","quota":{"gemini-5h":{"remaining_fraction":0.90,"reset_time":"2099-01-01T05:00:00Z"}}}"#
        pipe.fileHandleForWriting.write(Data(payload.utf8))
        try pipe.fileHandleForWriting.close()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
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

    private func runSessionCommand(
        home: URL, pathPrefix: String?, tmuxSession: String? = nil, directory: String = "/work/app"
    ) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", AgentUsage.sessionCommand(agent: .agy, tmuxSession: tmuxSession, directory: directory)]
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
