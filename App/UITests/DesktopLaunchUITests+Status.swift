import XCTest

/// The status cards: opening, what the host needs, failure and recovery.
extension DesktopLaunchUITests {
    func testDesktopPoorNetworkWarningMatchesAndroidTopLeft() throws {
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        launchStatusFixture(app, phase: "poor-network")
        for landscape in [false, true] {
            rotate(app, landscape: landscape)
            let warning = app.staticTexts["网络较差"]
            XCTAssertTrue(warning.waitForExistence(timeout: 5))
            let picture = app.otherElements["desktop-video-surface"].frame
            XCTAssertTrue(picture.contains(warning.frame))
            if landscape { XCTAssertLessThan(warning.frame.minX, picture.minX + 40) }
            XCTAssertLessThan(warning.frame.minY, picture.minY + 24)
            XCTAssertFalse(app.staticTexts["60 fps  2.4 Mbps"].exists)
            capture(app, landscape ? "Landscape Android network warning" : "Portrait Android network warning")
        }
    }

    func testDesktopOpeningShowsAndroidStepsAndStableCard() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        var previousSize: CGSize?
        for (phase, plugin, expectedStates) in [
            ("login", "启动桌面插件", ["进行中", "等待中", "等待中"]),
            ("install", "安装桌面插件", ["已完成", "进行中", "等待中"]),
            ("start", "启动桌面插件", ["已完成", "进行中", "等待中"]),
            ("first-frame", "启动桌面插件", ["已完成", "已完成", "进行中"])
        ] {
            launchStatusFixture(app, phase: phase)
            XCTAssertTrue(app.staticTexts["正在打开桌面"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["MacBook"].exists)
            for (index, label) in ["登录主机", plugin, "等待画面"].enumerated() {
                let step = app.otherElements["desktop-step-\(index)"]
                XCTAssertTrue(step.exists)
                XCTAssertEqual(step.label, label)
                XCTAssertEqual(step.value as? String, expectedStates[index])
            }
            let card = app.otherElements["desktop-status"]
            XCTAssertEqual(card.frame.width, 296, accuracy: 1)
            XCTAssertEqual(card.frame.height, 244, accuracy: 1)
            if let previousSize { XCTAssertEqual(card.frame.size, previousSize) }
            previousSize = card.frame.size
            XCTAssertTrue(app.staticTexts["desktop-log"].exists)
            XCTAssertFalse(app.buttons["desktop-retry"].exists)
            capture(app, "Android parity opening \(phase)")
        }
    }

    func testDesktopNeedsUseReadableInstructionsInBothLanguages() throws {
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        for english in [false, true] {
            launchStatusFixture(app, phase: "needs-screen-recording", english: english)
            let message = app.staticTexts["desktop-needs"]
            XCTAssertTrue(message.waitForExistence(timeout: 10))
            XCTAssertTrue(message.label.contains(english ? "Allow Screen Recording on the Mac" : "请在 Mac 上允许“屏幕录制”"))
            XCTAssertTrue(app.staticTexts[english ? "It connects by itself once done" : "满足后会自动连接"].exists)
            XCTAssertFalse(app.staticTexts["screen-recording"].exists)
            capture(app, english ? "English permission guide" : "Chinese permission guide")
            XCUIDevice.shared.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(message.isHittable)
            assertStatusInsideViewport(app)
            capture(app, english ? "English permission guide landscape" : "Chinese permission guide landscape")
            XCUIDevice.shared.orientation = .portrait
            Thread.sleep(forTimeInterval: 1)
        }
        launchStatusFixture(app, phase: "needs-windows")
        XCTAssertTrue(app.staticTexts["请先在这台电脑上登录桌面"].waitForExistence(timeout: 10))
        let copy = app.buttons["desktop-service-copy"]
        for _ in 0..<4 where !copy.isHittable { app.scrollViews["desktop-status-body"].swipeUp() }
        XCTAssertTrue(copy.isHittable, "Long Windows instructions must scroll to the copy command")
        copy.tap()
        capture(app, "Windows service command")
    }

