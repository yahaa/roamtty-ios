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
    func swipeScrollsTmuxHistory(mosh: Bool) throws {
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

    /// A swipe keeps reaching a full-screen agent that tracks the mouse once a line was typed and sent, as Codex draws:
    /// on the alternate screen, with any-event tracking, redrawing its status all the time.
    func testVerticalSwipeReachesAgentAfterTypingALine() throws { try swipeReachesAgentAfterTyping(mosh: false) }
    /// mosh resizes with the keyboard and resends its modes each time, so this is the case phones see most.
    func testMoshVerticalSwipeReachesAgentAfterTypingALine() throws { try swipeReachesAgentAfterTyping(mosh: true) }
    /// Chinese and Japanese keyboards add a phrase-boundary recognizer inside the terminal, which is how phones type here.
    func testVerticalSwipeReachesAgentAfterPinyinInput() throws {
        app.terminate()
        app.launchArguments += ["-AppleKeyboards", "(\"zh_Hans-Pinyin@sw=Pinyin;hw=Automatic\")", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        try swipeReachesAgentAfterTyping(mosh: false, sent: "你") { surface in
            // Pinyin stays marked text until the space bar picks the first candidate. Real key taps: typeText skips the input method.
            for key in ["n", "i", "h", "a", "o"] {
                let tapped = self.app.keys[key]
                XCTAssertTrue(tapped.waitForExistence(timeout: 5), "No key \(key); keys: \(self.app.keys.allElementsBoundByIndex.map(\.label))")
                tapped.tap()
            }
            let space = self.app.keys.matching(NSPredicate(format: "label IN {' ', '空格', '选定', '确认', 'space', 'Space', 'confirm'}")).firstMatch
            XCTAssertTrue(space.waitForExistence(timeout: 5), "No space key; keys: \(self.app.keys.allElementsBoundByIndex.map(\.label))")
            space.tap()
            surface.typeText("\n")
        }
    }
    func swipeReachesAgentAfterTyping(mosh: Bool, line: String = "hello", sent: String = "hello", type: ((XCUIElement) -> Void)? = nil) throws {
        let surface = try openTerminal(preferMosh: mosh)
        try runCommand(fakeMouseAgent())
        waitForOutput("AGENT_READY", surface: surface)
        let upper = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let lower = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        func wheelCount() -> Int {
            let value = (surface.value as? String ?? "").replacingOccurrences(of: "\n", with: "")
            return value.components(separatedBy: "WHEEL=").dropFirst().compactMap { Int($0.prefix(5)) }.last ?? -1
        }
        func swipeReachesAgent(_ moment: String) {
            let before = wheelCount()
            upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: 300, thenHoldForDuration: 0.2)
            let moved = NSPredicate { _, _ in wheelCount() > before }
            let expectation = XCTNSPredicateExpectation(predicate: moved, object: surface)
            expectation.expectationDescription = "A swipe reached the agent \(moment)"
            if XCTWaiter.wait(for: [expectation], timeout: 5) == .completed { return }
            saveFailureScreenshot("swipe-\(moment)")
            XCTFail("A swipe \(moment) sent the agent no wheel events (still \(before))")
        }
        swipeReachesAgent("before-typing")
        let row = app.buttons.matching(NSPredicate(format: "identifier IN {'cursor-escape', 'cursor-enter'}")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: row.frame.midY - surface.frame.minY)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        if let type { type(surface) } else { surface.typeText(line + "\n") }
        waitForOutput("SENT=" + sent, surface: surface)
        swipeReachesAgent("with-keyboard-up")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 20))
        swipeReachesAgent("after-keyboard-hid")
        capture("Swipe reached the agent after typing a line")
    }

    /// As on Android, a quick flick keeps scrolling after the finger lifts; a drag that stops first does not.
    func testTmuxFlickKeepsScrollingAfterRelease() throws {
        let surface = try openTerminal()
        try runCommand("seq -f 'FLING_%04g' 1 1500")
        waitForOutput("FLING_1500", surface: surface)
        let upper = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let lower = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        func lastLine() -> Int {
            let value = surface.value as? String ?? ""
            let numbers = value.components(separatedBy: "FLING_").dropFirst().compactMap { Int($0.prefix(4)) }
            return numbers.max() ?? 0
        }
        func settled() -> Int {
            var previous = -1, current = lastLine()
            while current != previous { previous = current; Thread.sleep(forTimeInterval: 1); current = lastLine() }
            return current
        }
        upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: 300, thenHoldForDuration: 0.3)
        let afterDrag = settled()
        let dragged = 1500 - afterDrag
        XCTAssertGreaterThan(dragged, 0, "The drag entered tmux copy-mode")
        upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: 3000, thenHoldForDuration: 0)
        let flicked = afterDrag - settled()
        XCTAssertGreaterThan(flicked, dragged * 3 / 2, "A flick over the same distance carries on after release")
        capture("Flick kept scrolling tmux history after release")
        closeTerminal()
    }
}
