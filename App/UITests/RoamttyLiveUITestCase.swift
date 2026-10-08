import XCTest

class RoamttyLiveUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        for key in ["ROAMTTY_TEST_HOST", "ROAMTTY_TEST_PORT", "ROAMTTY_TEST_USERNAME", "ROAMTTY_TEST_PASSWORD"] {
            if let value = ProcessInfo.processInfo.environment[key] { app.launchEnvironment[key] = value }
        }
        app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "UI-\(UUID().uuidString)"
        addUIInterruptionMonitor(withDescription: "Roamtty local network permission") { alert in
            guard alert.label.contains("Roamtty") || alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Roamtty'")).count > 0 else { return false }
            for title in ["Allow", "允许", "OK", "好"] {
                if alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            }
            return false
        }
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.exists && (alert.label.contains("Roamtty") || alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Roamtty'")).count > 0) {
            for title in ["Allow", "允许", "OK", "好"] where alert.buttons[title].exists { alert.buttons[title].tap(); break }
        }
        // A failed previous case may leave a durable extension receipt. Let normal
        // startup consume it into this case's isolated store, then dismiss its chooser.
        // Relaunches within a test do not run this cleanup and still verify recovery.
        let incoming = app.navigationBars.matching(NSPredicate(format: "identifier == '共享文件' OR identifier == 'Shared files'")).firstMatch
        if incoming.waitForExistence(timeout: 1) {
            let cancel = incoming.buttons.matching(NSPredicate(format: "label == '取消' OR label == 'Cancel'")).firstMatch
            XCTAssertTrue(cancel.exists); cancel.tap()
        }
    }

    func openHost() throws {
        guard ProcessInfo.processInfo.environment["ROAMTTY_TEST_HOST"] != nil else { throw XCTSkip("A live SSH fixture is required") }
        let host = app.buttons["host-UI Live Host"]
        XCTAssertTrue(host.waitForExistence(timeout: 8)); host.tap()
        let trust = app.buttons["auth-confirm"]
        if trust.waitForExistence(timeout: 10) { trust.tap() }
        XCTAssertTrue(app.buttons["host-detail-terminal"].waitForExistence(timeout: 8))
    }

    @discardableResult func openTerminal(preferMosh: Bool = false, directory: String = "/tmp", mode: String = "tmux") throws -> XCUIElement {
        if !app.buttons["host-detail-terminal"].exists { try openHost() }
        app.buttons["host-detail-terminal"].tap()
        let launch = app.buttons["launch-session"]
        XCTAssertTrue(launch.waitForExistence(timeout: 20))
        app.segmentedControls["launch-mode"].buttons[mode].tap()
        let folder = app.textFields["launch-directory"]
        replace(folder, with: directory); folder.typeText("\n")
        let mosh = app.switches["launch-mosh"]
        XCTAssertTrue(mosh.waitForExistence(timeout: 5))
        if (mosh.value as? String == "1") != preferMosh { mosh.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
        XCTAssertEqual(mosh.value as? String, preferMosh ? "1" : "0")
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: launch)
        waitForExpectations(timeout: 25); launch.tap()
        let surface = app.descendants(matching: .any)["terminal-surface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["已连接"].waitForExistence(timeout: 20))
        return surface
    }

    func openTools() {
        if app.buttons["terminal-commands"].exists { return }
        let surface = app.descendants(matching: .any)["terminal-surface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 8))
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        let ghost = app.buttons["terminal-ghost"]
        XCTAssertTrue(ghost.waitForExistence(timeout: 3)); ghost.tap()
        XCTAssertTrue(app.buttons["terminal-commands"].waitForExistence(timeout: 3))
    }

    @discardableResult func runCommand(_ text: String) throws -> XCUIElement {
        openTools(); app.buttons["terminal-commands"].tap()
        let draft = app.textViews["command-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 8)); replace(draft, with: text)
        app.buttons["command-run"].tap()
        let surface = app.descendants(matching: .any)["terminal-surface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        return surface
    }

    func waitForOutput(_ text: String, surface: XCUIElement, timeout: Double = 20) {
        // SwiftTerm's buffer export inserts a newline after every visual row,
        // including soft wraps. Match remote markers across those display rows.
        let rendered = NSPredicate { element, _ in
            guard let value = (element as? XCUIElement)?.value as? String else { return false }
            return value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "").contains(text)
        }
        expectation(for: rendered, evaluatedWith: surface).expectationDescription = "Terminal output contains \(text)"
        waitForExpectations(timeout: timeout)
    }

    func replace(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.exists); field.tap()
        let old = field.value as? String ?? ""
        if !old.isEmpty && old != field.placeholderValue {
            // iOS typeText inserts arrow-key glyphs literally. Use the native edit menu
            // to select the entire value, including text beyond a long field's viewport.
            field.press(forDuration: 1.1)
            let selectAll = app.menuItems.matching(NSPredicate(format: "label == 'Select All' OR label == '全选'")).firstMatch
            let selectAllButton = app.buttons.matching(NSPredicate(format: "label == 'Select All' OR label == '全选'")).firstMatch
            if selectAll.waitForExistence(timeout: 1) { selectAll.tap() }
            else if selectAllButton.exists { selectAllButton.tap() }
            else {
                field.doubleTap()
                if selectAll.waitForExistence(timeout: 1) { selectAll.tap() }
                else if selectAllButton.exists { selectAllButton.tap() }
            }
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "Replacing an input must remove its entire previous value")
    }

    func capture(_ name: String) {
        // The application crop can use stale portrait bounds after rotation.
        // Preserve the actual display, including native picker presentation.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
