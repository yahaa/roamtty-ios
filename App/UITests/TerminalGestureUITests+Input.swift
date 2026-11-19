import Foundation
import XCTest

/// Paste, reconnecting and the keyboard's delete key.
extension TerminalGestureUITests {
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
        XCTAssertTrue(reconnect.waitForExistence(timeout: 20))
        // The notice says what happened; the raw error waits behind 查看详情 (roamtty #277).
        XCTAssertTrue(app.staticTexts["terminal-connection-summary"].exists)
        let details = app.buttons["terminal-connection-details"]
        if details.exists {
            XCTAssertFalse(app.staticTexts["terminal-notice"].exists)
            details.tap()
            XCTAssertTrue(app.staticTexts["terminal-notice"].waitForExistence(timeout: 3))
        }
        capture("Connection notice with its details")
        reconnect.tap()
        XCTAssertTrue(phase("已连接").waitForExistence(timeout: 20))
        let resumed = try runCommand("printf 'RECONNECT_'; printf 'VERIFIED\\n'")
        waitForOutput("RECONNECT_VERIFIED", surface: resumed)
        XCTAssertFalse((resumed.value as? String ?? "").contains("BRACKETED_BYTES"), "A replacement session must have a fresh renderer and must not replay old input")
        capture("Plain SSH reconnected after server closed the shell")
        closePlainTerminal()
    }

    /// The lines here come through the prompt editor, so SwiftTerm's input buffer holds none of them, as after a paste:
    /// the keyboard must still repeat a held delete, and the host's line editor shows what each press did.
    func testHoldingKeyboardDeleteClearsARemoteLineAndATapDeletesOneCharacter() throws {
        let surface = try openTerminal(mode: "SSH")
        func stage(_ line: String) {
            typeIntoTerminal(line)
            app.buttons.matching(NSPredicate(format: "label == '收起' OR label == 'Hide'")).firstMatch.tap()
            let escape = app.buttons["cursor-escape"]
            XCTAssertTrue(escape.waitForExistence(timeout: 6))
            surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: escape.frame.midY - surface.frame.minY)).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        }
        let delete = app.keyboards.firstMatch.keys.matching(NSPredicate(format: "label IN {'delete', '删除', 'Delete'}")).firstMatch

        // Left in place, this prefix stops the command after it from printing anything.
        stage("false && ")
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.press(forDuration: 2.5)
        surface.typeText("echo HOLD_$((40+2))\n")
        waitForOutput("HOLD_42", surface: surface)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Clearing must leave the keyboard up")

        // The trailing backslash keeps the line open until one tap removes it, and only it.
        stage("echo TAP_$((40+2)) \\")
        delete.tap()
        surface.typeText("\n")
        waitForOutput("TAP_42", surface: surface)

        // A press too short to be a hold only deletes: the rest of the line still runs.
        stage("echo SHORT_$((40+2)) \\")
        delete.press(forDuration: 0.3)
        surface.typeText("\n")
        waitForOutput("SHORT_42", surface: surface)
    }

    func terminalColumns(_ surface: XCUIElement) throws -> Int {
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

    func closePlainTerminal() {
        closeTerminal()
        XCTAssertEqual(homeSessionCards().count, 0, "Explicitly closing plain SSH must remove its session card")
    }

    /// A small editor drawn like Claude Code's input: an output row, a ─ rule, three input rows, a rule and a status line
    /// at the bottom. ↑/↓ keep the column like Claude Code; ←/→ move one character, a wide one included. The status line
    /// shows the phase and how many sizes it has seen, the cursor (input row, character) and how many arrows arrived.
    func boxEditor() -> String {
        let source = """
        import os, select, termios, time, tty
        lines = ['\\u276f first line abc', '  second', '  third \\u4f60\\u597d tail']
        def w(ch): return 2 if '\\u4e00' <= ch <= '\\u9fff' else 1
        line, idx, sticky, keys, sizes, phase, since, size = 2, len(lines[2]), None, 0, 0, 'CAL', 0, None
        def cells(l, i): return sum(w(c) for c in lines[l][:i])
        def at(l, col):
            i = c = 0
            while i < len(lines[l]) and c + w(lines[l][i]) <= col:
                c += w(lines[l][i]); i += 1
            return i
        def draw():
            rows, cols = size
            top = rows - 7
            out = ['\\x1b[2J']
            def put(r, text): out.append('\\x1b[%d;1H%s' % (r + 1, text))
            put(top, 'OUTPUT_ABOVE_THE_BOX')
            put(top + 1, '\\u2500' * cols)
            for k, text in enumerate(lines): put(top + 2 + k, text)
            put(top + 5, '\\u2500' * cols)
            put(rows - 1, 'EDITOR_%s_%d AT_%d_%d KEYS_%d SIZE_%dx%d' % (phase, sizes, line, idx, keys, rows, cols))
            out.append('\\x1b[%d;1H' % (top + 1) if phase == 'CAL' else '\\x1b[%d;%dH' % (top + 3 + line, cells(line, idx) + 1))
            os.write(1, ''.join(out).encode())
        saved = termios.tcgetattr(0)
        buf = b''
        try:
            tty.setraw(0)
            deadline = time.monotonic() + 300
            while time.monotonic() < deadline:
                now = tuple(reversed(os.get_terminal_size(0)))
                if now != size:
                    size, sizes, phase, since = now, sizes + 1, 'CAL', time.monotonic(); draw()
                if phase == 'CAL' and time.monotonic() - since > 3:
                    phase = 'READY'; draw()
                if not select.select([0], [], [], 0.1)[0]:
                    continue
                buf += os.read(0, 256)
                while buf:
                    if buf[:1] == b'q':
                        deadline = 0; break
                    if buf[:1] == b'\\x1b' and len(buf) < 3:
                        break
                    if buf[:1] != b'\\x1b' or buf[1:2] not in (b'[', b'O'):
                        buf = buf[1:]; continue
                    key, buf = buf[2:3], buf[3:]
                    keys += 1
                    if phase != 'READY':
                        continue
                    if key in (b'A', b'B'):
                        if sticky is None: sticky = cells(line, idx)
                        line = max(0, min(2, line + (-1 if key == b'A' else 1))); idx = at(line, sticky)
                    elif key in (b'C', b'D'):
                        sticky = None; idx = max(0, min(len(lines[line]), idx + (1 if key == b'C' else -1)))
                draw()
        finally:
            termios.tcsetattr(0, termios.TCSADRAIN, saved)
        """
        return "python3 -u -c \"import base64; exec(base64.b64decode('\(Data(source.utf8).base64EncodedString())'))\""
    }

    /// A stand-in for Codex's interface: alternate screen, any-event SGR mouse tracking, a status redrawn ten times a
    /// second, and a count of the wheel events and the last line it was sent.
    func fakeMouseAgent() -> String {
        let source = """
        import os, re, select, termios, tty
        saved = termios.tcgetattr(0)
        wheel, line, sent, pending, frame = 0, '', '', b'', 0
        try:
            tty.setraw(0)
            os.write(1, b'\\x1b[?1049h\\x1b[?1003h\\x1b[?1006h\\x1b[2J\\x1b[1;1HAGENT_READY')
            while line != 'quit':
                if select.select([0], [], [], 0.1)[0]:
                    pending += os.read(0, 4096)
                    wheel += len(re.findall(rb'\\x1b\\[<6[45];\\d+;\\d+M', pending))
                    typed = re.sub(rb'\\x1b\\[<\\d+;\\d+;\\d+[Mm]', b'', pending).decode(errors='ignore')
                    pending = b''
                    for character in typed:
                        if character in '\\r\\n': sent, line = line, ''
                        else: line += character
                frame += 1
                os.write(1, ('\\x1b[3;1HWHEEL=%05d\\x1b[K\\x1b[5;1HSENT=%s\\x1b[K\\x1b[7;1HWorking %d\\x1b[K\\x1b[12;1H> %s\\x1b[K' % (wheel, sent, frame, line)).encode())
        finally:
            os.write(1, b'\\x1b[?1006l\\x1b[?1003l\\x1b[?1049l')
            termios.tcsetattr(0, termios.TCSADRAIN, saved)
        """
        return "python3 -u -c \"import base64; exec(base64.b64decode('\(Data(source.utf8).base64EncodedString())'))\""
    }

    func receiver(prefix: String, count: Int, bracketed: Bool = false, reportProgress: Bool = false) -> String {
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
