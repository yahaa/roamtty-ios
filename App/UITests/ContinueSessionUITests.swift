import XCTest

final class ContinueSessionUITests: RoamttyLiveUITestCase {
    /// 新建会话 › 继续会话 lists the tmux sessions on the one host and attaches the tapped one; tapping it again opens
    /// the card it already has instead of a second one.
    func testContinueSessionAttachesARunningTmuxSession() throws {
        let name = "roamtty-ui-continue-" + UUID().uuidString.prefix(8).lowercased()
        let surface = try openTerminal()
        let created = "CONTINUE_" + "CREATED"
        try runCommand("tmux new-session -d -s \(name) -c /tmp && printf '%s\\n' '\(created)'")
        waitForOutput(created, surface: surface)
        leaveTerminal()
        let before = Set(homeSessionCards().allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(before.count, 1)

        openContinueSheet()
        let row = app.buttons["continue-tmux-\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The detached session is listed")
        capture("继续会话 lists the running tmux sessions")
        row.tap()
        let attached = app.descendants(matching: .any)["terminal-surface"].firstMatch
        XCTAssertTrue(attached.waitForExistence(timeout: 20))
        waitForConnected(timeout: 25)
        try runCommand("tmux display-message -p 'ATTACHED_#S'")
        waitForOutput("ATTACHED_" + name, surface: attached)
        leaveTerminal()
        let after = Set(homeSessionCards().allElementsBoundByIndex.map(\.identifier))
        XCTAssertEqual(after.count, 2, "Continuing a session adds its card")

        // Already open: the row is badged and opens that card, adding none.
        openContinueSheet()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue(row.staticTexts.matching(NSPredicate(format: "label == '已打开' OR label == 'Open'")).firstMatch.exists)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal-surface"].firstMatch.waitForExistence(timeout: 20))
        waitForConnected(timeout: 25)
        let again = try runCommand("tmux display-message -p 'AGAIN_#S'")
        waitForOutput("AGAIN_" + name, surface: again)
        leaveTerminal()
        XCTAssertEqual(Set(homeSessionCards().allElementsBoundByIndex.map(\.identifier)), after, "An open session is not attached twice")

        // The launch sheet's tmux tab shares the list: the session is badged, and attaching it opens the same card.
        try openHost()
        app.buttons["host-detail-terminal"].tap()
        let source = app.segmentedControls["launch-source"]
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.buttons.element(boundBy: 1).tap()
        let launchRow = app.buttons["launch-tmux-\(name)"]
        XCTAssertTrue(launchRow.waitForExistence(timeout: 20))
        XCTAssertTrue(launchRow.staticTexts.matching(NSPredicate(format: "label == '已打开' OR label == 'Open'")).firstMatch.exists)
        launchRow.tap()
        let attach = app.buttons["launch-attach"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: attach)
        waitForExpectations(timeout: 10)
        capture("The launch sheet's tmux tab")
        attach.tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal-surface"].firstMatch.waitForExistence(timeout: 20))
        waitForConnected(timeout: 25)
        closeTerminal()
        XCTAssertEqual(Set(sessionCards.allElementsBoundByIndex.map(\.identifier)), before, "Closing ends the continued session's card only")
    }

    /// With only the fixture host saved, 继续会话 skips the host step.
    private func openContinueSheet() {
        showSessionsTab()
        let add = app.buttons["add-session"]
        XCTAssertTrue(add.waitForExistence(timeout: 8)); add.tap()
        let pick = app.buttons["new-session-pick-continue"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5)); pick.tap()
        XCTAssertTrue(app.descendants(matching: .any)["continue-sheet"].firstMatch.waitForExistence(timeout: 5))
    }
}
