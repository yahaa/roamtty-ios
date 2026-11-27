import XCTest

/// Isolated offline simulator UI tests & screenshot capture for Terminal `agy /voice`.
final class VoiceUITests: XCTestCase {
    private var shotDir: URL? {
        ProcessInfo.processInfo.environment["ROAMTTY_VOICE_SHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private func saveShot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = shotDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: dir.appendingPathComponent(name + ".png"))
        }
    }

    private func launchVoiceFixture(
        _ app: XCUIApplication,
        state: String? = nil,
        dockOpen: Bool = false,
        popoverOpen: Bool = false,
        networkUnstable: Bool = false,
        pluginMissing: Bool = false,
        english: Bool = false
    ) {
        continueAfterFailure = false
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--voice-ui-fixture"]
        app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "VoiceUIFixture"
        app.launchEnvironment["ROAMTTY_VOICE_FIXTURE_LANGUAGE"] = english ? "en" : "zh-Hans"
        app.launchEnvironment["ROAMTTY_VOICE_FIXTURE_DOCK"] = dockOpen ? "1" : "0"
        app.launchEnvironment["ROAMTTY_VOICE_FIXTURE_POPOVER"] = popoverOpen ? "1" : "0"
        app.launchEnvironment["ROAMTTY_VOICE_FIXTURE_UNSTABLE"] = networkUnstable ? "1" : "0"
        app.launchEnvironment["ROAMTTY_VOICE_FIXTURE_PLUGIN_MISSING"] = pluginMissing ? "1" : "0"
        if let state { app.launchEnvironment["ROAMTTY_VOICE_FIXTURE_STATE"] = state } else { app.launchEnvironment.removeValue(forKey: "ROAMTTY_VOICE_FIXTURE_STATE") }
        app.launch()
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 2) {
            alert.buttons.firstMatch.tap()
            _ = alert.waitForNonExistence(timeout: 3)
        }
    }

    /// Reopens the floating dock via `terminal-ghost` if an alert or screenshot delay elapsed past `dockHideSeconds`.
    private func ensureVoiceDockButton(_ app: XCUIApplication, timeout: TimeInterval = 10) -> XCUIElement {
        let voiceBtn = app.buttons["terminal-voice"]
        if voiceBtn.exists && voiceBtn.isHittable { return voiceBtn }
        if voiceBtn.waitForExistence(timeout: 2), voiceBtn.isHittable { return voiceBtn }
        let ghost = app.buttons["terminal-ghost"]
        if !ghost.waitForExistence(timeout: 2) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
            _ = ghost.waitForExistence(timeout: 4)
        }
        if ghost.exists { ghost.tap() }
        XCTAssertTrue(voiceBtn.waitForExistence(timeout: timeout), "Phone button must appear in agy dock")
        return voiceBtn
    }

    func testVoiceOneTapLiveCallFloatingPetPopoverAndGestures() {
        let app = XCUIApplication()
        defer { app.terminate() }

        // 1. Dock phone button beside desktop button in agy session.
        launchVoiceFixture(app, dockOpen: true)
        _ = ensureVoiceDockButton(app)
        XCTAssertTrue(app.buttons["terminal-desktop"].exists, "Desktop button stays beside phone button")
        Thread.sleep(forTimeInterval: 0.4)
        saveShot("01-voice-dock-phone")

        // 2. Tap phone button -> starts live call immediately (no confirmation sheet), dock collapses, floating ghost appears & never auto-hides (>5s).
        ensureVoiceDockButton(app).tap()
        XCTAssertFalse(app.buttons["voice-sheet-confirm"].exists, "Confirmation sheet must not appear")
        let ghost = app.buttons["terminal-ghost"]
        XCTAssertTrue(ghost.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["pet-voice-tag"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
        saveShot("02-voice-floating-pet")

        // Confirm pet never auto-hides past normal 5s timeout while call is active.
        Thread.sleep(forTimeInterval: 5.4)
        XCTAssertTrue(ghost.exists, "Ghost pet must NEVER auto-hide during an active voice call")

        // 3. Tap phone-holding pet -> compact call control popover pops to its left.
        ghost.tap()
        let muteBtn = app.buttons["voice-pop-mute"]
        XCTAssertTrue(muteBtn.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["voice-pop-route"].exists)
        XCTAssertTrue(app.buttons["voice-pop-dock"].exists)
        XCTAssertTrue(app.buttons["voice-pop-hangup"].exists)
        Thread.sleep(forTimeInterval: 0.4)
        saveShot("03-voice-call-popover")

        // Test Mute toggle and Route cycle.
        muteBtn.tap()
        XCTAssertTrue(app.staticTexts["麦克风已静音"].waitForExistence(timeout: 3))
        app.buttons["voice-pop-route"].tap()
        XCTAssertTrue(app.buttons["voice-pop-route"].label.contains("听筒"))

        // Tap outside dismisses popover WITHOUT ending call.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.15)).tap()
        XCTAssertTrue(muteBtn.waitForNonExistence(timeout: 3))
        XCTAssertTrue(ghost.exists, "Call stays active after dismissing popover")

        // Long-pressing pet STILL opens GhostShortcuts radial arc!
        ghost.press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["pet-ctrl-o"].waitForExistence(timeout: 3), "Long press preserves GhostShortcuts arc")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.15)).tap()
        XCTAssertTrue(app.buttons["pet-ctrl-o"].waitForNonExistence(timeout: 3))

        // Re-open popover and Hangup -> ends call and reverts handset back to keyboard.
        ghost.tap()
        XCTAssertTrue(app.buttons["voice-pop-hangup"].waitForExistence(timeout: 3))
        app.buttons["voice-pop-hangup"].tap()
        XCTAssertTrue(app.staticTexts["pet-voice-tag"].waitForNonExistence(timeout: 3))
    }

    func testVoiceSpeakingAndUnstableNetworkStatesRenderCleanly() {
        let app = XCUIApplication()
        defer { app.terminate() }
        launchVoiceFixture(app, state: "speaking")
        XCTAssertTrue(app.buttons["terminal-ghost"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["AI 回复中"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.4)
        saveShot("04-voice-pet-speaking")

        launchVoiceFixture(app, state: "listening", networkUnstable: true)
        XCTAssertTrue(app.buttons["terminal-ghost"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["网络不稳定"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.4)
        saveShot("05-voice-pet-unstable")
    }
}
