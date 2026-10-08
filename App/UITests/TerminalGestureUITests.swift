import Foundation
import XCTest

final class TerminalGestureUITests: RoamttyLiveUITestCase {
    func testPlainSSHKeyboardPinchAndGestureBytes() throws {
        let surface = try openTerminal(mode: "SSH")
        XCTAssertTrue(app.staticTexts["SSH"].exists)
        XCTAssertFalse(app.staticTexts["tmux"].exists)
        app.buttons["terminal-keyboard"].tap()
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
        let escape = app.buttons["cursor-escape"]
        XCTAssertTrue(escape.waitForExistence(timeout: 6)); escape.tap()
        waitForOutput("GESTURE_BYTES=091b5b441b5b431b", surface: surface)
        capture("Double tap, horizontal swipes and Escape received by remote PTY")
        closePlainTerminal()
    }

    func testBracketedPasteAndReconnectAfterRemoteShellExit() throws {
        let surface = try openTerminal(mode: "SSH")
        let payload = "one\ntwo\n"
        let expected = Data(("\u{1b}[200~one\rtwo\r\u{1b}[201~").utf8)
        try runCommand(receiver(prefix: "BRACKETED", count: expected.count, bracketed: true))
        waitForOutput("BRACKETED_READY", surface: surface)
        openTools(); app.buttons["terminal-commands"].tap()
        let draft = app.textViews["command-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5)); replace(draft, with: payload)
        app.buttons["command-insert"].tap()
        XCTAssertFalse(app.buttons["terminal-paste-send"].exists, "Bracketed paste must be sent with delimiters without a multiline warning")
        waitForOutput("BRACKETED_BYTES=" + expected.map { String(format: "%02x", $0) }.joined(), surface: surface)
        try runCommand("kill -HUP $$")
        let reconnect = app.buttons["terminal-reconnect"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 20)); reconnect.tap()
        XCTAssertTrue(app.staticTexts["已连接"].waitForExistence(timeout: 20))
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
        app.buttons["terminal-close"].tap()
        let confirm = app.buttons.matching(identifier: "terminal-close-confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3)); confirm.tap()
        XCTAssertTrue(app.buttons["host-detail-terminal"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-'")).count, 0, "Explicitly closing plain SSH must remove its session card")
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
