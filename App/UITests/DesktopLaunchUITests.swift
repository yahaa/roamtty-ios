import XCTest

/// Opt-in regression against a saved desktop host and its existing credentials.
/// Does not reset the user's store or create/edit hosts.
final class DesktopLaunchUITests: XCTestCase {
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
        let stats = app.switches.matching(NSPredicate(format: "label == '显示网络状态' OR label == 'Show network stats'")).firstMatch
        XCTAssertTrue(stats.waitForExistence(timeout: 5))
        let wasOff = (stats.value as? String) == "0"
        if wasOff { stats.tap() }
        ops.tap()
        let frames = app.staticTexts.matching(NSPredicate(format: "label MATCHES '.*[1-9][0-9]* fps.*'")).firstMatch
        XCTAssertTrue(frames.waitForExistence(timeout: 30), "Must receive live desktop frames")
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 5)
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertTrue(frames.exists, "Live video stats must remain visible")
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Live desktop after 30 seconds"
        attachment.lifetime = .keepAlways
        add(attachment)
        if wasOff { ops.tap(); stats.tap(); ops.tap() }
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["home-tab-hosts"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
    }
}
