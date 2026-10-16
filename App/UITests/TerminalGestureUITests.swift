import Foundation
import XCTest

final class TerminalGestureUITests: RoamttyLiveUITestCase {
    func testPlainSSHKeyboardPinchAndGestureBytes() throws {
        let surface = try openTerminal(mode: "SSH")
        XCTAssertTrue(terminalTransport.hasPrefix("SSH"))
        // As on Android, a tap on the cursor's line opens the keyboard.
        let escape = app.buttons["cursor-escape"]
        XCTAssertTrue(escape.waitForExistence(timeout: 6))
        surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: escape.frame.midY - surface.frame.minY)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        surface.typeText("printf 'KEYBOARD_'; printf 'VERIFIED\\n'\n")
        waitForOutput("KEYBOARD_VERIFIED", surface: surface)

        let original = try terminalColumns(surface)
        surface.pinch(withScale: 1.4, velocity: 1)
        let enlarged = try terminalColumns(surface)
        XCTAssertLessThan(enlarged, original, "Pinching must resize the actual remote PTY columns")
        capture("Plain SSH keyboard and enlarged terminal font")

        try runCommand(receiver(prefix: "GESTURE", count: 8, reportProgress: true))
        waitForOutput("GESTURE_READY", surface: surface)
        surface.doubleTap()
        waitForOutput("GESTURE_PROGRESS=09", surface: surface)
        let left = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3))
        let right = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3))
        right.press(forDuration: 0.01, thenDragTo: left)
        waitForOutput("GESTURE_PROGRESS=091b5b44", surface: surface)
        left.press(forDuration: 0.01, thenDragTo: right)
        waitForOutput("GESTURE_PROGRESS=091b5b441b5b43", surface: surface)
        XCTAssertTrue(escape.waitForExistence(timeout: 6)); escape.tap()
        waitForOutput("GESTURE_BYTES=091b5b441b5b431b", surface: surface)
        capture("Double tap, horizontal swipes and Escape received by remote PTY")
        closePlainTerminal()
    }

    func testTmuxVerticalSwipeScrollsHistory() throws { try swipeScrollsTmuxHistory(mosh: false) }
    /// mosh resends its modes after every resize; tracking must survive the 1006 reset/set pair.
    func testMoshTmuxVerticalSwipeScrollsHistory() throws { try swipeScrollsTmuxHistory(mosh: true) }
    private func swipeScrollsTmuxHistory(mosh: Bool) throws {
        let surface = try openTerminal(preferMosh: mosh)
        XCTAssertEqual(terminalTransport.hasSuffix("mosh"), mosh)
        try runCommand("seq -f 'HIST_%03g' 1 400")
        waitForOutput("HIST_400", surface: surface)
        // A downward drag sends wheel-up events; tmux enters copy-mode and shows earlier lines.
        let upper = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let lower = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        for _ in 0..<2 { upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: 300, thenHoldForDuration: 0.2) }
        let scrolled = NSPredicate { element, _ in !((element as? XCUIElement)?.value as? String ?? "HIST_400").contains("HIST_400") }
        expectation(for: scrolled, evaluatedWith: surface).expectationDescription = "tmux scrolled back through its history"
        waitForExpectations(timeout: 10)
        capture("Vertical swipe scrolled tmux history" + (mosh ? " over mosh" : ""))
        closeTerminal()
    }

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

    func testBracketedPasteAndReconnectAfterRemoteShellExit() throws {
        let surface = try openTerminal(mode: "SSH")
        let payload = "one\ntwo\n"
        let expected = Data(("\u{1b}[200~one\rtwo\r\u{1b}[201~").utf8)
        try runCommand(receiver(prefix: "BRACKETED", count: expected.count, bracketed: true))
        waitForOutput("BRACKETED_READY", surface: surface)
        typeIntoTerminal(payload)
        XCTAssertFalse(app.buttons["terminal-paste-send"].exists, "Bracketed paste must be sent with delimiters without a multiline warning")
        waitForOutput("BRACKETED_BYTES=" + expected.map { String(format: "%02x", $0) }.joined(), surface: surface)
        try runCommand("kill -HUP $$")
        let reconnect = app.buttons["terminal-reconnect"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 20)); reconnect.tap()
        XCTAssertTrue(phase("已连接").waitForExistence(timeout: 20))
        let resumed = try runCommand("printf 'RECONNECT_'; printf 'VERIFIED\\n'")
        waitForOutput("RECONNECT_VERIFIED", surface: resumed)
        XCTAssertFalse((resumed.value as? String ?? "").contains("BRACKETED_BYTES"), "A replacement session must have a fresh renderer and must not replay old input")
        capture("Plain SSH reconnected after server closed the shell")
        closePlainTerminal()
    }

    private func terminalColumns(_ surface: XCUIElement) throws -> Int {
        let token = String(UUID().uuidString.prefix(6))
        try runCommand("set -- $(stty size); printf 'PTY_'; printf '\(token)_%s_%s\\n' \"$1\" \"$2\"")
        let marker = "PTY_" + token + "_"
        waitForOutput(marker, surface: surface)
        let value = surface.value as? String ?? ""
        let regex = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: marker) + "[0-9]+_([0-9]+)")
        guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value), let columns = Int(value[range]) else {
            XCTFail("The remote stty output must contain the PTY column count"); return 0
        }
        return columns
    }

    private func closePlainTerminal() {
        closeTerminal()
        XCTAssertEqual(homeSessionCards().count, 0, "Explicitly closing plain SSH must remove its session card")
    }

    private func receiver(prefix: String, count: Int, bracketed: Bool = false, reportProgress: Bool = false) -> String {
        let source = """
        import os, select, termios, time, tty
        saved = termios.tcgetattr(0)
        received = bytearray()
        try:
            tty.setraw(0)
            os.write(1, b'\\x1b[?1l\\x1b[?2004\(bracketed ? "h" : "l")')
            print('\\r\\n\(prefix)_READY', flush=True)
            deadline = time.monotonic() + 90
            while len(received) < \(count) and time.monotonic() < deadline:
                if select.select([0], [], [], 1)[0]:
                    chunk = os.read(0, \(count) - len(received))
                    if not chunk:
                        break
                    received.extend(chunk)
                    if \(reportProgress ? "True" : "False"):
                        os.write(1, ('\\r\\n\(prefix)_PROGRESS=' + received.hex() + '\\r\\n').encode())
        finally:
            os.write(1, b'\\x1b[?2004l')
            termios.tcsetattr(0, termios.TCSADRAIN, saved)
        print('\\r\\n\(prefix)_BYTES=' + received.hex(), flush=True)
        """
        return "python3 -u -c \"import base64; exec(base64.b64decode('\(Data(source.utf8).base64EncodedString())'))\""
    }
}
