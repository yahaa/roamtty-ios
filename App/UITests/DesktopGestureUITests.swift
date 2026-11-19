import XCTest

/// The gesture table (docs/DESKTOP-GESTURES.md) against a real desktop host: every gesture is made with
/// real synthesized touches on the live page, and the input it sent is read back from the page's probe
/// (ROAMTTY_DESKTOP_INPUT_PROBE=1). Screenshots of the host's picture after each step show its effect.
/// Opt-in: `scripts/test-desktop-gestures.sh host.json` sets ROAMTTY_DESKTOP_GESTURE_HOST=1 and points
/// ROAMTTY_TEST_HOST / _PORT / _USERNAME / _PASSWORD at a disposable desktop host. The full suite's SSH
/// fixture has no desktop, so there these tests skip; `testSwipeBackFromOutsideThePicture` needs no host.
final class DesktopGestureUITests: XCTestCase {
    var app: XCUIApplication!
    var surface: CGRect = .zero

    func launch(pointer: String) throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ROAMTTY_DESKTOP_GESTURE_HOST"] == "1", let host = env["ROAMTTY_TEST_HOST"], !host.isEmpty,
              env["ROAMTTY_TEST_PASSWORD"] != nil else {
            throw XCTSkip("Needs a live desktop host: run scripts/test-desktop-gestures.sh host.json")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--desktop-gesture-fixture"]
        for key in ["ROAMTTY_TEST_HOST", "ROAMTTY_TEST_PORT", "ROAMTTY_TEST_USERNAME", "ROAMTTY_TEST_PASSWORD", "ROAMTTY_TAP_POINTS"] {
            if let value = env[key] { app.launchEnvironment[key] = value }
        }
        app.launchEnvironment["ROAMTTY_STORAGE_NAME"] = "DesktopGesture-\(UUID().uuidString)"
        app.launchEnvironment["ROAMTTY_DESKTOP_INPUT_PROBE"] = "1"
        app.launchEnvironment["ROAMTTY_DESKTOP_POINTER"] = pointer
        app.launch()
        // Connected once the stats show the picture's size (a still screen sends 0 fps).
        let frames = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+×[0-9]+ .*'")).firstMatch
        XCTAssertTrue(frames.waitForExistence(timeout: 90), "the live desktop must be connected")
        continueAfterFailure = true
        let gestures = app.otherElements["desktop-video-surface"]
        XCTAssertTrue(gestures.waitForExistence(timeout: 5))
        surface = gestures.frame
        Thread.sleep(forTimeInterval: 2)
    }

    // MARK: Probe

    var probe: XCUIElement { app.staticTexts["desktop-input-probe"] }

    /// The tokens since the last gesture began.
    func tokens() -> [String] {
        guard probe.exists else { return [] }
        return probe.label.split(separator: " ").dropFirst().map(String.init)
    }

    /// Waits until the tokens hold `expected` in order (prefix matches: "m" for any move).
    @discardableResult
    func expect(_ expected: [String], within seconds: Double = 3, _ step: String,
                file: StaticString = #filePath, line: UInt = #line) -> [String] {
        let deadline = Date().addingTimeInterval(seconds)
        var seen: [String] = []
        repeat {
            seen = tokens()
            if Self.ordered(expected, in: seen) { return seen }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        XCTFail("\(step): expected \(expected) in order, got \(seen)", file: file, line: line)
        return seen
    }

    static func ordered(_ expected: [String], in seen: [String]) -> Bool {
        var i = 0
        for token in seen where i < expected.count {
            if token == expected[i] || (expected[i].hasSuffix("*") && token.hasPrefix(expected[i].dropLast())) { i += 1 }
        }
        return i == expected.count
    }

    func none(_ prefix: String, _ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let seen = tokens()
        XCTAssertFalse(seen.contains { $0.hasPrefix(prefix) }, "\(step): no \(prefix) expected, got \(seen)", file: file, line: line)
    }

    func capture(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    // MARK: Points

    func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: surface.minX + surface.width * fx, y: surface.minY + surface.height * fy)
    }

    /// A point inside the host's picture, as fractions of it (the view letterboxes it).
    func pic(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        let width = min(surface.width, surface.height / remoteAspect), height = width * remoteAspect
        return CGPoint(x: surface.midX - width / 2 + width * fx, y: surface.midY - height / 2 + height * fy)
    }

    func pause(_ s: Double = 0.8) { Thread.sleep(forTimeInterval: s) }

    /// Esc from the keyboard panel's shortcut bar: closes a menu or an overview on the host.
    func escape() {
        withShortcutBar { tapBarKey("Esc") }
    }

