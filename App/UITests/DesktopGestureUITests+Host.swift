import XCTest

/// Against the real host: its edges, its desktop button and its own gestures.
extension DesktopGestureUITests {
    /// Swiping back works from the black bars beside the picture, as on any page, while an edge swipe that
    /// starts on the picture stays the desktop's. The offline layout fixture: no host needed.
    func testSwipeBackFromOutsideThePicture() throws {
        for landscape in [false, true] {
            app = XCUIApplication()
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
            app.launchArguments = ["--desktop-controls-fixture"]
            app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "DesktopControlsFixture"
            app.launchEnvironment["ROAMTTY_DESKTOP_STATUS_FIXTURE"] = "connected"
            app.launchEnvironment["ROAMTTY_DESKTOP_FIXTURE_LANGUAGE"] = "zh-Hans"
            app.launch()
            fixedAspect = 720.0 / 1280 // the fixture's picture
            if landscape {
                XCUIDevice.shared.orientation = .landscapeRight
                let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.app.frame.width > self.app.frame.height }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
                pause(1)
            }
            let ops = app.buttons["操作"]
            XCTAssertTrue(ops.waitForExistence(timeout: 10))
            surface = app.otherElements["desktop-video-surface"].frame
            let screen = app.frame
            let mode = landscape ? "landscape" : "portrait"

            // From the screen's left edge, on the picture: the desktop keeps it.
            let onPicture = pic(0, 0.5)
            if onPicture.x - screen.minX < 20 {
                edgeSwipe(from: CGPoint(x: screen.minX + 1, y: onPicture.y), to: CGPoint(x: screen.minX + screen.width * 0.8, y: onPicture.y))
                pause(1.5)
                XCTAssertTrue(ops.exists && ops.isHittable, "\(mode): an edge swipe on the picture does not leave the page")
            }

            // From the screen's left edge, on a black bar: back to the home page.
            let bar = landscape ? CGPoint(x: screen.minX + 2, y: screen.midY)
                                : CGPoint(x: screen.minX + 2, y: (surface.minY + pic(0, 0).y) / 2)
            XCTAssertFalse(app.otherElements["desktop-video-surface"].frame.isEmpty)
            edgeSwipe(from: bar, to: CGPoint(x: screen.minX + screen.width * 0.8, y: bar.y))
            let home = app.buttons["home-tab-hosts"].waitForExistence(timeout: 5)
            if !home { capture("\(mode): still on the desktop after swiping back") }
            XCTAssertTrue(home, "\(mode): swiping back from the black bar leaves the desktop")
            capture("\(mode): back from the black bar")
            XCUIDevice.shared.orientation = .portrait
        }
    }

    /// A swipe in from the screen's edge through XCUITest's own drag, which the system's screen-edge
    /// recognizers accept (touches from the event synthesizer above carry no screen-edge flag).
    func edgeSwipe(from: CGPoint, to: CGPoint) {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: from.x, dy: from.y))
        start.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: to.x, dy: to.y)), withVelocity: 600, thenHoldForDuration: 0)
    }

    /// The rail's 显示桌面, tapped again and again: each tap must reach the host at once and change its picture.
    func testShowDesktopButtonEveryTap() throws {
        try launch(pointer: "touch")
        let button = app.buttons["显示桌面"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        var report: [String] = []
        for i in 1...6 {
            let before = picture(), sent = probeCount()
            let tapped = Date()
            button.tap()
            let tapMs = Int(Date().timeIntervalSince(tapped) * 1000)
            // The app sent it?
            var sentMs = -1
            while Date().timeIntervalSince(tapped) < 3 {
                if probeCount() > sent, tokens().last == "a1" { sentMs = Int(Date().timeIntervalSince(tapped) * 1000); break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            // The host's picture changed?
            var changedMs = -1
            while Date().timeIntervalSince(tapped) < 5 {
                let after = picture()
                let share = Double(zip(before, after).filter { abs(Int($0) - Int($1)) > 16 }.count) / Double(max(1, before.count))
                if share > 0.02 { changedMs = Int(Date().timeIntervalSince(tapped) * 1000); break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            report.append("tap \(i): tap() \(tapMs) ms, sent \(sentMs) ms, picture changed \(changedMs) ms")
            capture("show desktop tap \(i)")
            pause(2)
        }
        NSLog("RoamttyShowDesktop %@", report.joined(separator: " | "))
        let a = XCTAttachment(string: report.joined(separator: "\n")); a.name = "show desktop timings"; a.lifetime = .keepAlways; add(a)
        for line in report {
            XCTAssertFalse(line.contains("sent -1"), line)
            XCTAssertFalse(line.contains("changed -1"), line)
        }
    }

    /// A Mac with a full-screen app in front (the runner activates it first): 显示桌面 must answer at once with the slide, and a second, impatient tap must not undo it.
    func testShowDesktopFromFullScreenTappedTwice() throws {
        try launch(pointer: "touch")
        let button = app.buttons["显示桌面"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        pause(1)
        capture("full-screen app in front")
        let app0 = picture()
        let tapped = Date()
        button.tap()
        button.tap() // the impatient second tap, a moment later
        var samples: [(ms: Int, pic: [UInt8])] = []
        while Date().timeIntervalSince(tapped) < 4 {
            samples.append((Int(Date().timeIntervalSince(tapped) * 1000), picture()))
            Thread.sleep(forTimeInterval: 0.05)
        }
        func differs(_ a: [UInt8], _ b: [UInt8]) -> Double {
            Double(zip(a, b).filter { abs(Int($0) - Int($1)) > 16 }.count) / Double(max(1, a.count))
        }
        let first = samples.first { differs(app0, $0.pic) > 0.02 }?.ms ?? -1
        let moving = zip(samples, samples.dropFirst()).filter { differs($0.pic, $1.pic) > 0.02 }.map { $1.ms }
        pause(1)
        let end = picture()
        capture("after two taps")
        let report = "first change \(first) ms, picture changed at \(moving) ms, end differs from the app by \(String(format: "%.2f", differs(app0, end)))"
        NSLog("RoamttyShowDesktopFullScreen %@", report)
        let a = XCTAttachment(string: report); a.name = "timings"; a.lifetime = .keepAlways; add(a)
        XCTAssertGreaterThanOrEqual(first, 0, report)
        XCTAssertLessThan(first, 1200, "the slide starts at once, the picture does not freeze: \(report)")
        XCTAssertGreaterThan(differs(app0, end), 0.2, "the second tap did not undo the first: the desktop shows. \(report)")
        // Back where it started: the app's Space, the desktop shown again hidden.
        button.tap()
        pause(1.5)
    }

    /// ⌃⌘F on the host through the shortcut bar's latched modifiers: puts a Mac's front window in full screen, or
    /// takes it out. Not `typeKey("f", modifierFlags:)`: the simulator hands the page a plain F, and the host gets that.
    func testToggleHostFullScreen() throws {
        try launch(pointer: "touch")
        withShortcutBar {
            tapBarKey("⌃")
            tapBarKey("⌘")
            app.typeText("f")
        }
        pause(3)
        capture("after control-command-F")
    }

    /// Connects and looks, sending nothing: to see what is on a host before testing on it.
    func testLookAtHost() throws {
        try launch(pointer: "mouse")
        capture("host screen")
    }

    /// Taps the host's screen at ROAMTTY_TAP_POINTS ("x,y;x,y", fractions of the host's screen), in touch mode.
    func testTapHostPoints() throws {
        try launch(pointer: "touch")
        let width = min(surface.width, surface.height / remoteAspect), height = width * remoteAspect
        let left = surface.midX - width / 2, top = surface.midY - height / 2
        for pair in (ProcessInfo.processInfo.environment["ROAMTTY_TAP_POINTS"] ?? "").split(separator: ";") {
            // "d0.3,0.1": a double tap.
            let double = pair.hasPrefix("d")
            let f = pair.drop { $0 == "d" }.split(separator: ",").compactMap { Double($0) }
            guard f.count == 2 else { continue }
            let p = CGPoint(x: left + width * f[0], y: top + height * f[1])
            if double { try Touches.perform([[(p, 0), (p, 0.06)]], then: [[(p, 0.2), (p, 0.26)]]) } else { try Touches.tap([p]) }
            pause(1.5)
        }
        capture("after taps")
    }

    /// A host at its lock screen (a Mac whose login is the test login): types the password there.
    func testUnlockHost() throws {
        try launch(pointer: "mouse")
        let keys = app.buttons.matching(NSPredicate(format: "label == '键盘' OR label == 'Keys'")).firstMatch
        XCTAssertTrue(keys.waitForExistence(timeout: 5)); keys.tap()
        pause(1.5)
        app.typeText(ProcessInfo.processInfo.environment["ROAMTTY_TEST_PASSWORD"] ?? "")
        pause(0.5)
        app.typeText("\n")
        pause(3)
        let close = app.buttons.matching(NSPredicate(format: "label == '关闭键盘' OR label == 'Close keyboard'")).firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() }
        pause(1)
        capture("after unlocking")
    }

    // MARK: Trackpad mode
}
