import XCTest
@testable import RoamttyDesktopCore

/// Mirrors Android's DesktopGesturesTest.
final class DesktopGesturesTests: XCTestCase {
    /// A 2000×1000 view showing a 3024×1964 Retina screen: letterboxed left and right.
    private let view = Viewport(viewWidth: 2000, viewHeight: 1000, remoteWidth: 3024, remoteHeight: 1964)

    private func gestures(_ mode: PointerMode = .touch) -> DesktopGestures {
        let g = DesktopGestures(mode: mode); g.viewport = view; return g
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

    func testTouchTapClicksWhereTheFingerIs() {
        let g = gestures()
        XCTAssertTrue(g.down(1000, 500, time: 0).isEmpty)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .button(1, down: true), .button(1, down: false)], g.up(1001, 500, time: 80))
    }

    func testTouchLongPressRightClicks() {
        let g = gestures()
        _ = g.down(1000, 500, time: 0)
        XCTAssertEqual(500, g.tickAt)
        XCTAssertTrue(g.tick(499).isEmpty)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .button(2, down: true), .button(2, down: false)], g.tick(500))
        XCTAssertNil(g.tickAt)
        XCTAssertTrue(g.move(1100, 500, time: 600).isEmpty, "a long press does not drag")
        XCTAssertTrue(g.up(1100, 500, time: 700).isEmpty)
    }

    func testTouchDragHoldsTheButtonFromWhereTheFingerLanded() {
        let g = gestures()
        _ = g.down(1000, 500, time: 0)
        XCTAssertTrue(g.move(1005, 500, time: 20).isEmpty, "within the slop nothing happens yet")
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .button(1, down: true), .moveTo(x: 1512 + 39, y: 982)], g.move(1020, 500, time: 40))
        XCTAssertNil(g.tickAt, "a drag is never a long press")
        XCTAssertEqual([.moveTo(x: 1512 + 196, y: 982)], g.move(1100, 500, time: 80))
        XCTAssertEqual([.button(1, down: false)], g.up(1100, 500, time: 120))
    }

    func testTouchDragsWhenZoomedToo() {
        let g = gestures()
        g.viewport = view.zoomed(2, 1000, 500)
        _ = g.down(1000, 500, time: 0)
        let out = g.move(1100, 500, time: 50)
        XCTAssertEqual(.button(1, down: true), out[1])
        XCTAssertTrue(out.allSatisfy { if case .view = $0 { return false }; return true })
    }

    func testTwoTapsAreADoubleClickInTouchMode() {
        let g = gestures()
        _ = g.down(1000, 500, time: 0)
        XCTAssertEqual(3, g.up(1000, 500, time: 50).count)
        XCTAssertTrue(g.down(1000, 500, time: 150).isEmpty)
        XCTAssertEqual([.moveTo(x: 1512, y: 982), .button(1, down: true), .button(1, down: false)], g.up(1000, 500, time: 200))
    }

    func testMouseModeMovesRelativelyAndClicksInPlace() {
        let g = gestures(.mouse)
        _ = g.down(100, 100, time: 0)
        let moves = g.move(150, 100, time: 30)
        XCTAssertEqual(1, moves.count)
        // 50 view px / scale × speed.
        guard case .moveBy(let dx, _)? = moves.first else { return XCTFail() }
        XCTAssertEqual(Int(50 / view.scale * DesktopGestures.MOUSE_SPEED), dx)
        XCTAssertTrue(g.up(150, 100, time: 40).isEmpty, "moving is no tap")
        _ = g.down(150, 100, time: 1000)
        // The press goes out at once; its release waits for a possible second touch.
        XCTAssertEqual([.button(1, down: true)], g.up(150, 100, time: 1050))
        XCTAssertEqual(1050 + DesktopGestures.DOUBLE_TAP_MS, g.tickAt)
        XCTAssertTrue(g.tick(1300).isEmpty)
        XCTAssertEqual([.button(1, down: false)], g.tick(1350))
        XCTAssertNil(g.tickAt)
    }

    func testMouseTapThenHoldDragsWithOnePress() {
        let g = gestures(.mouse)
        _ = g.down(100, 100, time: 0)
        XCTAssertEqual([.button(1, down: true)], g.up(100, 100, time: 50))
        XCTAssertTrue(g.down(300, 300, time: 200).isEmpty, "the tap's press carries on")
        XCTAssertNil(g.tickAt, "no release, no long press")
        let moved = g.move(350, 300, time: 250)
        XCTAssertEqual(1, moved.count)
        if case .moveBy? = moved.first {} else { XCTFail("\(moved)") }
        XCTAssertEqual([.button(1, down: false)], g.up(350, 300, time: 300))
        XCTAssertNil(g.tickAt)
    }

    func testMouseTwoTapsDoubleClick() {
        let g = gestures(.mouse)
        _ = g.down(100, 100, time: 0)
        _ = g.up(100, 100, time: 50)
        _ = g.down(100, 100, time: 150)
        XCTAssertEqual([.button(1, down: false), .button(1, down: true), .button(1, down: false)], g.up(100, 100, time: 200))
        XCTAssertNil(g.tickAt)
    }

    func testMouseLateTouchReleasesTheTapFirst() {
        let g = gestures(.mouse)
        _ = g.down(100, 100, time: 0)
        _ = g.up(100, 100, time: 50)
        // The tick was late: the next touch lets the button go before anything else.
        XCTAssertEqual([.button(1, down: false)], g.down(100, 100, time: 600))
        XCTAssertEqual(1100, g.tickAt)
    }

    func testCancelLetsEverythingGo() {
        let g = gestures(.mouse)
        _ = g.down(100, 100, time: 0)
        _ = g.up(100, 100, time: 50)
        XCTAssertEqual([.button(1, down: false)], g.cancel())
        XCTAssertNil(g.tickAt)
        let t = gestures()
        _ = t.down(1000, 500, time: 0)
        _ = t.move(1100, 500, time: 50)
        XCTAssertEqual([.button(1, down: false)], t.cancel())
    }

    func testTheFingerLeftAfterTwoDoesNothing() {
        let g = gestures()
        _ = g.down(900, 500, time: 0)
        _ = g.twoDown(900, 500, 1100, 500)
        g.twoUp()
        XCTAssertTrue(g.move(1300, 500, time: 100).isEmpty)
        XCTAssertTrue(g.up(1300, 500, time: 150).isEmpty)
    }

    func testTwoFingersScrollOrZoom() {
        let g = gestures()
        _ = g.down(900, 500, time: 0)
        _ = g.twoDown(900, 500, 1100, 500)
        XCTAssertTrue(g.twoMove(900, 505, 1100, 505).isEmpty)
        XCTAssertEqual([.wheel(dx: 0, dy: 140)], g.twoMove(900, 540, 1100, 540))
        g.twoUp()
        XCTAssertTrue(g.up(900, 540, time: 400).isEmpty, "lifting after a two-finger gesture is no tap")

        let z = gestures()
        _ = z.down(900, 500, time: 0)
        _ = z.twoDown(900, 500, 1100, 500)
        let pinch = z.twoMove(850, 500, 1150, 500)
        guard pinch.count == 1, case .view(let v) = pinch[0] else { return XCTFail("\(pinch)") }
        XCTAssertEqual(1.5, v.zoom, accuracy: 0.01)
    }

    func testZoomedInTwoFingersMoveThePictureThenScroll() {
        let g = gestures()
        g.viewport = g.viewport.zoomed(2, g.viewport.viewWidth / 2, g.viewport.viewHeight / 2)
        let before = g.viewport
        _ = g.down(900, 500, time: 0)
        _ = g.twoDown(900, 500, 1100, 500)
        let pan = g.twoMove(860, 480, 1060, 480)
        guard pan.count == 1, case .view(let moved) = pan[0] else { return XCTFail("\(pan)") }
        XCTAssertEqual(before.panX - 40, moved.panX, accuracy: 0.01, "the picture follows the fingers from where they landed")
        XCTAssertEqual(before.panY - 20, moved.panY, accuracy: 0.01)
        // Far past the top edge: the picture stops there and the rest scrolls the host.
        let past = g.twoMove(860, -2000, 1060, -2000)
        guard case .view(let edge)? = past.first else { return XCTFail("\(past)") }
        XCTAssertEqual(edge, edge.clamped())
        guard case .wheel(_, let dy)? = past.last else { return XCTFail("past the edge the host scrolls: \(past)") }
        XCTAssertLessThan(dy, 0)
    }
}
