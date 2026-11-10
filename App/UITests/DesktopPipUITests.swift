import XCTest

/// The desktop in a small window over its terminal, on a live desktop host (Android E2eDesktopTest d07 / d10):
/// the dock's desktop button opens it (a long press opens the page), it moves and turns with the phone, a tap
/// focuses it without the keyboard, the bar's keyboard brings the input method with the shortcut row, full screen
/// opens the page and coming back shows it small again, and ✕ closes it.
final class DesktopPipUITests: RoamttyLiveUITestCase {
    private var window: XCUIElement { app.descendants(matching: .any)["pip-desktop"].firstMatch }
    private var bar: XCUIElement { app.descendants(matching: .any)["pip-desktop-bar"].firstMatch }
    private var dockDesktop: XCUIElement { app.descendants(matching: .any)["terminal-desktop"].firstMatch }

    private func openDock() {
        openTools()
        XCTAssertTrue(dockDesktop.waitForExistence(timeout: 30), "The host's desktop button must show once its desktop is found")
    }

    /// 操作 › 返回: back to the terminal, the desktop kept. The panel slides in first.
    private func leavePage(_ ops: XCUIElement) {
        ops.tap()
        let exit = app.buttons["desktop-op-exit"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: exit)
        waitForExpectations(timeout: 5)
        Thread.sleep(forTimeInterval: 0.4)
        exit.tap()
    }

    private func waitGone(_ element: XCUIElement, timeout: Double = 10) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    func testSmallDesktopWindowOverTheTerminal() throws {
        try openTerminal(directory: "/tmp")
        openDock()
        dockDesktop.tap()
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        // The picture replaces the opening card.
        waitGone(app.descendants(matching: .any)["pip-desktop-status"].firstMatch, timeout: 60)
        capture("pip-unfocused")
        XCTAssertFalse(bar.exists, "No bar until it is focused")

        // A drag puts it where it is dropped.
        let before = window.frame
        let place = app.descendants(matching: .any)["pip-desktop-place"].firstMatch
        // Towards the middle of the screen, wherever an earlier run left it.
        // Sideways to between the left edge and the middle, where the grip is on its right.
        let down = before.midY < app.frame.midY
        let toX = 0.5 + (app.frame.width * 0.38 - before.midX) / before.width
        place.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: place.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: down ? 1.6 : -0.6)))
        let moved = window.frame
        XCTAssertGreaterThan(abs(moved.minY - before.minY), 60, "\(before) → \(moved)")
        XCTAssertGreaterThanOrEqual(moved.minY, 62, "Clear of the status bar")

        // The grip resizes it: outwards grows it, back in shrinks it.
        let grip = app.descendants(matching: .any)["pip-desktop-resize"].firstMatch
        XCTAssertTrue(grip.exists)
        func dragGrip(out: Bool) {
            let left = grip.frame.midX < window.frame.midX
            let dx: CGFloat = (left ? -1 : 1) * (out ? 2.5 : -2.5)
            grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + dx, dy: 0.5)))
        }
        XCTAssertGreaterThan(grip.frame.midX, window.frame.midX, "The grip is on the right, with room to grow")
        dragGrip(out: true)
        let grown = window.frame
        XCTAssertGreaterThan(grown.width, moved.width + 20, "\(moved) → \(grown)")
        // The right grip keeps the left corner: the window does not jump aside.
        XCTAssertEqual(grown.minX, moved.minX, accuracy: 3, "\(moved) → \(grown)")
        XCTAssertEqual(grown.minY, moved.minY, accuracy: 3)
        dragGrip(out: false)
        XCTAssertLessThan(window.frame.width, grown.width - 20, "\(grown) → \(window.frame)")

        // Turning the phone keeps it.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        capture("pip-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)

        // A tap focuses it: the bar shows, the keyboard does not.
        window.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertEqual(app.keyboards.count, 0, "Focusing must not bring up the keyboard")
        capture("pip-focused")

        // The bar's keyboard: the input method with the shortcut row straight above it, no 快捷键 chip.
        app.buttons["pip-desktop-keyboard"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["desktop-sk-esc"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["desktop-kb-toggle"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The keyboard opens from the bar")
        app.typeText("pip")
        capture("pip-keyboard")
        // ▾ closes it, as the bar's button does.
        app.descendants(matching: .any)["desktop-kb-hide-bar"].firstMatch.tap()
        waitGone(app.descendants(matching: .any)["desktop-sk-esc"].firstMatch)
        XCTAssertTrue(bar.exists, "Still focused")
        app.buttons["pip-desktop-keyboard"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["desktop-sk-esc"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["pip-desktop-keyboard"].tap()
        waitGone(app.descendants(matching: .any)["desktop-sk-esc"].firstMatch)

        // A touch on the terminal takes the input back.
        app.descendants(matching: .any)["terminal-surface"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).tap()
        waitGone(bar)

        // Full screen opens the page; going back shows it small again.
        window.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        app.buttons["pip-desktop-full"].tap()
        let ops = app.buttons.matching(NSPredicate(format: "label == '操作' OR label == 'Ops'")).firstMatch
        XCTAssertTrue(ops.waitForExistence(timeout: 10))
        XCTAssertFalse(window.exists, "The page takes the picture")
        leavePage(ops)
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Back on the terminal, the desktop is small again")
        waitGone(app.descendants(matching: .any)["pip-desktop-status"].firstMatch, timeout: 20)

        // ✕ on the bar closes it; the dock button opens it again, and its long press opens the page.
        window.tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        app.buttons["pip-desktop-close"].tap()
        waitGone(window)
        openDock()
        dockDesktop.tap()
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        openDock()
        dockDesktop.tap()
        waitGone(window)
        openDock()
        dockDesktop.press(forDuration: 0.8)
        XCTAssertTrue(ops.waitForExistence(timeout: 10), "A long press opens the desktop page")
        leavePage(ops)
        XCTAssertTrue(app.descendants(matching: .any)["terminal-surface"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(window.exists, "Opened full, it comes back without the small window")
    }
}