    func testDesktopFailureAndRecoveryMatchAndroid() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        launchStatusFixture(app, phase: "failed")
        XCTAssertTrue(app.staticTexts["无法打开桌面"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["这台主机没有图形桌面"].exists)
        let retry = app.buttons["desktop-retry"], close = app.buttons["desktop-close"]
        XCTAssertTrue(retry.isHittable); XCTAssertTrue(close.isHittable)
        XCTAssertEqual(retry.frame.midY, close.frame.midY, accuracy: 1)
        XCTAssertFalse(app.activityIndicators.firstMatch.exists)
        capture(app, "Android parity failure")
        launchStatusFixture(app, phase: "recovering")
        XCTAssertTrue(app.staticTexts["连接中断"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["正在恢复…"].exists)
        XCTAssertTrue(app.staticTexts["网络恢复后画面会自动回来"].exists)
        capture(app, "Android parity recovery over last frame")
        launchStatusFixture(app, phase: "connected")
        XCTAssertTrue(app.otherElements["desktop-video-surface"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["desktop-status"].exists)
        XCTAssertFalse(app.otherElements["desktop-recovering"].exists)
    }

    func testDesktopRecoveryWaitsAndCancelsWhenPictureReturns() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        launchStatusFixture(app, phase: "recovery-sequence")
        let loseLink = app.buttons["所有窗口"], restoreLink = app.buttons["显示桌面"]
        XCTAssertTrue(loseLink.waitForExistence(timeout: 10))
        let recovery = app.otherElements["desktop-recovering"]
        loseLink.tap()
        XCTAssertFalse(recovery.exists, "Brief interruptions must not flash a recovery card")
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        restoreLink.tap()
        XCTAssertFalse(recovery.exists)
        loseLink.tap()
        restoreLink.tap()
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertFalse(recovery.exists, "A cancelled timer must not cover a restored picture")
        loseLink.tap()
        XCTAssertFalse(recovery.exists, "A new recovery episode gets its own delay")
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
    }

    /// Run on the compact simulator at default and accessibility sizes as well as the normal phone.
    func testDesktopStatusFitsViewportWithScrollableInstructions() throws {
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        for phase in ["first-frame", "needs-windows", "failed"] {
            launchStatusFixture(app, phase: phase, english: true)
            XCTAssertTrue(app.otherElements["desktop-status"].waitForExistence(timeout: 10))
            for landscape in [false, true] {
                XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
                Thread.sleep(forTimeInterval: 1)
                assertStatusInsideViewport(app)
                if phase == "needs-windows" {
                    let copy = app.buttons["desktop-service-copy"]
                    for _ in 0..<8 where !copy.isHittable { app.scrollViews["desktop-status-body"].swipeUp() }
                    XCTAssertTrue(copy.isHittable)
                } else if phase == "failed" {
                    XCTAssertTrue(app.buttons["desktop-retry"].isHittable)
                    XCTAssertTrue(app.buttons["desktop-close"].isHittable)
                }
                capture(app, "Status \(phase) fits \(landscape ? "landscape" : "portrait")")
            }
            XCUIDevice.shared.orientation = .portrait
        }
    }

    func assertStatusInsideViewport(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let card = app.otherElements["desktop-status"].frame
        XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(card), "Card \(card) must fit \(app.frame)", file: file, line: line)
        XCTAssertGreaterThan(card.width, 200, file: file, line: line)
        XCTAssertGreaterThan(card.height, 150, file: file, line: line)
    }

    func launchStatusFixture(_ app: XCUIApplication, phase: String, english: Bool = false, showStats: Bool = false) {
        continueAfterFailure = false
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--desktop-controls-fixture"]
        app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "DesktopControlsFixture"
        app.launchEnvironment["ROAMTTY_DESKTOP_STATUS_FIXTURE"] = phase
        app.launchEnvironment["ROAMTTY_DESKTOP_FIXTURE_LANGUAGE"] = english ? "en" : "zh-Hans"
        app.launchEnvironment["ROAMTTY_DESKTOP_STATS_FIXTURE"] = showStats ? "1" : "0"
        app.launch()
    }

    func rotate(_ app: XCUIApplication, landscape: Bool) {
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        let orientation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (app.frame.width > app.frame.height) == landscape
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [orientation], timeout: 5), .completed,
                       "Wait for the application window to finish rotating")
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Real SSH to a headless fixture, with a deliberately stale positive desktop cache.
    func testHeadlessHostStopsRetryingAndUpdatesCard() throws {
        guard ProcessInfo.processInfo.environment["ROAMTTY_HEADLESS_DESKTOP_FIXTURE"] == "1" else {
            throw XCTSkip("Requires seed-headless-desktop-fixture.py and a headless SSH fixture")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "DesktopHeadlessRegression"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-tab-hosts"].waitForExistence(timeout: 15))
        app.buttons["home-tab-hosts"].tap()
        let screen = app.buttons["host-screen-ui-live-host"]
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        screen.tap()
        let failure = app.staticTexts["这台主机没有图形桌面"]
        XCTAssertTrue(failure.waitForExistence(timeout: 15))
        let retry = app.buttons["重试"]
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 2)
            XCTAssertTrue(failure.exists, "The terminal failure must stay visible instead of reopening the desktop")
            XCTAssertTrue(retry.exists)
        }
        capture(app, "Headless desktop failure stays visible")
        // A retry is explicit, and another negative probe returns to the same stable failure page.
        retry.tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        app.buttons["关闭"].tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["没有图形桌面"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["home-tab-hosts"].waitForExistence(timeout: 15))
        app.buttons["home-tab-hosts"].tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["没有图形桌面"].exists)
        screen.tap()
        XCTAssertTrue(app.buttons["host-detail-terminal"].waitForExistence(timeout: 10))
        XCTAssertFalse(failure.exists)
        capture(app, "Headless host opens details after relaunch")
    }
}
