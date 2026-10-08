import Foundation
import XCTest

final class SessionCapacityUITests: RoamttyLiveUITestCase {
    private struct OwnedSession {
        let cardID: String
        let token: String
        var recordID: String { String(cardID.dropFirst("session-".count)) }
    }

    func testEightSessionsStayIsolatedAndRemovingCardPreservesRemoteTmux() throws {
        try openHost()
        XCTAssertEqual(sessionIDs().count, 0)
        let runID = nonce()
        var sessions: [OwnedSession] = []
        var remoteTmux: String?

        for index in 0..<8 {
            revealHostControl(app.buttons["host-detail-terminal"])
            let surface = try openTerminal(preferMosh: false, mode: index == 0 ? "tmux" : "SSH")
            let token = runID + "_" + String(index)
            let ready = "CAPACITY_READY_" + nonce()
            var command = "export ROAMTTY_UI_CAPACITY=" + quote(token)
            if index == 0 {
                // Discover the actual session name through this terminal, then
                // mark only that owned tmux session for the later removal check.
                command += "; owned=$(tmux display-message -p -t \"$TMUX_PANE\" '#{session_name}')"
                    + " && tmux set-environment -t \"=$owned\" ROAMTTY_UI_CAPACITY \"$ROAMTTY_UI_CAPACITY\""
                    + " && { printf 'CAPACITY_TMUX_'; printf " + quote(runID + ":%s:END\\n") + " \"$owned\"; }"
            }
            command += " && " + emit(ready)
            try runCommand(command)
            waitForOutput(ready, surface: surface)
            if index == 0 {
                remoteTmux = try tmuxName(from: surface, runID: runID)
            }
            returnToHostDetail()
            let before = Set(sessions.map(\.cardID))
            let after = sessionIDs()
            XCTAssertEqual(after.count, index + 1, "Every successful launch must add one session card")
            XCTAssertTrue(before.isSubset(of: after), "Launching a session must retain existing cards")
            let added = after.subtracting(before)
            XCTAssertEqual(added.count, 1)
            let cardID = try XCTUnwrap(added.first)
            sessions.append(OwnedSession(cardID: cardID, token: token))
            waitFor(NSPredicate(format: "label CONTAINS '已连接' OR label CONTAINS 'Connected'"), element: app.buttons[cardID])
        }

        let eightIDs = Set(sessions.map(\.cardID))
        XCTAssertEqual(eightIDs.count, 8)
        for session in sessions {
            let card = app.buttons[session.cardID]
            XCTAssertTrue(card.exists)
            XCTAssertTrue(card.label.contains("已连接") || card.label.contains("Connected"), "All eight connections must remain live")
        }
        revealHostControl(app.buttons[sessions.last!.cardID])
        capture("Eight independent connected session cards")

        revealHostControl(app.buttons["host-detail-terminal"])
        app.buttons["host-detail-terminal"].tap()
        let launch = app.buttons["launch-session"]
        XCTAssertTrue(launch.waitForExistence(timeout: 15))
        waitFor(NSPredicate(format: "isEnabled == true"), element: launch, timeout: 20)
        launch.tap()
        let limit = app.alerts.firstMatch
        XCTAssertTrue(limit.waitForExistence(timeout: 8), "A ninth session must report the per-host limit")
        XCTAssertTrue(limit.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Maximum 8 sessions per host' OR label CONTAINS '每台主机最多 8 个会话'")).firstMatch.exists)
        capture("Ninth session denied without replacing an existing connection")
        let acknowledge = limit.buttons.matching(NSPredicate(format: "label == '好' OR label == 'OK'")).firstMatch
        XCTAssertTrue(acknowledge.exists); acknowledge.tap()
        // The root error alert has already dismissed the launch sheet. Its
        // acknowledgement returns directly to the original eight session cards.
        waitFor(NSPredicate(format: "exists == false"), element: limit)
        XCTAssertTrue(app.buttons["host-detail-terminal"].waitForExistence(timeout: 5))
        XCTAssertEqual(sessionIDs(), eightIDs, "The rejected ninth launch must not alter any session card")

        // Revisit every card only after all eight shells have been initialized.
        // Each fresh marker requires its own remote variable to match, so shared
        // shell state or old terminal scrollback cannot satisfy these checks.
        for session in sessions.reversed() {
            openSession(session)
            let isolated = "CAPACITY_ISOLATED_" + nonce()
            let surface = try runCommand("test \"$ROAMTTY_UI_CAPACITY\" = " + quote(session.token) + " && " + emit(isolated))
            waitForOutput(isolated, surface: surface)
            if session.cardID == sessions[0].cardID { closeCurrentTerminal() }
            else { returnToHostDetail() }
        }

        let tmux = sessions[0]
        let name = try XCTUnwrap(remoteTmux)
        XCTAssertEqual(sessionIDs(), eightIDs, "Closing tmux must retain its card and still occupy a slot")
        waitFor(NSPredicate(format: "label CONTAINS '已断开' OR label CONTAINS 'Disconnected'"), element: app.buttons[tmux.cardID])
        let remove = app.buttons["close-session-" + tmux.recordID]
        revealHostControl(remove); remove.tap()
        let removeOnly = app.buttons.matching(NSPredicate(format: "label == '仅移除此卡片' OR label == 'Remove this card'")).firstMatch
        XCTAssertTrue(removeOnly.waitForExistence(timeout: 5)); removeOnly.tap()
        waitFor(NSPredicate(format: "exists == false"), element: app.buttons[tmux.cardID])
        XCTAssertEqual(sessionIDs(), eightIDs.subtracting([tmux.cardID]))

        openSession(sessions[1])
        let preserved = "CAPACITY_TMUX_PRESERVED_" + nonce()
        let target = quote("=" + name)
        let check = "tmux has-session -t " + target
            + " && test \"$(tmux show-environment -t " + target + " ROAMTTY_UI_CAPACITY)\" = " + quote("ROAMTTY_UI_CAPACITY=" + tmux.token)
            + " && " + emit(preserved)
        let surface = try runCommand(check)
        waitForOutput(preserved, surface: surface)
        capture("Removed card leaves its exact remote tmux session alive")
        let cleaned = "CAPACITY_TMUX_REMOVED_" + nonce()
        try runCommand("tmux kill-session -t " + target + " && ! tmux has-session -t " + target + " 2>/dev/null && " + emit(cleaned))
        waitForOutput(cleaned, surface: surface)
        returnToHostDetail()

        // Removing the card releases exactly one slot; a new real SSH shell can
        // occupy it while all seven previous SSH cards keep their identities.
        let remaining = eightIDs.subtracting([tmux.cardID])
        revealHostControl(app.buttons["host-detail-terminal"])
        let replacement = try openTerminal(preferMosh: false, mode: "SSH")
        let accepted = "CAPACITY_SLOT_REUSED_" + nonce()
        try runCommand(emit(accepted)); waitForOutput(accepted, surface: replacement)
        returnToHostDetail()
        let finalIDs = sessionIDs()
        XCTAssertEqual(finalIDs.count, 8)
        XCTAssertTrue(remaining.isSubset(of: finalIDs))
        XCTAssertEqual(finalIDs.subtracting(remaining).count, 1)
        XCTAssertFalse(finalIDs.contains(tmux.cardID))

        // Close only the SSH connections created by this case. The sole owned
        // tmux session was terminated above by its discovered exact name.
        for cardID in finalIDs.sorted() {
            let close = app.buttons["close-session-" + String(cardID.dropFirst("session-".count))]
            revealHostControl(close); close.tap()
            let confirm = app.buttons.matching(NSPredicate(format: "label == '关闭连接' OR label == 'Close connection'")).firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
            waitFor(NSPredicate(format: "exists == false"), element: app.buttons[cardID])
        }
        XCTAssertEqual(sessionIDs().count, 0)
    }

    private func sessionIDs() -> Set<String> {
        Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session-'")).allElementsBoundByIndex.map(\.identifier))
    }

    private func returnToHostDetail() { leaveTerminal() }

    private func openSession(_ session: OwnedSession) {
        let card = app.buttons[session.cardID]
        revealHostControl(card); card.tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal-surface"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(phase("已连接").waitForExistence(timeout: 10))
    }

    private func closeCurrentTerminal() {
        closeTerminal()
        XCTAssertTrue(app.buttons["host-detail-terminal"].waitForExistence(timeout: 5))
    }

    private func revealHostControl(_ element: XCUIElement) {
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        for attempt in 0...12 {
            let frame = scroll.frame.intersection(app.frame)
            let top = max(frame.minY, app.navigationBars.firstMatch.frame.maxY)
            let visible = CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, frame.maxY - top)).insetBy(dx: 0, dy: 4)
            if element.exists && element.isHittable && visible.contains(element.frame) { return }
            guard attempt < 12 else { XCTFail("The session control did not become visible"); return }
            if element.exists && element.frame.midY < visible.minY { scroll.swipeDown() }
            else { scroll.swipeUp() }
        }
    }

    private func waitFor(_ predicate: NSPredicate, element: XCUIElement, timeout: Double = 8) {
        let check = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [check], timeout: timeout), .completed)
    }

    private func tmuxName(from surface: XCUIElement, runID: String) throws -> String {
        let text = (surface.value as? String ?? "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        let pattern = NSRegularExpression.escapedPattern(for: "CAPACITY_TMUX_" + runID + ":") + "(roamtty-[A-Fa-f0-9]{12}):END"
        let expression = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "The real tmux shell must report its owned session name")
        let range = try XCTUnwrap(Range(match.range(at: 1), in: text))
        return String(text[range])
    }

    private func nonce() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }
    private func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func emit(_ marker: String) -> String {
        let split = marker.index(marker.startIndex, offsetBy: marker.count / 2)
        return "{ printf '%s' " + quote(String(marker[..<split])) + "; printf '%s\\n' " + quote(String(marker[split...])) + "; }"
    }
}