    /// Opens the keyboard panel with its shortcut bar, runs `body`, and closes the panel again.
    func withShortcutBar(_ body: () -> Void) {
        let keys = app.buttons.matching(NSPredicate(format: "label == '键盘' OR label == 'Keys'")).firstMatch
        guard keys.waitForExistence(timeout: 3) else { return XCTFail("no keyboard button") }
        keys.tap()
        let toggle = app.buttons["desktop-kb-toggle"]
        if toggle.waitForExistence(timeout: 3) { toggle.tap() }
        body()
        let close = app.buttons.matching(NSPredicate(format: "label == '关闭键盘' OR label == 'Close keyboard'")).firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() }
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        pause(1)
    }

    func tapBarKey(_ label: String) {
        let key = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        if key.waitForExistence(timeout: 3) { key.tap() } else { XCTFail("no \(label) key") }
    }

    /// Trackpad mode: the cursor to the middle of the host's screen, from its bottom-left corner by a slow
    /// slide (slow enough for the lowest, constant pointer gain of 0.5).
    func centerCursor() throws {
        let corner = pic(0, 1)
        try Touches.perform([[(CGPoint(x: corner.x + 4, y: corner.y - 4), 0), (CGPoint(x: corner.x + 30, y: corner.y - 20), 0.2)]])
        expect(["m0,*", "fshortcut"], "a swipe in from the picture's bottom-left corner")
        pause(0.3)
        // At a gain of 0.5, sliding the picture's own width moves the cursor half the host's width.
        let width = min(surface.width, surface.height / remoteAspect), height = width * remoteAspect
        let from = CGPoint(x: surface.minX + surface.width * 0.05, y: surface.midY + height * 0.45)
        let to = CGPoint(x: from.x + width * 0.9, y: from.y - height * 0.9)
        var path: [(CGPoint, Double)] = []
        for i in 0...40 { let f = CGFloat(i) / 40; path.append((CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f), 0.2 * Double(i))) }
        try Touches.perform([path])
        pause(0.5)
    }

    /// Height over width of the host's screen, from the stats' size line.
    var fixedAspect: CGFloat?
    var remoteAspect: CGFloat {
        if let fixedAspect { return fixedAspect }
        let size = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9]+×[0-9]+ .*'")).firstMatch.label
        let parts = size.split(separator: " ").first?.split(separator: "×").compactMap { Double($0) } ?? []
        return parts.count == 2 && parts[0] > 0 ? CGFloat(parts[1] / parts[0]) : 0.625
    }

    /// The middle of the host's picture, small and grey, to tell whether the host's screen changed.
    func picture() -> [UInt8] {
        let shot = XCUIScreen.main.screenshot().image
        guard let cg = shot.cgImage else { return [] }
        let scale = CGFloat(cg.width) / shot.size.width
        let height = min(surface.height, surface.width * remoteAspect)
        let rect = CGRect(x: surface.minX + surface.width * 0.1, y: surface.midY - height * 0.3,
                          width: surface.width * 0.8, height: height * 0.6)
        guard let crop = cg.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)) else { return [] }
        let w = 96, h = 48
        var bytes = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        ctx?.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
    }

    func share(_ a: [UInt8], _ b: [UInt8]) -> Double {
        Double(zip(a, b).filter { abs(Int($0) - Int($1)) > 16 }.count) / Double(max(1, a.count))
    }

    func assertChanged(_ before: [UInt8], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        // The host's picture takes a moment to come: wait up to three seconds for it.
        var changed = 0, share = 0.0
        let deadline = Date().addingTimeInterval(3)
        repeat {
            let after = picture()
            // Sensitive enough for a dark menu over a dark window (macOS dark mode); a still host
            // changes under 0.2% of the samples (video noise, the clock).
            changed = zip(before, after).filter { abs(Int($0) - Int($1)) > 16 }.count
            share = Double(changed) / Double(max(1, before.count))
            if share > 0.004 { break }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        XCTAssertGreaterThan(share, 0.004, "\(what): the host's picture did not change (\(changed) of \(before.count) samples)", file: file, line: line)
    }
}

/// Multi-finger touches through XCTest's event synthesizer (what WebDriverAgent uses): XCUITest's public
/// API has no two-finger slide, hold or three-finger swipe.
enum Touches {
    typealias Finger = [(CGPoint, Double)]

    static func tap(_ points: [CGPoint]) throws {
        try perform(points.map { [($0, 0), ($0, 0.06)] })
    }

    /// Each finger lands at its first point, moves through the rest at their offsets (seconds), and lifts at the last.
    /// `then`: a second set of fingers in the same record, offsets counted from the same start.
    static func perform(_ fingers: [Finger], then more: [Finger] = []) throws {
        guard let recordClass = NSClassFromString("XCSynthesizedEventRecord"),
              let pathClass = NSClassFromString("XCPointerEventPath") else { throw XCTSkip("No XCTest event synthesizer") }
        typealias InitRecord = @convention(c) (AnyObject, Selector, NSString, Int) -> Unmanaged<AnyObject>
        typealias InitPath = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Unmanaged<AnyObject>
        typealias MoveTo = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        typealias LiftUp = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias AddPath = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias Synthesize = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool

        func alloc(_ cls: AnyClass) -> AnyObject {
            (cls as AnyObject).perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
        }
        func imp<T>(_ object: AnyObject, _ name: String, _: T.Type) -> (T, Selector) {
            let sel = NSSelectorFromString(name)
            return (unsafeBitCast(object.method(for: sel), to: T.self), sel)
        }
        let recordAlloc = alloc(recordClass)
        let (initRecord, initRecordSel) = imp(recordAlloc, "initWithName:interfaceOrientation:", InitRecord.self)
        let record = initRecord(recordAlloc, initRecordSel, "roamtty gesture", 1).takeUnretainedValue()
        for finger in fingers + more {
            guard let first = finger.first, let last = finger.last else { continue }
            let pathAlloc = alloc(pathClass)
            let (initPath, initPathSel) = imp(pathAlloc, "initForTouchAtPoint:offset:", InitPath.self)
            let path = initPath(pathAlloc, initPathSel, first.0, first.1).takeUnretainedValue()
            let (moveTo, moveSel) = imp(path, "moveToPoint:atOffset:", MoveTo.self)
            for point in finger.dropFirst() { moveTo(path, moveSel, point.0, point.1) }
            let (lift, liftSel) = imp(path, "liftUpAtOffset:", LiftUp.self)
            lift(path, liftSel, last.1)
            let (add, addSel) = imp(record, "addPointerEventPath:", AddPath.self)
            add(record, addSel, path)
        }
        let (synthesize, synthesizeSel) = imp(record, "synthesizeWithError:", Synthesize.self)
        var error: NSError?
        if !synthesize(record, synthesizeSel, &error) { throw error ?? NSError(domain: "Touches", code: 1) }
    }
}
