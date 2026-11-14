import XCTest
@testable import RoamttyDesktopCore

/// The gesture table in docs/DESKTOP-GESTURES.md, row by row.
final class DesktopGesturesTests: XCTestCase {
    /// A 2000×1000 view showing a 3024×1964 Retina screen: letterboxed left and right.
    let view = Viewport(viewWidth: 2000, viewHeight: 1000, remoteWidth: 3024, remoteHeight: 1964)

    func gestures(_ mode: PointerMode = .touch) -> DesktopGestures {
        let g = DesktopGestures(mode: mode); g.viewport = view; return g
    }

    func tap(_ g: DesktopGestures, _ x: Float, _ y: Float, at t: Int64, id: Int = 0) -> [GestureAction] {
        g.began(id, x, y, time: t) + g.ended(id, x, y, time: t + 60)
    }

    func buttons(_ actions: [GestureAction]) -> [GestureAction] {
        actions.filter { if case .button = $0 { return true }; return false }
    }

    func moves(_ actions: [GestureAction]) -> [(Int, Int)] {
        actions.compactMap { if case .moveTo(let x, let y) = $0 { return (x, y) }; return nil }
    }

    func wheels(_ actions: [GestureAction]) -> [(Int, Int)] {
        actions.compactMap { if case .wheel(let dx, let dy) = $0 { return (dx, dy) }; return nil }
    }

    func views(_ actions: [GestureAction]) -> [Viewport] {
        actions.compactMap { if case .view(let v) = $0 { return v }; return nil }
    }

    func testViewportMapsToNativePixels() {
        let scale: Float = 1000 / 1964
        XCTAssertEqual(scale, view.scale, accuracy: 1e-6)
        let c = view.toRemote(1000, 500)
        XCTAssertEqual(1512, c.x)
        XCTAssertEqual(982, c.y)
        // The black bars clamp to the edge.
        XCTAssertEqual(0, view.toRemote(10, 500).x)
        XCTAssertFalse(view.contains(10, 500))
        let zoomed = view.zoomed(2, 1000, 500)
        XCTAssertEqual(1512, zoomed.toRemote(1000, 500).x)
        XCTAssertEqual(982, zoomed.toRemote(1000, 500).y)
        XCTAssertEqual(1, view.zoomed(0.5, 0, 0).zoom)
    }

    // MARK: Clicks

