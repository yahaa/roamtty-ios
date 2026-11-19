import XCTest

/// Opt-in regression against a saved desktop host and its existing credentials.
/// Does not reset the user's store or create/edit hosts.
final class DesktopLaunchUITests: XCTestCase {
    func testDesktopNetworkStatsRestorePortraitAndMatchAndroidLandscape() throws {
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        for english in [false, true] {
            launchStatusFixture(app, phase: "stats", english: english, showStats: true)
            for landscape in [false, true] {
                rotate(app, landscape: landscape)
                let rtt = app.staticTexts["UDP 15 ms"]
                XCTAssertTrue(rtt.waitForExistence(timeout: 10))
                let picture = app.otherElements["desktop-video-surface"].frame
                for label in ["UDP 15 ms", "60 fps  2.4 Mbps", english ? "End-to-end 22 ms" : "端到端 22 ms",
                              english ? "Host 6 · Network 15 · Phone 1" : "主机端 6 · 网络 15 · 手机端 1",
                              english ? "Loss 0.0%" : "丢包 0.0%", "1920×1246 videotoolbox"] {
                    let value = app.staticTexts[label]
                    XCTAssertTrue(value.exists, "Keep every metric: \(label)")
                    XCTAssertTrue(picture.contains(value.frame), "Keep \(label) inside the desktop overlay")
                    XCTAssertTrue(app.frame.insetBy(dx: -1, dy: -1).contains(value.frame))
                }
                // Android: 8 outer + 7 horizontal / 4 vertical panel padding.
                XCTAssertEqual(rtt.frame.minY, picture.minY + 12, accuracy: 1)
                let ops = app.buttons[english ? "Ops" : "操作"]
                if landscape {
                    XCTAssertEqual(rtt.frame.minX, picture.minX + 15, accuracy: 1)
                    XCTAssertEqual(ops.frame.width, 54, accuracy: 1, "Landscape buttons are as deep as portrait ones")
                    XCTAssertGreaterThanOrEqual(ops.frame.minX, picture.maxX - 1)
                } else {
                    XCTAssertGreaterThanOrEqual(ops.frame.minY, picture.maxY - 1)
                    XCTAssertLessThanOrEqual(ops.frame.minY, picture.maxY + 5, "No new statistics strip above portrait controls")
                }
                capture(app, "Android stats overlay \(english ? "English" : "Chinese") \(landscape ? "landscape" : "portrait")")
            }
        }
    }

