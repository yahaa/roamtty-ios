import XCTest

/// The controls, and a live desktop: its keyboard, its sound and a cold launch.
extension DesktopLaunchUITests {
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
                assertPictureClearsKeyboard(app, landscape: landscape, fullHeight: fullPictureHeight, controls: toggle)
                if landscape { capture(app, "Landscape before shortcut toggle") }
                toggle.tap()
            }
            XCTAssertTrue(app.buttons["desktop-kb-more"].waitForExistence(timeout: 5))
            if !landscape { XCTAssertFalse(ops.exists, "Portrait rail is replaced by the keyboard") }
            assertPictureClearsKeyboard(app, landscape: landscape, fullHeight: fullPictureHeight, controls: app.buttons["desktop-kb-more"])

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
            assertPictureClearsKeyboard(app, landscape: landscape, fullHeight: fullPictureHeight, controls: app.buttons["desktop-kb-more"])
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

    /// Portrait: the picture shrinks to fit above the keyboard. Landscape: the picture is short already, so it keeps
    /// its full height and the keyboard floats over its lower part.
    func assertPictureClearsKeyboard(_ app: XCUIApplication, landscape: Bool, fullHeight: CGFloat, controls: XCUIElement) {
        guard landscape else { return assertPictureAboveControls(app, controls: controls) }
        let picture = app.otherElements["desktop-video-surface"]
        XCTAssertEqual(picture.frame.height, fullHeight, accuracy: 1, "The landscape keyboard does not shrink the picture")
        XCTAssertGreaterThan(picture.frame.maxY, controls.frame.maxY,
                             "The landscape keyboard floats over the picture instead of shrinking it")
    }

    func assertPictureAboveControls(_ app: XCUIApplication, controls: XCUIElement) {
        let picture = app.otherElements["desktop-video-surface"]
        XCTAssertTrue(picture.exists)
        XCTAssertGreaterThan(picture.frame.height, 20)
        XCTAssertLessThanOrEqual(picture.frame.maxY, controls.frame.minY + 1,
                                 "The complete remote picture must fit above the keyboard and shortcuts")
    }

    func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// The host's sound on the phone (Android `E2eAudioTest`): the host loops a 440 Hz / 660 Hz tone
    /// (the runner starts it), the app decodes 440 Hz on the left at the tone's level, near live and
    /// without drops; 声音 off stops the packets and on brings them back. Played at volume 0: a simulator
    /// would play it through the Mac's speakers.
    func testLiveDesktopPlaysTheHostsSound() throws {
        guard let host = ProcessInfo.processInfo.environment["ROAMTTY_LIVE_DESKTOP_HOST"], !host.isEmpty,
              ProcessInfo.processInfo.environment["ROAMTTY_LIVE_DESKTOP_TONE"] == "1" else {
            throw XCTSkip("Set ROAMTTY_LIVE_DESKTOP_HOST and ROAMTTY_LIVE_DESKTOP_TONE=1 with a tone playing on the host")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ROAMTTY_DESKTOP_AUDIO_PROBE"] = "1"
        app.launchEnvironment["ROAMTTY_DESKTOP_AUDIO_MUTE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-hosts"].waitForExistence(timeout: 15))
        app.buttons["home-tab-hosts"].tap()
        let card = app.buttons["host-screen-" + host]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let online = NSPredicate(format: "label CONTAINS[c] '打开桌面' OR label CONTAINS[c] 'Open desktop'")
        expectation(for: online, evaluatedWith: card)
        waitForExpectations(timeout: 20)
        card.tap()
        let probe = app.staticTexts["desktop-audio-probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 60), "the player decoded something")
        func value(_ key: String) -> Int {
            let label = probe.label
            guard let r = label.range(of: key + "=") else { return -1 }
            return Int(label[r.upperBound...].prefix { $0.isNumber }) ?? -1
        }
        // 440 Hz crosses zero 880 times a second; the tone's RMS is 8000 / √2.
        let tone = NSPredicate { _, _ in (860...900).contains(value("crossings")) && (5000...6300).contains(value("rms")) }
        expectation(for: tone, evaluatedWith: probe)
        waitForExpectations(timeout: 30)
        // Settled: a few seconds of steady play, near live, without drops.
        Thread.sleep(forTimeInterval: 10)
        let dropped = value("dropped"), packets = value("packets")
        var queued: [Int] = []
        for _ in 0..<10 { Thread.sleep(forTimeInterval: 0.3); queued.append(value("queued")) }
        let state = "\(probe.label), queued \(queued)"
        // As deep as the network's jitter, never past the drop line above it.
        XCTAssertLessThanOrEqual(queued.max() ?? 999, value("target") + 120, state)
        XCTAssertLessThanOrEqual(value("target"), 300, state)
        XCTAssertLessThanOrEqual((value("dropped") - dropped) * 50, max(1, value("packets") - packets), state)
        NSLog("RoamttyAudioProbe %@", state)
        capture(app, "Sound playing")

        // 声音 off: no more packets; on again: they come back.
        let ops = app.buttons.matching(NSPredicate(format: "label == '操作' OR label == 'Ops'")).firstMatch
        let sound = app.switches.matching(NSPredicate(format: "label BEGINSWITH '声音' OR label BEGINSWITH 'Sound'")).firstMatch
        ops.tap()
        XCTAssertTrue(sound.waitForExistence(timeout: 5))
        XCTAssertEqual(sound.value as? String, "1")
        sound.tap()
        app.buttons["desktop-op-close"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        let off = value("packets")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(value("packets"), off, "no packets while sound is off")
        ops.tap()
        XCTAssertTrue(sound.waitForExistence(timeout: 5))
        sound.tap()
        app.buttons["desktop-op-close"].tap()
        let back = NSPredicate { _, _ in value("packets") > off + 50 }
        expectation(for: back, evaluatedWith: probe)
        waitForExpectations(timeout: 15)
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
        // The card's picture opens the desktop once the host is reachable.
        let card = app.buttons["host-screen-" + host]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let online = NSPredicate(format: "label CONTAINS[c] '打开桌面' OR label CONTAINS[c] 'Open desktop'")
        expectation(for: online, evaluatedWith: card)
        waitForExpectations(timeout: 20)
        card.tap()
        let ops = app.buttons.matching(NSPredicate(format: "label == '操作' OR label == 'Ops'")).firstMatch
        XCTAssertTrue(ops.waitForExistence(timeout: 15))
        ops.tap()
        let row = app.switches.matching(NSPredicate(format: "label BEGINSWITH '显示网络状态' OR label BEGINSWITH 'Show network stats'")).firstMatch
        let stats = row.switches.firstMatch
        XCTAssertTrue(stats.waitForExistence(timeout: 5))
        let wasOff = (stats.value as? String) == "0"
        if wasOff {
            stats.tap()
            XCTAssertEqual(stats.value as? String, "1")
        }
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
        if wasOff {
            ops.tap()
            stats.tap()
            XCTAssertEqual(stats.value as? String, "0")
            app.buttons["desktop-op-close"].tap()
        }
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-hosts"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
    }
}