    func testTouchTapClicksAtOnceWhereTheFingerLanded() {
        let g = gestures()
        XCTAssertTrue(g.began(0, 1000, 500, time: 0).isEmpty)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .button(1, down: true), .button(1, down: false)], g.ended(0, 1003, 500, time: 80))
        XCTAssertNil(g.tickAt, "nothing waits after a tap")
    }

    func testTrackpadTapClicksAtOnceWhereTheCursorIs() {
        let g = gestures(.mouse)
        g.hostCursor(x: 100, y: 200, time: 0)
        XCTAssertEqual([.button(1, down: true), .button(1, down: false)], tap(g, 900, 500, at: 1000))
        XCTAssertNil(g.tickAt, "the button is not held for a possible drag")
        // Moving straight after the tap only moves: no accidental drag.
        _ = g.began(0, 900, 500, time: 1100)
        let out = g.moved(0, 960, 500, time: 1130)
        XCTAssertTrue(buttons(out).isEmpty, "\(out)")
        XCTAssertEqual(1, moves(out).count)
    }

    func testTouchDoubleTapLandsOnOnePixelDespiteJitter() {
        let g = gestures()
        _ = tap(g, 1000, 500, at: 0)
        let second = tap(g, 1007, 504, at: 160)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .button(1, down: true), .button(1, down: false)], second)
        // Too late, or too far: a tap of its own.
        XCTAssertNotEqual(1512, moves(tap(g, 1007, 504, at: 900)).first?.0)
        _ = tap(g, 1000, 500, at: 2000)
        XCTAssertNotEqual(1512, moves(tap(g, 1030, 500, at: 2150)).first?.0)
    }

    func testTrackpadDoubleTapIsTwoClicksInPlace() {
        let g = gestures(.mouse)
        g.hostCursor(x: 300, y: 300, time: 0)
        let out = tap(g, 900, 500, at: 1000) + tap(g, 906, 503, at: 1150)
        XCTAssertEqual([.button(1, down: true), .button(1, down: false), .button(1, down: true), .button(1, down: false)], out)
    }

    func testTwoFingerTapRightClicks() {
        let g = gestures(.mouse)
        _ = g.began(0, 900, 500, time: 0)
        _ = g.began(1, 1100, 500, time: 20)
        _ = g.ended(0, 900, 500, time: 90)
        XCTAssertTrue(g.ended(1, 1100, 500, time: 100).isEmpty, "a second two-finger tap would zoom instead")
        XCTAssertEqual(400, g.tickAt)
        XCTAssertEqual([.button(2, down: true), .button(2, down: false), .feedback(.click)], g.tick(400))
        XCTAssertNil(g.tickAt)

        // Touch mode: at the middle of the two fingers.
        let t = gestures()
        _ = t.began(0, 900, 500, time: 0); _ = t.began(1, 1100, 500, time: 10)
        _ = t.ended(0, 900, 500, time: 80); _ = t.ended(1, 1100, 500, time: 80)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .button(2, down: true), .button(2, down: false), .feedback(.click)], t.tick(380))
    }

    func testAnotherTouchSendsAWaitingRightClickFirst() {
        let g = gestures(.mouse)
        _ = g.began(0, 900, 500, time: 0); _ = g.began(1, 1100, 500, time: 0)
        _ = g.ended(0, 900, 500, time: 80); _ = g.ended(1, 1100, 500, time: 80)
        let out = tap(g, 900, 500, at: 200)
        XCTAssertEqual([.button(2, down: true), .button(2, down: false), .button(1, down: true), .button(1, down: false)], buttons(out))
    }

    func testThreeFingerTapMiddleClicks() {
        let g = gestures(.mouse)
        _ = g.began(0, 900, 500, time: 0); _ = g.began(1, 1000, 500, time: 10); _ = g.began(2, 1100, 500, time: 20)
        _ = g.ended(0, 900, 500, time: 90); _ = g.ended(1, 1000, 500, time: 95)
        XCTAssertEqual([.button(3, down: true), .button(3, down: false), .feedback(.click)], g.ended(2, 1100, 500, time: 100))
        XCTAssertNil(g.tickAt)
    }

    // MARK: Holds

    func testHoldThenLiftRightClicks() {
        let g = gestures()
        _ = g.began(0, 1000, 500, time: 0)
        XCTAssertEqual(DesktopGestures.HOLD_MS, g.tickAt)
        XCTAssertEqual(false, g.indicator?.armed, "the ring fills while waiting")
        XCTAssertTrue(g.tick(349).isEmpty)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .feedback(.hold)], g.tick(350))
        XCTAssertEqual(true, g.indicator?.armed)
        XCTAssertTrue(g.moved(0, 1004, 500, time: 400).isEmpty, "within the slop it is still a click")
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .button(2, down: true), .button(2, down: false), .feedback(.click)], g.ended(0, 1004, 500, time: 600))
        XCTAssertNil(g.indicator)
    }

    func testTouchHoldThenMoveDragsFromWhereTheFingerLanded() {
        let g = gestures()
        _ = g.began(0, 1000, 500, time: 0)
        _ = g.tick(350)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .button(1, down: true), .feedback(.pickup), .moveTo(x: 1512 + 39, y: 982)],
                       g.moved(0, 1020, 500, time: 400))
        XCTAssertEqual([.moveTo(x: 1512 + 196, y: 982)], g.moved(0, 1100, 500, time: 450))
        XCTAssertEqual([.button(1, down: false)], g.ended(0, 1100, 500, time: 500))
    }

    func testTrackpadHoldThenMoveDragsTheCursor() {
        let g = gestures(.mouse)
        g.hostCursor(x: 500, y: 500, time: 0)
        _ = g.began(0, 900, 500, time: 1000)
        XCTAssertEqual([.feedback(.hold)], g.tick(1350), "the cursor stays where it is")
        let out = g.moved(0, 930, 500, time: 1400)
        XCTAssertEqual([.button(1, down: true), .feedback(.pickup)], Array(out.prefix(2)))
        XCTAssertGreaterThan(moves(out).first?.0 ?? 0, 500)
        XCTAssertEqual([.button(1, down: false)], g.ended(0, 930, 500, time: 1500))
    }

    func testTwoFingerHoldThenMoveRightDrags() {
        let g = gestures()
        _ = g.began(0, 900, 500, time: 0); _ = g.began(1, 1100, 500, time: 0)
        XCTAssertEqual(DesktopGestures.HOLD2_MS, g.tickAt)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .feedback(.hold)], g.tick(500))
        XCTAssertEqual(2, g.indicator?.fingers)
        let out = g.moved([(0, 900, 530), (1, 1100, 530)], time: 600)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .button(2, down: true), .feedback(.pickup), .moveTo(x: 1512, y: 982 + 58)], out)
        XCTAssertEqual([.button(2, down: false)], g.ended(0, 900, 530, time: 700))
        XCTAssertTrue(g.ended(1, 1100, 530, time: 710).isEmpty)
    }

    // MARK: Moving and scrolling
}

final class DesktopSwipeShortcutTests: XCTestCase {
    func testSwipesBecomeEachSystemsShortcut() {
        XCTAssertEqual([DesktopProtocol.action(DesktopProtocol.ACTION_ALL_WINDOWS)], DesktopSwipeShortcut.frames(.up, os: "windows"))
        XCTAssertEqual([DesktopProtocol.action(DesktopProtocol.ACTION_SHOW_DESKTOP)], DesktopSwipeShortcut.frames(.down, os: "macos"))
        XCTAssertEqual([DesktopProtocol.key(HidUsage.LEFT_CTRL, down: true), DesktopProtocol.key(HidUsage.RIGHT, down: true),
                        DesktopProtocol.key(HidUsage.RIGHT, down: false), DesktopProtocol.key(HidUsage.LEFT_CTRL, down: false)],
                       DesktopSwipeShortcut.frames(.left, os: "macOS"))
        XCTAssertEqual([DesktopProtocol.key(HidUsage.LEFT_CTRL, down: true), DesktopProtocol.key(HidUsage.LEFT_GUI, down: true),
                        DesktopProtocol.key(HidUsage.LEFT, down: true), DesktopProtocol.key(HidUsage.LEFT, down: false),
                        DesktopProtocol.key(HidUsage.LEFT_GUI, down: false), DesktopProtocol.key(HidUsage.LEFT_CTRL, down: false)],
                       DesktopSwipeShortcut.frames(.right, os: "windows"))
        XCTAssertEqual(DesktopProtocol.key(HidUsage.LEFT_ALT, down: true), DesktopSwipeShortcut.frames(.left, os: "linux")[1])
    }
}
