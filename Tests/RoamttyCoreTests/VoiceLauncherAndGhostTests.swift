import Foundation
import XCTest
@testable import RoamttyCore

final class VoiceLauncherAndGhostTests: XCTestCase {
    func testAgyLauncherInjectsAntigravityMicAndWindowsLauncherMatches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".roamtty"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try AgentHooks.script.write(to: dir.appendingPathComponent(".roamtty/agent-hook.sh"), atomically: true, encoding: .utf8)
        let launcher = dir.appendingPathComponent(".roamtty/agy")
        try AgentHooks.agyLauncher(micPort: 24713).write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        let fakeAgy = dir.appendingPathComponent("agy")
        let seen = dir.appendingPathComponent("seen.txt")
        let argsSeen = dir.appendingPathComponent("args.txt")
        try "#!/bin/sh\nprintf '%s|%s' \"$ROAMTTY_AGENT\" \"$ANTIGRAVITY_MIC\" > '\(seen.path)'\nprintf '%s\\n' \"$@\" > '\(argsSeen.path)'\nexit 0\n"
            .write(to: fakeAgy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeAgy.path)

        let proc = Process()
        proc.executableURL = launcher
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = dir.path
        env["PATH"] = dir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env.removeValue(forKey: "ANTIGRAVITY_MIC")
        proc.environment = env
        try proc.run(); proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: seen, encoding: .utf8), "agy|127.0.0.1:24713")
        let args = try String(contentsOf: argsSeen, encoding: .utf8)
        XCTAssertTrue(args.contains("--settings"), args)
        XCTAssertTrue(args.contains("\"fullDuplex\":true"), args)
        XCTAssertTrue(args.contains("sh ~/.roamtty/agent-hook.sh agy statusline"), args)

        // Explicit --settings passed by caller is preserved without duplicating launcher --settings.
        let procCustom = Process()
        procCustom.executableURL = launcher
        procCustom.arguments = ["--settings", "{}"]
        procCustom.environment = env
        try procCustom.run(); procCustom.waitUntilExit()
        XCTAssertEqual(try String(contentsOf: argsSeen, encoding: .utf8), "--settings\n{}\n")

        // Dynamic default launcher uses 127.0.0.1:24713 when voice-mic is absent, and honors ~/.roamtty/voice-mic when present.
        try AgentHooks.agyLauncher(micPort: nil).write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let procDefault = Process()
        procDefault.executableURL = launcher
        procDefault.environment = env
        try procDefault.run(); procDefault.waitUntilExit()
        XCTAssertEqual(try String(contentsOf: seen, encoding: .utf8), "agy|127.0.0.1:24713")

        try "127.0.0.1:31234\n".write(to: dir.appendingPathComponent(".roamtty/voice-mic"), atomically: true, encoding: .utf8)
        let proc2 = Process()
        proc2.executableURL = launcher
        proc2.environment = env
        try proc2.run(); proc2.waitUntilExit()
        XCTAssertEqual(try String(contentsOf: seen, encoding: .utf8), "agy|127.0.0.1:31234")
    }

    func testTmuxSetEnvironmentAndInjectScriptRunExpectedTmuxCommand() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-tmux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let logFile = dir.appendingPathComponent("tmux.log")
        let fakeTmux = dir.appendingPathComponent("tmux")
        try "#!/bin/sh\nprintf '%s|' \"$@\" >> '\(logFile.path)'\nprintf '\\n' >> '\(logFile.path)'\n"
            .write(to: fakeTmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeTmux.path)

        let script = try XCTUnwrap(RemoteCommands.injectAntigravityMicScript(micPort: 24713, tmuxSession: "roamtty-abc;rm"))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = dir.path
        env["PATH"] = dir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        proc.environment = env
        try proc.run(); proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        let tmuxArgs = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(tmuxArgs.contains("set-environment|-t|=roamtty-abcrm|ANTIGRAVITY_MIC|127.0.0.1:24713|"), tmuxArgs)
        let launcherContent = try String(contentsOf: dir.appendingPathComponent(".roamtty/agy"), encoding: .utf8)
        XCTAssertTrue(launcherContent.contains("voice-mic"))
        XCTAssertTrue(launcherContent.contains("export ANTIGRAVITY_MIC=127.0.0.1:24713"))
        let voiceMic = try String(contentsOf: dir.appendingPathComponent(".roamtty/voice-mic"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(voiceMic, "127.0.0.1:24713")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(".roamtty").path)
        XCTAssertFalse(files.contains { $0.hasPrefix("voice-mic.") || $0.hasPrefix("agy.") }, "atomic mktemp+mv must leave no temp files")

        // Clear removes transient voice-mic and unsets tmux override while keeping the default 24713 launcher.
        let clearScript = RemoteCommands.clearAntigravityMicScript(tmuxSession: "roamtty-abc;rm")
        let procClear = Process()
        procClear.executableURL = URL(fileURLWithPath: "/bin/sh")
        procClear.arguments = ["-c", clearScript]
        procClear.environment = env
        try procClear.run(); procClear.waitUntilExit()
        XCTAssertEqual(procClear.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".roamtty/voice-mic").path))
        let clearedTmux = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(clearedTmux.contains("set-environment|-u|-t|=roamtty-abcrm|ANTIGRAVITY_MIC|"), clearedTmux)

        XCTAssertNil(RemoteCommands.tmuxSetEnvironment(session: "s", name: "BAD;NAME", value: "1"))
        let exactSet = try XCTUnwrap(RemoteCommands.tmuxSetEnvironment(session: "s", name: "ANTIGRAVITY_MIC", value: "127.0.0.1:24713"))
        XCTAssertTrue(exactSet.contains("-t =s"))
    }

    func testGhostVoiceStatesAndReduceMotionAccessibility() {
        XCTAssertTrue(GhostVoiceState.idle.showsKeyboard)
        XCTAssertFalse(GhostVoiceState.idle.showsHandset)
        XCTAssertFalse(GhostVoiceState.idle.showsAura)

        let connecting = GhostVoiceState.connecting
        XCTAssertTrue(connecting.showsHandset && connecting.showsAura && connecting.showsSoundWaves)

        let listening = GhostVoiceState.listening(level: 1.8)
        XCTAssertTrue(listening.showsHandset && listening.showsAura && !listening.showsSoundWaves)
        XCTAssertEqual(listening.audioLevel, 1.0)
        XCTAssertEqual(GhostVoiceState.listening(level: .nan).audioLevel, 0.0)

        let speaking = GhostVoiceState.speaking(level: 0.65)
        XCTAssertTrue(speaking.showsHandset && speaking.showsAura && speaking.showsSoundWaves && !speaking.showsMuteBadge)
        XCTAssertEqual(speaking.audioLevel, 0.65, accuracy: 0.0001)

        let muted = GhostVoiceState.muted
        XCTAssertTrue(muted.showsHandset && muted.showsAura && !muted.showsSoundWaves && muted.showsMuteBadge)

        // Pet stays green (.stable) across every active call state while network is stable,
        // and shifts to amber (.unstable) only when network is unstable or reconnecting.
        for activeState in [connecting, listening, speaking, muted] {
            XCTAssertEqual(GhostVoiceTone.forCall(state: activeState, networkUnstable: false), .stable)
            XCTAssertEqual(GhostVoiceTone.forCall(state: activeState, networkUnstable: true), .unstable)
        }
        XCTAssertEqual(GhostVoiceTone.forCall(state: .idle, networkUnstable: true), .stable)

        // Reduce Motion freezes bob/sway/jiggle/pulse while retaining static handset & wave marks.
        let rmA = GhostVoicePose.at(0.1, voice: speaking, reduceMotion: true)
        let rmB = GhostVoicePose.at(2.7, voice: speaking, reduceMotion: true)
        XCTAssertEqual(rmA, rmB)
        XCTAssertEqual(rmA.sway, 0)
        XCTAssertEqual(rmA.wave, 0)
        XCTAssertEqual(rmA.ringJiggle, 0)
        XCTAssertNil(rmA.pulseProgress)
        XCTAssertEqual(rmA.waveAlpha1, 0.85)
        XCTAssertEqual(rmA.waveAlpha2, 0.55)

        // Live motion produces wrench damping (0.18x) in call and ringing jiggle in connecting.
        let idleWave = GhostVoicePose.at(3.18, voice: .idle, reduceMotion: false).wave
        let callWave = GhostVoicePose.at(3.18, voice: listening, reduceMotion: false).wave
        XCTAssertEqual(callWave, idleWave * 0.18, accuracy: 0.0001)
        let ringPose = GhostVoicePose.at(0.12, voice: .connecting, reduceMotion: false)
        XCTAssertNotEqual(ringPose.ringJiggle, 0)
        XCTAssertNotNil(ringPose.pulseProgress)
    }
}
