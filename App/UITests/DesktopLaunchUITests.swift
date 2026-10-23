import XCTest

/// Opt-in regression against a saved desktop host and its existing credentials.
/// Does not reset the user's store or create/edit hosts.
final class DesktopLaunchUITests: XCTestCase {
    func testDesktopControlsLayoutAndKeyboard() throws {
        guard ProcessInfo.processInfo.environment["ROAMTTY_DESKTOP_CONTROLS_FIXTURE"] == "1" else {
            throw XCTSkip("Requires isolated desktop controls fixture")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--desktop-controls-fixture"]
        app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "DesktopControlsFixture"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        let ops = app.buttons.matching(NSPredicate(format: "label == '操作' OR label == 'Ops'")).firstMatch
        XCTAssertTrue(ops.waitForExistence(timeout: 15))
        for landscape in [false, true] {
            XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
            Thread.sleep(forTimeInterval: 1)
            ops.tap()
            XCTAssertTrue(app.buttons["desktop-op-close"].waitForExistence(timeout: 5))
            let mode = app.buttons.matching(NSPredicate(format: "label == '鼠标指针' OR label == 'Trackpad'")).firstMatch
            XCTAssertTrue(mode.exists); mode.tap(); XCTAssertTrue(mode.isSelected)
            capture(app, landscape ? "Landscape operations" : "Portrait operations")
            app.buttons["desktop-op-close"].tap()
            let fullPictureHeight = app.otherElements["desktop-video-surface"].frame.height
            app.buttons.matching(NSPredicate(format: "label == '键盘' OR label == 'Keys'")).firstMatch.tap()
            Thread.sleep(forTimeInterval: 1)
            let keyboardContinue = app.buttons["Continue"]
            if keyboardContinue.waitForExistence(timeout: 2) { keyboardContinue.tap() }
            let toggle = app.buttons["desktop-kb-toggle"]
            if toggle.waitForExistence(timeout: 3) {
                assertPictureAboveControls(app, controls: toggle)
                if landscape { capture(app, "Landscape before shortcut toggle") }
                toggle.tap()
            }
            XCTAssertTrue(app.buttons["desktop-kb-more"].waitForExistence(timeout: 5))
            if !landscape { XCTAssertFalse(ops.exists, "Portrait rail is replaced by the keyboard") }
            assertPictureAboveControls(app, controls: app.buttons["desktop-kb-more"])

            let modifier = app.buttons.matching(NSPredicate(format: "label == 'Ctrl' OR label == '⌃'")).firstMatch
            XCTAssertTrue(modifier.exists)
            modifier.press(forDuration: 0.7)
            XCTAssertTrue(["已锁定", "Locked"].contains(modifier.value as? String ?? ""))
            modifier.tap()
            modifier.tap()
            XCTAssertTrue(["单次生效", "Once"].contains(modifier.value as? String ?? ""))
            app.buttons["Esc"].tap()
            XCTAssertEqual(modifier.value as? String ?? "", "")
            capture(app, landscape ? "Landscape shortcuts and IME" : "Portrait shortcuts and IME")
            app.buttons["desktop-kb-more"].tap()
            Thread.sleep(forTimeInterval: 0.5)
            let f12 = app.buttons["F12"]
            XCTAssertTrue(f12.waitForExistence(timeout: 5)); XCTAssertTrue(f12.isHittable)
            assertPictureAboveControls(app, controls: app.buttons["desktop-kb-more"])
            f12.tap()
            let shift = app.buttons["Shift"]
            XCTAssertTrue(shift.isHittable); shift.tap()
            capture(app, landscape ? "Landscape PC keys" : "Portrait PC keys")
            app.buttons["desktop-kb-more"].tap()
            Thread.sleep(forTimeInterval: 0.5)
            app.buttons["desktop-kb-hide-bar"].tap()
            XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
            modifier.press(forDuration: 0.7)
            app.buttons.matching(NSPredicate(format: "label == '关闭键盘' OR label == 'Close keyboard'")).firstMatch.tap()
            XCTAssertTrue(ops.waitForExistence(timeout: 5))
            XCTAssertEqual(app.otherElements["desktop-video-surface"].frame.height, fullPictureHeight, accuracy: 1)
            app.buttons.matching(NSPredicate(format: "label == '键盘' OR label == 'Keys'")).firstMatch.tap()
            XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
            XCTAssertEqual(modifier.value as? String ?? "", "", "Closing the keyboard must clear locked modifiers")
            app.buttons.matching(NSPredicate(format: "label == '关闭键盘' OR label == 'Close keyboard'")).firstMatch.tap()
        }
    }

    private func assertPictureAboveControls(_ app: XCUIApplication, controls: XCUIElement) {
        let picture = app.otherElements["desktop-video-surface"]
        XCTAssertTrue(picture.exists)
        XCTAssertGreaterThan(picture.frame.height, 20)
        XCTAssertLessThanOrEqual(picture.frame.maxY, controls.frame.minY + 1,
                                 "The complete remote picture must fit above the keyboard and shortcuts")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testColdLaunchAndLiveDesktopStayRunning() throws {
        guard let host = ProcessInfo.processInfo.environment["ROAMTTY_LIVE_DESKTOP_HOST"], !host.isEmpty else {
            throw XCTSkip("Set ROAMTTY_LIVE_DESKTOP_HOST to a saved, desktop-enabled host")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        for _ in 0..<2 {
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["home-tab-hosts"].waitForExistence(timeout: 15))
            XCTAssertEqual(app.state, .runningForeground)
        }
        app.buttons["home-tab-hosts"].tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier ==[c] %@", "host-" + host)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        let desktop = app.buttons["host-detail-desktop"]
        XCTAssertTrue(desktop.waitForExistence(timeout: 10))
        desktop.tap()
        let ops = app.buttons.matching(NSPredicate(format: "label == '操作' OR label == 'Ops'")).firstMatch
        XCTAssertTrue(ops.waitForExistence(timeout: 15))
        ops.tap()
        let stats = app.switches.matching(NSPredicate(format: "label BEGINSWITH '显示网络状态' OR label BEGINSWITH 'Show network stats'")).firstMatch
        XCTAssertTrue(stats.waitForExistence(timeout: 5))
        let wasOff = (stats.value as? String) == "0"
        if wasOff { stats.tap() }
        app.buttons["desktop-op-close"].tap()
        let frames = app.staticTexts.matching(NSPredicate(format: "label MATCHES '.*[1-9][0-9]* fps.*'")).firstMatch
        XCTAssertTrue(frames.waitForExistence(timeout: 30), "Must receive live desktop frames")
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 5)
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertTrue(frames.exists, "Live video stats must remain visible")
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Live desktop after 30 seconds"
        attachment.lifetime = .keepAlways
        add(attachment)
        if wasOff { ops.tap(); stats.tap(); app.buttons["desktop-op-close"].tap() }
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-hosts"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
    }
}
