import XCTest

final class SessionRenameUITests: RoamttyLiveUITestCase {
    /// Long press → 重命名 names the card; the terminal's switcher uses the name; clearing it gives the automatic one back.
    func testRenameCardFromItsMenuAndClearIt() throws {
        try openTerminal(directory: "/tmp", mode: "tmux")
        leaveTerminal()
        let card = try XCTUnwrap(homeSessionCards().allElementsBoundByIndex.first)
        let id = String(card.identifier.dropFirst("home-session-".count))
        let title = app.descendants(matching: .any)["home-session-title-" + id].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        let automatic = title.label

        card.press(forDuration: 1)
        let rename = app.buttons["home-session-rename-" + id]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["home-session-close-" + id].exists)
        capture("Session card menu")
        rename.tap()

        let input = app.textFields["home-session-rename-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, automatic)
        // Nothing changed yet, so there is nothing to save.
        XCTAssertFalse(app.buttons["home-session-rename-save"].isEnabled)
        capture("Rename dialog")
        // The name starts selected, so typing replaces it.
        input.typeText("logs tail")
        XCTAssertEqual(input.value as? String, "logs tail")
        app.buttons["home-session-rename-save"].tap()
        XCTAssertFalse(input.waitForExistence(timeout: 1))
        XCTAssertTrue(waitFor(title, label: "logs tail"))
        capture("Renamed card")

        card.tap()
        let switcher = app.buttons["session-switcher"]
        openTools()
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        XCTAssertTrue(switcher.label.contains("logs tail"), switcher.label)
        switcher.tap()
        let back = app.buttons.matching(NSPredicate(format: "label == '返回主机详情' OR label == 'Back to host details'")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3)); back.tap()

        let renamed = try XCTUnwrap(homeSessionCards().allElementsBoundByIndex.first { $0.identifier == "home-session-" + id })
        renamed.press(forDuration: 1)
        XCTAssertTrue(app.buttons["home-session-rename-" + id].waitForExistence(timeout: 3))
        app.buttons["home-session-rename-" + id].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        app.buttons["home-session-rename-clear"].tap()
        XCTAssertTrue(app.staticTexts["home-session-rename-help"].waitForExistence(timeout: 2))
        capture("Rename dialog cleared")
        app.buttons["home-session-rename-save"].tap()
        XCTAssertTrue(waitFor(title, label: automatic))

        renamed.press(forDuration: 1)
        let close = app.buttons["home-session-close-" + id]
        XCTAssertTrue(close.waitForExistence(timeout: 3)); close.tap()
    }

    private func waitFor(_ element: XCUIElement, label: String) -> Bool {
        let done = expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)
        return XCTWaiter.wait(for: [done], timeout: 5) == .completed
    }
}
