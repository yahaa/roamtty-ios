import Foundation
import XCTest

final class CommandHistoryUITests: RoamttyLiveUITestCase {
    func testRemoteHistoryRefreshFilterRunAndSavedCommandSurviveRelaunch() throws {
        let surface = try openTerminal(mode: "SSH")
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let executed = "HISTORY_EXECUTED_" + token
        let command = emit(executed)
        let prepared = "HISTORY_PREPARED_" + token

        // Only this shell disables automatic history writes. The app's separate SSH
        // history reader still reads the real user's ~/.bash_history. The fixture is
        // one UUID-owned byte record; cleanup removes that exact record and no others.
        let record = Data(("\n" + command + "\n").utf8).base64EncodedString()
        let seed = """
        import base64, os
        from pathlib import Path
        path = Path.home() / '.bash_history'
        with path.open('ab') as history:
            history.write(base64.b64decode('\(record)'))
            history.flush()
            os.fsync(history.fileno())
        print('\(prepared)', flush=True)
        """
        try runCommand("unset HISTFILE; " + python(seed))
        waitForOutput(prepared, surface: surface)

        openCommands()
        let search = app.textFields["history-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        // Noncontiguous characters require the real fuzzy filter, rather than a
        // full-string match against a test-only row.
        let fuzzy = String(token.enumerated().filter { $0.offset.isMultiple(of: 3) }.map(\.element)).lowercased()
        replace(search, with: fuzzy)
        let refresh = app.buttons["history-refresh"]
        waitUntilEnabled(refresh); refresh.tap(); waitUntilEnabled(refresh)
        let remote = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-command-' AND label == %@", command)).firstMatch
        XCTAssertTrue(remote.waitForExistence(timeout: 15), "Refresh must load the fixture from actual remote shell history")
        XCTAssertEqual(app.staticTexts["history-source"].label.lowercased(), "~/.bash_history")
        replace(search, with: "absent-" + UUID().uuidString)
        XCTAssertFalse(remote.exists, "A nonmatching query must hide the remote history row")
        replace(search, with: fuzzy)
        XCTAssertTrue(remote.waitForExistence(timeout: 8)); remote.tap()
        XCTAssertEqual(app.textViews["command-draft"].value as? String, command)
        app.buttons["command-run"].tap()
        waitForOutput(executed, surface: surface)

        let draft = openCommands()
        replace(draft, with: command)
        localizedButton("保存", "Save").tap()
        replace(app.textFields["history-search"], with: fuzzy)
        let saved = savedCommand(command)
        XCTAssertTrue(saved.waitForExistence(timeout: 8), "Saving must create a separate saved-command row")
        capture("Remote history command executed and saved")
        app.buttons["command-done"].tap()

        let cleaned = "HISTORY_CLEANED_" + token
        let cleanup = """
        import base64, os
        from pathlib import Path
        owned = base64.b64decode('\(record)')
        path = Path.home() / '.bash_history'
        with path.open('r+b') as history:
            original = history.read()
            assert original.count(owned) == 1
            remaining = original.replace(owned, b'', 1)
            history.seek(0)
            history.write(remaining)
            history.truncate()
            history.flush()
            os.fsync(history.fileno())
        assert owned not in path.read_bytes()
        print('\(cleaned)', flush=True)
        """
        try runCommand(python(cleanup)); waitForOutput(cleaned, surface: surface)
        closePlainTerminal()
        app.terminate(); app.launch()

        let resumed = try openTerminal(mode: "SSH")
        let ready = "SAVED_SESSION_" + token
        try runCommand("unset HISTFILE; " + emit(ready)); waitForOutput(ready, surface: resumed)
        openCommands()
        // Sparse fuzzy matching was exercised before cleanup. Match the whole
        // owned command here so unrelated remote history cannot satisfy it.
        replace(app.textFields["history-search"], with: command)
        let restored = savedCommand(command)
        XCTAssertTrue(restored.waitForExistence(timeout: 15), "A saved command must survive app relaunch independently of remote history")
        let refreshed = app.buttons["history-refresh"]
        waitUntilEnabled(refreshed); refreshed.tap(); waitUntilEnabled(refreshed)
        let loaded = app.staticTexts["history-source"]
        // With the keyboard open, this native lazy List initially exposes only
        // Saved and its row. Reveal the remote section before asserting absence;
        // an offscreen row must not masquerade as successful remote cleanup.
        try revealCommandListElement(loaded, scrollingDown: true)
        let emptyHistory = app.staticTexts.matching(NSPredicate(format: "label == '没有匹配的 shell 历史命令' OR label == 'No matching shell history commands' OR label == '无法读取可用的 bash 或 zsh 历史。' OR label == 'No usable bash or zsh history is available.'")).firstMatch
        try revealCommandListElement(emptyHistory, scrollingDown: true)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-command-' AND label == %@", command)).firstMatch.exists)
        try revealCommandListElement(restored, scrollingDown: false)
        restored.tap()
        XCTAssertEqual(app.textViews["command-draft"].value as? String, command)
        app.buttons["command-run"].tap()
        waitForOutput(executed, surface: resumed)
        capture("Persisted saved command runs after remote fixture cleanup and relaunch")

        openCommands()
        replace(app.textFields["history-search"], with: command)
        let removed = savedCommand(command)
        XCTAssertTrue(removed.waitForExistence(timeout: 8)); removed.swipeLeft()
        localizedButton("删除", "Delete").tap()
        waitUntilGone(removed)
        app.buttons["command-done"].tap()
        closePlainTerminal()
    }

    func testNativeTerminalSelectionCopyAndClipboardPasteReachRemoteOnce() throws {
        let surface = try openTerminal(mode: "SSH")
        let token = String(UUID().uuidString.prefix(8))
        let payload = "CLIPBOARD_" + token
        // Clear only this terminal's screen and scrollback, then copy its real
        // selected rendered text. The test never reads a pre-existing clipboard.
        try runCommand("printf '\\033[3J\\033[2J\\033[H'; " + emit(payload))
        waitForOutput(payload, surface: surface)
        openTools()
        let pin = app.buttons["terminal-pin-tools"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5)); pin.tap()
        let dock = app.scrollViews["terminal-dock"]
        let select = dock.buttons.matching(NSPredicate(format: "label == '选择' OR label == 'Select'")).firstMatch
        let copy = dock.buttons.matching(NSPredicate(format: "label == '复制' OR label == 'Copy'")).firstMatch
        XCTAssertTrue(select.isHittable); select.tap()
        capture("Native terminal selection")
        XCTAssertTrue(copy.isHittable); copy.tap()

        let draft = openCommands()
        draft.tap(); draft.press(forDuration: 1.1)
        tapNativePaste()
        let copied = try XCTUnwrap(draft.value as? String)
        XCTAssertTrue(copied.contains(payload), "Native Copy must publish the selected terminal text")
        XCTAssertLessThan(copied.utf8.count, 4096, "The cleared test terminal must contain only a small owned payload and prompt")
        XCTAssertTrue(copied.unicodeScalars.allSatisfy { $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32 }, "Selection copies rendered text, never terminal control sequences")
        app.buttons["command-done"].tap()

        // Expected bytes come from the clipboard content just exposed through the
        // native text editor, with the terminal's documented newline convention.
        let normalized = copied.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        let expected = Data(normalized.utf8)
        XCTAssertFalse(expected.isEmpty)
        let prefix = "NATIVE_PASTE_" + token
        try runCommand(byteReceiver(prefix: prefix, count: expected.count))
        waitForOutput(prefix + "_READY", surface: surface)
        openTools()
        let paste = app.scrollViews["terminal-dock"].buttons.matching(NSPredicate(format: "label == '粘贴' OR label == 'Paste'")).firstMatch
        XCTAssertTrue(paste.isHittable); paste.tap()
        if copied.contains("\n") || copied.contains("\r") {
            let send = app.alerts.firstMatch.buttons.matching(identifier: "terminal-paste-send").firstMatch
            XCTAssertTrue(send.waitForExistence(timeout: 5), "Native multiline clipboard paste must use the same confirmation as other input")
            send.tap()
        }
        waitForOutput(prefix + "_BYTES=" + expected.map { String(format: "%02x", $0) }.joined() + "_END", surface: surface)
        capture("Actual clipboard bytes reached remote PTY exactly once")
        closePlainTerminal()
    }

