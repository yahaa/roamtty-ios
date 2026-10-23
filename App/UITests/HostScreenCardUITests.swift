import XCTest

/// Opt-in end-to-end screen-card parity check using an existing saved host, without changing its data.
final class HostScreenCardUITests: XCTestCase {
    func testLivePreviewPersistsAndStripOpensDetails() throws {
        guard let host = ProcessInfo.processInfo.environment["ROAMTTY_LIVE_DESKTOP_HOST"], !host.isEmpty else {
            throw XCTSkip("Set ROAMTTY_LIVE_DESKTOP_HOST to a saved desktop host")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let hosts = app.buttons["home-tab-hosts"]
        XCTAssertTrue(hosts.waitForExistence(timeout: 15)); hosts.tap()
        let strip = app.buttons.matching(NSPredicate(format: "identifier ==[c] %@", "host-" + host)).firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 10))
        capture(app, "Screen cards before connecting")
        strip.tap()
        XCTAssertTrue(app.buttons["host-detail-desktop"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let screen = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'host-screen-' AND label CONTAINS[c] %@", host)).firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 10)); screen.tap()
        let ops = app.buttons.matching(NSPredicate(format: "label == '操作' OR label == 'Ops'")).firstMatch
        XCTAssertTrue(ops.waitForExistence(timeout: 15))
        // Allow connection, capture cadence, and async JPEG write to complete.
        Thread.sleep(forTimeInterval: 30)
        XCTAssertEqual(app.state, .runningForeground)
        ops.tap()
        app.buttons["desktop-op-exit"].tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        let saved = NSPredicate(format: "value == '已保存桌面预览' OR value == 'Saved desktop preview'")
        expectation(for: saved, evaluatedWith: screen)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == '已连接' OR label == 'Connected'")).firstMatch.exists)
        capture(app, "Connected host screen card with saved preview")
        // The strip must keep its detail action even when a desktop is running.
        strip.tap()
        XCTAssertTrue(app.buttons["host-detail-desktop"].waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        XCTAssertTrue(hosts.waitForExistence(timeout: 15)); hosts.tap()
        XCTAssertTrue(screen.waitForExistence(timeout: 10))
        expectation(for: saved, evaluatedWith: screen)
        waitForExpectations(timeout: 15)
        capture(app, "Screen card preview after cold launch")
    }
    /// Simulator fixtures are seeded in isolated stores by the validation script, never in user data.
    func testOfflineAndHeadlessCardsOpenDetails() throws {
        guard ProcessInfo.processInfo.environment["ROAMTTY_HOST_CARD_FIXTURE"] == "1" else {
            throw XCTSkip("Requires isolated simulator host-card fixtures")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        for theme in ["dark", "light"] {
            app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "HostCardParity-" + theme
            app.launch()
            let hosts = app.buttons["home-tab-hosts"]
            XCTAssertTrue(hosts.waitForExistence(timeout: 15)); hosts.tap()
            let headless = app.buttons["host-screen-headless"]
            XCTAssertTrue(headless.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["没有图形桌面"].exists)
            XCTAssertTrue(app.staticTexts["tmux"].firstMatch.exists)
            XCTAssertTrue(app.staticTexts["mosh"].firstMatch.exists)
            // The fixture points to a closed loopback port. Wait for the real reachability probe.
            let offline = app.staticTexts["离线"].firstMatch
            XCTAssertTrue(offline.waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 2)
            capture(app, "Offline preview and headless cards - " + theme)
            for id in ["pictured", "headless"] {
                app.buttons["host-screen-" + id].tap()
                XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 10))
                XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == '操作' OR label == 'Ops'")).firstMatch.exists)
                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(headless.waitForExistence(timeout: 10))
            }
            app.terminate()
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
