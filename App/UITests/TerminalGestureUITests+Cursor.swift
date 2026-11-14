import Foundation
import XCTest

/// The cursor row, the keyboard and taps inside a multi-line input.
extension TerminalGestureUITests {
    func testCursorRowTapAndDoubleTapAfterKeyboardIsPutAway() throws {
        let surface = try openTerminal()
        let escape = app.buttons["cursor-escape"]
        XCTAssertTrue(escape.waitForExistence(timeout: 6))
        func tapCursorRow() {
            // The cursor row shows Esc, or Enter for a few seconds after typing.
            let row = app.buttons.matching(NSPredicate(format: "identifier IN {'cursor-escape', 'cursor-enter'}")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 6))
            surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: row.frame.midY - surface.frame.minY)).tap()
        }
        tapCursorRow()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Fill the screen so the cursor sits on the bottom row, as in a working shell.
        surface.typeText("seq 1 120; echo TYPED_\\\nDONE\n")
        waitForOutput("TYPED_DONE", surface: surface)
        let hide = app.buttons["cursor-hide-keyboard"]
        // Enter puts the keyboard away by itself after 15 s.
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 20))
        capture("Keyboard put away after typing")
        tapCursorRow()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { saveFailureScreenshot("cursorRowAfterAutoHide") }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "A tap on the cursor row must open the keyboard after it hid itself")
        XCTAssertTrue(hide.waitForExistence(timeout: 5)); hide.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        // Tapping the cursor's line again brings the keyboard back.
        tapCursorRow()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { saveFailureScreenshot("cursorRowAfterHide") }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "A tap on the cursor row must open the keyboard again")
        // A reading tap away from the cursor puts it away; a double tap then brings the pet's arrows.
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.1)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        tapCursorRow()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { saveFailureScreenshot("cursorRowAfterReadingTap") }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "A tap on the cursor row must open the keyboard after a reading tap")
        hide.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).doubleTap()
        if !app.buttons["pet-arrow-up"].waitForExistence(timeout: 3) { saveFailureScreenshot("doubleTapArrows") }
        XCTAssertTrue(app.buttons["pet-arrow-up"].exists, "A double tap must bring the pet's arrow keys")
    }

    /// Claude Code's /usage panel hides the cursor and parks it on its tab bar near the top; the line the
    /// user typed /usage on must still bring the keyboard back once it was put away.
    func testTypedLineOpensKeyboardWhileHostHidesCursor() throws {
        let surface = try openTerminal(mode: "SSH")
        let row = app.buttons.matching(NSPredicate(format: "identifier IN {'cursor-escape', 'cursor-enter'}")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: row.frame.midY - surface.frame.minY)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Typing a /usage line, then Enter, replaces it with a panel whose hidden cursor sits on row 4.
        surface.typeText("printf '\\033[?1049h\\033[2J\\033[30;1H/usage'; read -r x; printf '\\033[2J\\033[HPANEL_\\nSHOWN\\033[?25l\\033[4;20H'; read -r y\n")
        sleep(2); XCTAssertTrue(row.waitForExistence(timeout: 6))
        let typedLine = row.frame.midY - surface.frame.minY
        surface.typeText("\n")
        waitForOutput("PANEL_SHOWN", surface: surface)
        let hide = app.buttons["cursor-hide-keyboard"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5)); hide.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: typedLine)).tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { saveFailureScreenshot("hiddenCursorTypedLine") }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "With the cursor hidden, a tap on the typed line must open the keyboard")
    }

    func testKeyboardReopenedAfterEnterStaysUp() throws {
        let surface = try openTerminal()
        func tapCursorRow() {
            // The cursor row shows Esc, or Enter for a few seconds after typing.
            let row = app.buttons.matching(NSPredicate(format: "identifier IN {'cursor-escape', 'cursor-enter'}")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 6))
            surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: row.frame.midY - surface.frame.minY)).tap()
        }
        tapCursorRow()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        surface.typeText("seq 1 120; echo REOPEN_\\\nDONE\n")
        waitForOutput("REOPEN_DONE", surface: surface)
        // A reading tap puts the keyboard away before Enter's own 15 s timer does.
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.1)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        tapCursorRow()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // That earlier timer must not take the keyboard the user just asked for away again.
        sleep(16)
        if !app.keyboards.firstMatch.exists { saveFailureScreenshot("keyboardTakenAway") }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "The keyboard opened from the cursor row must stay up")
    }

    /// As on Android, a tap on typed text moves the cursor there: along the cursor's row with ←/→, and in a multi-line
    /// input box (Claude Code's, between ─ rules) up or down first, then along once the app has echoed the cursor.
    func testTapMovesTheCursorInsideAMultiLineInput() throws {
        let surface = try openTerminal()
        try runCommand(boxEditor())
        // The editor counts the sizes it has drawn at: putting the prompt editor or the keyboard away resizes it.
        func status(_ pattern: String) -> Int? {
            let value = (surface.value as? String ?? "").replacingOccurrences(of: "\n", with: "")
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).last,
                  let range = Range(match.range(at: 1), in: value) else { return nil }
            return Int(value[range])
        }
        func sizes(_ phase: String) -> Int? { status("EDITOR_" + phase + "_([0-9]+)") }
        waitForOutput("EDITOR_READY_", surface: surface)
        let drawn = sizes("READY") ?? 0
        let row = app.buttons.matching(NSPredicate(format: "identifier IN {'cursor-escape', 'cursor-enter'}")).firstMatch
        // Bring the keyboard up first, so the box does not move under the taps. A tap past the typed text sends nothing.
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.9, dy: row.frame.midY - surface.frame.minY)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // The editor parks the cursor on its output row, then on the end of the last input row: the cursor's key
        // follows it, which measures the rows. Cells are measured from the column count, so taps stay near the left.
        // The output row is only the cursor's for the three seconds after a resize, so it is measured while the
        // editor says so, not after a wait that a slow simulator stretches past them.
        var size = 0, output: CGFloat = 0
        let resized = expectation(for: NSPredicate { _, _ in
            if let measuring = sizes("CAL"), measuring > drawn { size = measuring; output = row.frame.midY; return false }
            return size > 0 && sizes("READY") == size
        }, evaluatedWith: surface)
        resized.expectationDescription = "The keyboard resized the editor, which then parked the cursor on its input"
        wait(for: [resized], timeout: 20); sleep(1)
        let last = row.frame.midY, rowHeight = (last - output) / 4
        let value = surface.value as? String ?? ""
        let sizePattern = try NSRegularExpression(pattern: "SIZE_([0-9]+)x([0-9]+)")
        guard let match = sizePattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).last,
              let range = Range(match.range(at: 2), in: value), let columns = Double(value[range]), rowHeight > 4 else {
            return XCTFail("The editor must report its size and the cursor rows must be measurable")
        }
        let cellWidth = surface.frame.width / columns
        // Input rows: 0 "❯ first line abc", 1 "  second", 2 "  third 你好 tail" (row 2 is the cursor's, `last`).
        func tap(column: Double, inputRow: Int) {
            let y = last + CGFloat(inputRow - 2) * rowHeight - surface.frame.minY
            surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: CGFloat(column) * cellWidth, dy: y)).tap()
        }
        // Up two rows: the editor keeps its column (the end of row 0), then 12 ← reach "first".
        tap(column: 4, inputRow: 0)
        waitForOutput("AT_0_4 KEYS_14", surface: surface)
        // Down two rows onto 好: 你 is one ← / → press.
        tap(column: 10, inputRow: 2)
        waitForOutput("AT_2_9 KEYS_21", surface: surface)
        // Along the cursor's own row.
        tap(column: 3, inputRow: 2)
        waitForOutput("AT_2_3 KEYS_27", surface: surface)
        // Past the end of a row stops at its end.
        tap(column: 20, inputRow: 1)
        waitForOutput("AT_1_8 KEYS_33", surface: surface)
        capture("Taps moved the cursor across a multi-line input")
        // Output above the box is not the input: nothing is sent.
        tap(column: 4, inputRow: -2)
        sleep(2)
        XCTAssertEqual(status("KEYS_([0-9]+)"), 33, "A tap on output must send no arrows")
        closeTerminal()
    }
}