    func testDesktopNetworkStatsTogglePreservesViewportAndKeyboard() throws {
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        launchStatusFixture(app, phase: "stats", showStats: true)
        for landscape in [false, true] {
            rotate(app, landscape: landscape)
            let picture = app.otherElements["desktop-video-surface"]
            let withStats = picture.frame
            toggleNetworkStats(app)
            XCTAssertFalse(app.staticTexts["UDP 15 ms"].exists)
            XCTAssertEqual(picture.frame.width, withStats.width, accuracy: 1)
            XCTAssertEqual(picture.frame.height, withStats.height, accuracy: 1)
            toggleNetworkStats(app)
            XCTAssertTrue(app.staticTexts["UDP 15 ms"].waitForExistence(timeout: 5))
            XCTAssertEqual(picture.frame.width, withStats.width, accuracy: 1)
            XCTAssertEqual(picture.frame.height, withStats.height, accuracy: 1)
            app.buttons["键盘"].tap()
            Thread.sleep(forTimeInterval: 1)
            if app.buttons["Continue"].waitForExistence(timeout: 1) { app.buttons["Continue"].tap() }
            let hideKeyboard = app.buttons["关闭键盘"]
            XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 5))
            if landscape {
                // The landscape picture is short already: rather than shrinking above the keyboard,
                // it keeps running under the floating keyboard bar.
                XCTAssertGreaterThan(picture.frame.maxY, hideKeyboard.frame.maxY,
                                     "The landscape keyboard floats over the picture instead of shrinking it")
            } else {
                assertPictureAboveControls(app, controls: hideKeyboard)
            }
            let rtt = app.staticTexts["UDP 15 ms"]
            if landscape { XCTAssertEqual(rtt.frame.minX, picture.frame.minX + 15, accuracy: 1) }
            XCTAssertEqual(rtt.frame.minY, picture.frame.minY + 12, accuracy: 1)
            XCTAssertTrue(picture.frame.contains(app.staticTexts["1920×1246 videotoolbox"].frame))
            capture(app, landscape ? "Landscape overlay with keyboard" : "Portrait overlay with keyboard")
            // A tap that lands while the keyboard is still settling can be dropped; the next rotation needs it down.
            for _ in 0..<2 where hideKeyboard.exists { hideKeyboard.tap(); _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3) }
            XCTAssertFalse(app.keyboards.firstMatch.exists, "Closing the keyboard must put it away")
        }
    }

    func testLandscapeRailAndPictureUseTheSideWithoutTheIsland() throws {
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        launchStatusFixture(app, phase: "stats", showStats: true)
        var landscapeRail: [Bool: (depth: CGFloat, fromEdge: CGFloat)] = [:]
        // Device landscape left puts the top of the phone, and its island, on the left.
        for (orientation, islandLeft) in [(UIDeviceOrientation.landscapeLeft, true), (.landscapeRight, false)] {
            XCUIDevice.shared.orientation = orientation
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
            Thread.sleep(forTimeInterval: 1)
            let screen = app.frame
            let picture = app.otherElements["desktop-video-surface"].frame
            let ops = app.buttons["操作"].frame
            let rtt = app.staticTexts["UDP 15 ms"].frame
            if islandLeft {
                XCTAssertGreaterThan(picture.minX, screen.minX + 20, "The picture keeps clear of the island")
                XCTAssertGreaterThan(ops.maxX, screen.maxX - 12, "The buttons sit by the screen edge")
            } else {
                XCTAssertEqual(picture.minX, screen.minX, accuracy: 1, "The picture runs to the screen edge")
                XCTAssertLessThan(ops.maxX, screen.maxX - 20, "The rail's buttons keep clear of the island")
                XCTAssertGreaterThan(rtt.minX, screen.minX + 30, "The stats stay out of the rounded corner")
            }
            XCTAssertLessThanOrEqual(picture.maxX, ops.minX + 1)
            XCTAssertEqual(picture.maxY, screen.maxY, accuracy: 1, "The picture runs under the home indicator")
            XCTAssertGreaterThan(ops.minY, app.buttons["所有窗口"].frame.maxY - 1, "操作 is the lowest button")
            landscapeRail[islandLeft] = (ops.width, screen.maxX - ops.minX)
            capture(app, islandLeft ? "Landscape, island left" : "Landscape, island right")
        }
        XCUIDevice.shared.orientation = .portrait
        let upright = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width < app.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [upright], timeout: 5), .completed)
        Thread.sleep(forTimeInterval: 1)
        let ops = app.buttons["操作"].frame
        XCTAssertLessThan(ops.maxX, app.buttons["所有窗口"].frame.minX, "操作 is the leftmost button")
        XCTAssertGreaterThan(ops.maxY, app.frame.maxY - 20, "The buttons sit just above the home indicator")
        // Lying down, the rail is as thick as standing up, with only the island's side kept clear.
        for (islandLeft, rail) in landscapeRail {
            XCTAssertEqual(rail.depth, ops.height, accuracy: 1, "Landscape buttons are as deep as portrait ones")
            if islandLeft { XCTAssertEqual(rail.fromEdge, app.frame.maxY - ops.minY, accuracy: 1, "The landscape rail is as thick as the portrait one") }
        }
        XCTAssertEqual(landscapeRail.count, 2)
        capture(app, "Portrait rail")
    }

    func testPinchZoomsThePicture() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        launchStatusFixture(app, phase: "stats", showStats: true)
        let picture = app.otherElements["desktop-video-surface"]
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        func drawnWidth() -> Int { Int((picture.value as? String)?.split(separator: "x").first ?? "") ?? 0 }
        let before = drawnWidth()
        XCTAssertGreaterThan(before, 0)
        // XCUIElement.pinch rests both fingers before spreading them, which the page takes for a two-finger hold (as
        // Android does); a pinch spreads them at once.
        let frame = picture.frame
        func at(_ x: CGFloat) -> CGPoint { CGPoint(x: frame.minX + frame.width * x, y: frame.midY) }
        try Touches.perform([[(at(0.45), 0), (at(0.15), 0.4)], [(at(0.55), 0), (at(0.85), 0.4)]])
        let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in drawnWidth() > before + 20 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed, "A pinch enlarges the picture: \(before) -> \(drawnWidth())")
        capture(app, "Pinch zoomed")
    }

    /// The figures: a tap on them still reaches the desktop, a still long press moves them (and nothing of it
    /// reaches the desktop), their ✕ hides them, and turned back on they come back where they were left.
    func testDesktopNetworkStatsCloseAndDragKeepGestures() throws {
        let app = XCUIApplication()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        for landscape in [false, true] {
            app.launchEnvironment["ROAMTTY_DESKTOP_INPUT_PROBE"] = "1"
            launchStatusFixture(app, phase: "stats", showStats: true)
            rotate(app, landscape: landscape)
            let stats = app.otherElements["desktop-stats"]
            XCTAssertTrue(app.staticTexts["UDP 15 ms"].waitForExistence(timeout: 10))
            let picture = app.otherElements["desktop-video-surface"].frame
            let home = stats.frame
            let probe = app.staticTexts["desktop-input-probe"]
            func probeText() -> String { probe.exists ? probe.label : "" }

            // A tap on the figures is the desktop's.
            stats.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).tap()
            let clicked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in probeText().contains("b1d") }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [clicked], timeout: 5), .completed, "A tap on the figures clicks the host: \(probeText())")
            XCTAssertEqual(stats.frame, home, "A tap does not move the figures")

            // A still long press picks them up and drags them; the desktop sees none of it.
            stats.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.8, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: picture.minX + picture.width * 0.75, dy: picture.minY + picture.height * 0.75)))
            Thread.sleep(forTimeInterval: 0.5)
            let moved = stats.frame
            XCTAssertGreaterThan(moved.minX, home.minX + picture.width * 0.1, "Dragged right: \(home) -> \(moved), probe \(probeText())")
            XCTAssertGreaterThan(moved.minY, home.minY + picture.height * 0.1, "Dragged down: \(home) -> \(moved)")
            XCTAssertTrue(picture.insetBy(dx: -1, dy: -1).contains(moved), "Kept inside the picture: \(moved) in \(picture)")
            XCTAssertNotNil(probeText().range(of: #"^#\d+ $"#, options: .regularExpression), "The drag sends nothing to the host: \(probeText())")
            capture(app, "Stats dragged \(landscape ? "landscape" : "portrait")")

            // ✕ hides them and says where they come back from.
            app.buttons["desktop-stats-close"].tap()
            XCTAssertTrue(stats.waitForNonExistence(timeout: 3))
            XCTAssertTrue(app.otherElements["desktop-stats-hint"].exists || app.staticTexts["网络状态已隐藏，可在「操作」中重新打开"].exists)
            capture(app, "Stats closed \(landscape ? "landscape" : "portrait")")
            toggleNetworkStats(app)
            XCTAssertTrue(stats.waitForExistence(timeout: 5))
            XCTAssertEqual(stats.frame.minX, moved.minX, accuracy: 2, "Back where it was left")
            XCTAssertEqual(stats.frame.minY, moved.minY, accuracy: 2, "Back where it was left")
        }
    }

    func toggleNetworkStats(_ app: XCUIApplication) {
        app.buttons["操作"].tap()
        let scroll = app.scrollViews["desktop-operations-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let row = app.switches.matching(NSPredicate(format: "label BEGINSWITH '显示网络状态'")).firstMatch
        // SwiftUI exposes both the labeled row and its UISwitch. Tap the actual
        // control; querying the offscreen row's hit point can fail in XCTest.
        let toggle = row.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        // swipeUp/swipeDown do not move this panel in landscape; drag explicitly within the visible scroll area.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<6 where !scroll.frame.contains(toggle.frame) {
            let frame = scroll.frame, up = toggle.frame.minY > frame.minY
            let (from, to) = up ? (frame.minY + frame.height * 0.8, frame.minY + frame.height * 0.25)
                                : (frame.minY + frame.height * 0.25, frame.minY + frame.height * 0.8)
            origin.withOffset(CGVector(dx: frame.midX, dy: from))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: frame.midX, dy: to)))
        }
        // The operations sheet may still be sliding in; wait for the switch to settle under a finger.
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed, "The network stats switch must be tappable: \(toggle.frame) in \(scroll.frame), window \(app.frame)")
        toggle.tap()
        app.buttons["desktop-op-close"].tap()
    }
}