    @discardableResult private func openCommands() -> XCUIElement {
        openTools(); app.buttons["terminal-commands"].tap()
        let draft = app.textViews["command-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 8))
        return draft
    }

    private func savedCommand(_ command: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH 'history-command-')", command)).firstMatch
    }

    private func revealCommandListElement(_ element: XCUIElement, scrollingDown: Bool) throws {
        for _ in 0..<12 {
            let list = try commandList()
            var visible = list.frame.intersection(app.frame)
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists { visible.size.height = max(0, min(visible.maxY, keyboard.frame.minY) - visible.minY) }
            if element.exists && element.isHittable && visible.contains(element.frame) { return }
            guard visible.height > 60 else { XCTFail("The command list must have visible space above the keyboard"); return }
            // With the keyboard open the list is only about 130pt tall. A full
            // swipe flings its short section header past the viewport in one step.
            let distance = min(32, visible.height * 0.25)
            let direction: CGFloat = scrollingDown ? 1 : -1
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY + direction * distance / 2))
            let end = origin.withOffset(CGVector(dx: visible.midX, dy: visible.midY - direction * distance / 2))
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            waitForCommandListLayout(list)
        }
        let list = try commandList()
        XCTAssertTrue(element.exists && element.isHittable && list.frame.contains(element.frame), "The command section must be visibly reached before checking or selecting it")
    }

    private func waitForCommandListLayout(_ list: XCUIElement) {
        var previousFrames: [CGRect]?
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard list.exists else { return false }
            let bounds = list.frame
            let frames = [bounds] + list.cells.allElementsBoundByIndex.map(\.frame).filter { $0.intersects(bounds) }
            defer { previousFrames = frames }
            return previousFrames == frames
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 4), .completed, "Command rows must settle after a short scroll")
    }

    private func commandList() throws -> XCUIElement {
        // The keyboard's suggestion strip is also a CollectionView and may be
        // first in the app query. E2 sent every swipe to that 55pt strip. Use the
        // actual list's identifier, or its tagged wrapper on another iOS version.
        let identifier = "command-history-list"
        let native = app.collectionViews.matching(identifier: identifier).firstMatch
        if native.waitForExistence(timeout: 5) { return native }
        let wrapper = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(wrapper.exists, "The command-history list must be present")
        let lists = wrapper.collectionViews.allElementsBoundByIndex
        XCTAssertEqual(lists.count, 1, "The tagged command list must contain exactly one native scrollable list")
        return try XCTUnwrap(lists.first)
    }

    private func localizedButton(_ chinese: String, _ english: String) -> XCUIElement {
        let button = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", chinese, english)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        return button
    }

    private func tapNativePaste() {
        let predicate = NSPredicate(format: "label == '粘贴' OR label == 'Paste'")
        let menuItem = app.menuItems.matching(predicate).firstMatch
        if menuItem.waitForExistence(timeout: 2) { menuItem.tap() }
        else {
            let button = app.buttons.matching(predicate).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 3), "The native text edit menu must offer Paste after Copy")
            button.tap()
        }
    }

    private func waitUntilEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isEnabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }

    private func waitUntilGone(_ element: XCUIElement) {
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 8), .completed)
    }

    private func closePlainTerminal() {
        app.buttons["terminal-close"].tap()
        let close = app.buttons.matching(identifier: "terminal-close-confirm").firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
        XCTAssertTrue(app.buttons["host-detail-terminal"].waitForExistence(timeout: 8))
    }

    private func emit(_ value: String) -> String {
        let middle = value.index(value.startIndex, offsetBy: value.count / 2)
        return "printf '%s' " + quote(String(value[..<middle])) + "; printf '%s\\n' " + quote(String(value[middle...]))
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private func python(_ source: String) -> String { "python3 -u -c \"import base64; exec(base64.b64decode('" + Data(source.utf8).base64EncodedString() + "'))\"" }

    private func byteReceiver(prefix: String, count: Int) -> String {
        python("""
        import os, select, termios, time, tty
        saved = termios.tcgetattr(0)
        received = bytearray()
        try:
            tty.setraw(0)
            os.write(1, b'\\x1b[?2004l')
            print('\\r\\n\(prefix)_READY', flush=True)
            deadline = time.monotonic() + 90
            while len(received) < \(count) and time.monotonic() < deadline:
                if select.select([0], [], [], 1)[0]:
                    chunk = os.read(0, \(count) - len(received))
                    if not chunk:
                        break
                    received.extend(chunk)
            if select.select([0], [], [], 0.3)[0]:
                received.extend(os.read(0, 4096))
        finally:
            termios.tcsetattr(0, termios.TCSADRAIN, saved)
        print('\\r\\n\(prefix)_BYTES=' + received.hex() + '_END', flush=True)
        """)
    }
}
