import Foundation
import XCTest

final class TerminalSettingsUITests: RoamttyLiveUITestCase {
    func testTmuxRenameCloseAndAppRelaunchPreserveRemoteShell() throws {
        let surface = try openTerminal()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try runCommand("export ROAMTTY_UI_RECOVERY='\(token)'; printf 'RECOVERY_'; printf 'READY\\n'")
        waitForOutput("RECOVERY_READY", surface: surface)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let session = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-")).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        let identifier = session.identifier
        let recordID = String(identifier.dropFirst("session-".count))
        let title = "Recovery " + String(token.prefix(8))
        app.buttons["rename-session-" + recordID].tap()
        let titleField = app.alerts.firstMatch.textFields.firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 3)); replace(titleField, with: title)
        app.alerts.firstMatch.buttons.matching(identifier: "session-title-save").firstMatch.tap()
        waitFor(NSPredicate(format: "label CONTAINS %@", title), element: app.buttons[identifier])
        app.buttons[identifier].tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
        closeTerminal()
        XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 5), "Closing tmux must retain its session card")

        app.terminate(); app.launch()
        try openHost()
        let restored = app.buttons[identifier]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertTrue(restored.label.contains(title), "The renamed card must survive an app restart")
        restored.tap()
        XCTAssertTrue(app.staticTexts["已连接"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.navigationBars[title].exists)
        let resumed = try runCommand("test \"$ROAMTTY_UI_RECOVERY\" = '\(token)' && { printf 'RECOVERY_'; printf 'PRESERVED\\n'; }")
        waitForOutput("RECOVERY_PRESERVED", surface: resumed)
        capture("Renamed tmux session resumed after app restart")

        closeTerminal()
        app.buttons["close-session-" + recordID].tap()
        let terminate = app.buttons.matching(identifier: "终止远程 tmux 并移除").firstMatch
        XCTAssertTrue(terminate.waitForExistence(timeout: 3)); terminate.tap()
        waitFor(NSPredicate(format: "exists == false"), element: app.buttons[identifier], timeout: 15)
    }

    func testPinnedToolsReserveWidthAndFunctionShortcutsReachRemote() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let surface = try openTerminal()
        let originalWidth = surface.frame.width
        openTools()
        let pin = app.buttons["terminal-pin-tools"]
        XCTAssertTrue(pin.waitForExistence(timeout: 3)); pin.tap()
        waitFor(NSPredicate { _, _ in surface.frame.width < originalWidth - 40 }, element: surface)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["terminal-commands"].exists, "Pinned tools must stay open when touching the terminal")
        XCTAssertLessThan(surface.frame.width, originalWidth - 40)
        capture("Pinned tools reserve terminal columns")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitFor(NSPredicate { _, _ in surface.frame.width > surface.frame.height }, element: surface)
        let dock = app.scrollViews["terminal-dock"]
        for _ in 0..<5 {
            if pin.isHittable { break }
            dock.swipeUp()
        }
        XCTAssertTrue(pin.isHittable)
        XCTAssertTrue(app.buttons["terminal-commands"].isHittable)
        XCTAssertLessThanOrEqual(surface.frame.maxX, pin.frame.minX + 2, "Landscape tools must reserve columns, not cover terminal cells")
        capture("Pinned tools and terminal in landscape")
        XCUIDevice.shared.orientation = .portrait
        waitFor(NSPredicate { _, _ in surface.frame.height > surface.frame.width }, element: surface)
        XCTAssertTrue(pin.isHittable)
        XCTAssertLessThan(surface.frame.width, originalWidth - 40)
        pin.tap()
        waitFor(NSPredicate { _, _ in abs(surface.frame.width - originalWidth) < 2 }, element: surface)
        app.buttons["collapse-dock"].tap()

        try runCommand(rawReader(prefix: "ROAMTTY_KEYS", count: 4))
        waitForOutput("ROAMTTY_KEYS_READY", surface: surface)
        openShortcutRing(surface: surface)
        let functions = app.buttons["pet-fn"]
        XCTAssertTrue(functions.waitForExistence(timeout: 2)); functions.tap()
        let f1 = app.buttons["pet-f1"]
        XCTAssertTrue(f1.waitForExistence(timeout: 2)); f1.tap()
        openShortcutRing(surface: surface)
        let controlC = app.buttons["pet-ctrl-c"]
        XCTAssertTrue(controlC.waitForExistence(timeout: 2)); controlC.tap()
        waitForOutput("ROAMTTY_KEYS_BYTES=1b4f5003", surface: surface)
        capture("F1 and Ctrl+C bytes received over SSH")
    }

    func testMultilinePasteRequiresConfirmationAndCancelSendsNothing() throws {
        let surface = try openTerminal()
        try runCommand(rawReader(prefix: "ROAMTTY_PASTE", count: 11))
        waitForOutput("ROAMTTY_PASTE_READY", surface: surface)
        let payload = "alpha\nbeta\n"
        openCommandDraft(payload)
        app.buttons["command-insert"].tap()
        let cancel = app.alerts.firstMatch.buttons.matching(identifier: "terminal-paste-cancel").firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3), "Unbracketed multiline input must ask before sending")
        capture("Multiline paste confirmation")
        cancel.tap()
        XCTAssertEqual(app.textViews["command-draft"].value as? String, payload)
        app.buttons["command-done"].tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        let noBytes = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "ROAMTTY_PASTE_RECEIVED"), object: surface)
        noBytes.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [noBytes], timeout: 2), .completed, "Cancelling must send no bytes to the waiting remote process")

        openCommandDraft(payload)
        app.buttons["command-insert"].tap()
        let send = app.alerts.firstMatch.buttons.matching(identifier: "terminal-paste-send").firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 3)); send.tap()
        waitForOutput("ROAMTTY_PASTE_BYTES=616c7068610d626574610d", surface: surface)
        XCTAssertFalse(app.buttons["terminal-paste-send"].exists)
        capture("Confirmed paste preserves text and normalizes newlines")
    }

    func testSettingsFontSizeLanguageAndThemePersistAcrossRelaunch() {
        openSettings()
        app.buttons["language-en"].tap()
        app.buttons["theme-light"].tap()
        XCTAssertTrue(app.buttons["language-en"].isSelected)
        XCTAssertTrue(app.buttons["theme-light"].isSelected)
        let font = app.buttons["settings-font"]
        revealSettings(font); font.tap()
        let fira = app.buttons["FiraCode"]
        XCTAssertTrue(fira.waitForExistence(timeout: 3)); fira.tap()
        waitFor(NSPredicate(format: "value == %@", "FiraCode"), element: font)
        let slider = app.sliders["settings-font-size"]
        revealSettings(slider); slider.adjust(toNormalizedSliderPosition: 0.65)
        let fontSize = app.staticTexts["settings-font-size-value"]
        XCTAssertTrue(fontSize.exists)
        let chosenSize = fontSize.label
        XCTAssertNotEqual(chosenSize, "13 pt", "Changing the slider must change the saved font size")
        let hiddenFiles = app.switches["settings-hidden-files"]
        revealSettings(hiddenFiles)
        setSwitch(hiddenFiles, on: true)
        app.buttons["settings-done"].tap()
        XCTAssertEqual(app.staticTexts["hosts-title"].label, "Hosts")
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["hosts-title"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["hosts-title"].label, "Hosts")

        openSettings()
        XCTAssertTrue(app.buttons["language-en"].isSelected)
        XCTAssertTrue(app.buttons["theme-light"].isSelected)
        revealSettings(font)
        XCTAssertEqual(font.value as? String, "FiraCode")
        revealSettings(fontSize)
        XCTAssertEqual(fontSize.label, chosenSize)
        revealSettings(hiddenFiles)
        XCTAssertEqual(hiddenFiles.value as? String, "1")
        capture("Font, size and file settings persisted")
        let scroll = app.scrollViews["settings-scroll"]
        for _ in 0..<5 {
            if settingsVisible(app.buttons["theme-dark"], in: scroll) { break }
            scroll.swipeDown()
        }
        XCTAssertTrue(settingsVisible(app.buttons["theme-dark"], in: scroll))
        app.buttons["theme-dark"].tap(); app.buttons["language-zh"].tap()
        XCTAssertTrue(app.buttons["theme-dark"].isSelected)
        XCTAssertTrue(app.buttons["language-zh"].isSelected)
        app.buttons["settings-done"].tap()
        XCTAssertEqual(app.staticTexts["hosts-title"].label, "主机")
    }

    func testAgentLauncherModesAndInstalledPluginsReflectLiveHost() throws {
        try openHost()
        app.buttons["host-detail-plugins"].tap()
        for name in ["tmux", "mosh"] {
            let installed = app.descendants(matching: .any)["plugin-installed-" + name].firstMatch
            XCTAssertTrue(installed.waitForExistence(timeout: 20), "The live fixture must report \(name) installed")
            XCTAssertFalse(app.buttons["plugin-install-" + name].exists)
        }
        let probe = app.buttons["host-plugins-retry"]
        XCTAssertTrue(probe.isEnabled); probe.tap()
        waitFor(NSPredicate(format: "isEnabled == true"), element: probe, timeout: 20)
        XCTAssertFalse(app.staticTexts["plugin-error"].exists)
        capture("Live tmux and mosh detection")
        app.buttons["plugins-done"].tap()
        app.buttons["host-detail-agent"].tap()
        let agents = app.segmentedControls["launch-agent"]
        let modes = app.segmentedControls["launch-agent-mode"]
        XCTAssertTrue(agents.waitForExistence(timeout: 10))
        agents.buttons["Claude Code"].tap()
        let plan = modes.buttons["计划"]
        XCTAssertTrue(plan.exists); plan.tap(); XCTAssertTrue(plan.isSelected)
        XCTAssertEqual(app.staticTexts["launch-command-preview"].label, "claude --permission-mode plan")
        XCTAssertTrue(app.staticTexts["launch-permission-hint"].label.contains("批准"))
        agents.buttons["Codex"].tap()
        let readOnly = modes.buttons["只读"]
        XCTAssertTrue(readOnly.exists); readOnly.tap(); XCTAssertTrue(readOnly.isSelected)
        XCTAssertEqual(app.staticTexts["launch-command-preview"].label, "codex --sandbox read-only")
        agents.buttons["Grok"].tap(); modes.buttons["YOLO"].tap()
        XCTAssertTrue(modes.buttons["YOLO"].isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["launch-yolo-warning"].firstMatch.exists)
        XCTAssertEqual(app.staticTexts["launch-command-preview"].label, "grok --always-approve")
        modes.buttons["标准"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["launch-yolo-warning"].firstMatch.exists)
        XCTAssertEqual(app.staticTexts["launch-command-preview"].label, "grok")

        let launch = app.buttons["launch-session"]
        let directory = app.textFields["launch-directory"]
        replace(directory, with: "/tmp/roamtty-missing-" + UUID().uuidString)
        XCTAssertFalse(launch.isEnabled, "Editing an unvalidated folder must disable launch")
        app.buttons["launch-open-directory"].tap()
        XCTAssertTrue(app.staticTexts["launch-error"].waitForExistence(timeout: 10))
        XCTAssertFalse(launch.isEnabled, "A failed folder request must not launch in the previous directory")
        replace(directory, with: "/tmp")
        app.buttons["launch-open-directory"].tap()
        waitFor(NSPredicate(format: "isEnabled == true"), element: launch, timeout: 15)
        XCTAssertFalse(app.staticTexts["launch-error"].exists)
        XCTAssertEqual(directory.value as? String, "/tmp")
        capture("Agent modes and validated remote launch directory")
        app.buttons["launch-cancel"].tap()
        XCTAssertTrue(app.buttons["host-detail-agent"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-")).count, 0, "Cancelling the launcher must create no session")
    }

    private func openSettings() {
        XCTAssertTrue(app.buttons["open-drawer"].waitForExistence(timeout: 8)); app.buttons["open-drawer"].tap()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 3)); app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["settings-done"].waitForExistence(timeout: 5))
    }

    private func closeTerminal() {
        app.buttons["terminal-close"].tap()
        let confirm = app.buttons.matching(identifier: "terminal-close-confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3)); confirm.tap()
        XCTAssertTrue(app.buttons["host-detail-terminal"].waitForExistence(timeout: 5))
    }

    private func openShortcutRing(surface: XCUIElement) {
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        let ghost = app.buttons["terminal-ghost"]
        XCTAssertTrue(ghost.waitForExistence(timeout: 3)); ghost.press(forDuration: 0.4)
    }

    private func openCommandDraft(_ text: String) {
        openTools(); app.buttons["terminal-commands"].tap()
        let draft = app.textViews["command-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5)); replace(draft, with: text)
    }

    private func revealSettings(_ element: XCUIElement) {
        let scroll = app.scrollViews["settings-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 3))
        for _ in 0..<5 {
            if settingsVisible(element, in: scroll) { return }
            scroll.swipeUp()
        }
        XCTAssertTrue(settingsVisible(element, in: scroll))
    }

    private func settingsVisible(_ element: XCUIElement, in scroll: XCUIElement) -> Bool {
        guard element.exists && element.isHittable else { return false }
        let frame = scroll.frame.intersection(app.frame)
        let top = max(frame.minY, app.navigationBars.firstMatch.frame.maxY)
        let visible = CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, frame.maxY - top))
        return visible.contains(element.frame)
    }

    private func setSwitch(_ element: XCUIElement, on: Bool) {
        if (element.value as? String == "1") != on { element.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap() }
        XCTAssertEqual(element.value as? String, on ? "1" : "0")
    }

    private func waitFor(_ predicate: NSPredicate, element: XCUIElement, timeout: Double = 5) {
        let check = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [check], timeout: timeout), .completed)
    }

    /// The UI sends every byte through the real PTY. A bounded receiver restores
    /// terminal modes even on timeout; base64 keeps echoed input from containing
    /// the output markers that the tests assert.
    private func rawReader(prefix: String, count: Int) -> String {
        let source = """
        import os, select, termios, time, tty
        saved = termios.tcgetattr(0)
        received = bytearray()
        try:
            tty.setraw(0)
            os.write(1, b'\\x1b[?2004l')
            print('\\r\\n\(prefix)_READY', flush=True)
            deadline = time.monotonic() + 90
            while len(received) < \(count) and time.monotonic() < deadline:
                if not select.select([0], [], [], 1)[0]:
                    continue
                chunk = os.read(0, \(count) - len(received))
                if not chunk:
                    break
                if not received:
                    print('\\r\\n\(prefix)_RECEIVED', flush=True)
                received.extend(chunk)
        finally:
            termios.tcsetattr(0, termios.TCSADRAIN, saved)
        print('\\r\\n\(prefix)_BYTES=' + received.hex(), flush=True)
        """
        let encoded = Data(source.utf8).base64EncodedString()
        return "python3 -u -c \"import base64; exec(base64.b64decode('\(encoded)'))\""
    }
}
