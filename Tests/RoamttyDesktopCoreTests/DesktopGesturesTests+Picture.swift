import XCTest
@testable import RoamttyDesktopCore

/// The picture, the shortcuts, and odds and ends.
extension DesktopGesturesTests {
    func testPinchZoomsAndMovesThePicture() {
        let g = gestures()
        _ = g.began(0, 900, 500, time: 0); _ = g.began(1, 1100, 500, time: 0)
        let pinch = g.moved([(0, 850, 500), (1, 1150, 500)], time: 30)
        XCTAssertEqual(1, pinch.count)
        XCTAssertEqual(1.5, views(pinch).first?.zoom ?? 0, accuracy: 0.01)
        XCTAssertTrue(wheels(pinch).isEmpty && buttons(pinch).isEmpty, "zoom never reaches the host")
        let zoomed = g.viewport
        let pan = g.moved([(0, 800, 500), (1, 1100, 500)], time: 60)
        XCTAssertEqual(zoomed.zoom, views(pan).first?.zoom ?? 0, accuracy: 0.01)
        XCTAssertLessThan(views(pan).first?.panX ?? 0, zoomed.panX, "the picture follows the fingers while pinching")
    }

    func testTwoFingerDoubleTapZoomsInAndOut() {
        let g = gestures(.mouse)
        func twoTap(_ t: Int64) -> [GestureAction] {
            g.began(0, 1400, 300, time: t) + g.began(1, 1600, 300, time: t) + g.ended(0, 1400, 300, time: t + 60) + g.ended(1, 1600, 300, time: t + 60)
        }
        XCTAssertTrue(twoTap(0).isEmpty)
        let zoomIn = twoTap(200)
        XCTAssertEqual(2.5, views(zoomIn).first?.zoom ?? 0, accuracy: 0.01)
        XCTAssertTrue(buttons(zoomIn).isEmpty, "no right click")
        XCTAssertNil(g.tickAt)
        // The spot under the fingers stays put.
        XCTAssertEqual(Float(view.toRemote(1500, 300).x), Float(g.viewport.toRemote(1500, 300).x), accuracy: 2)
        _ = twoTap(2000)
        let zoomOut = twoTap(2200)
        XCTAssertEqual(1, views(zoomOut).first?.zoom)
        XCTAssertEqual(0, views(zoomOut).first?.panX)
    }

    func testTrackpadZoomedInThePictureFollowsTheCursor() {
        let g = gestures(.mouse)
        g.viewport = view.zoomed(2.5, 1000, 500)
        g.hostCursor(x: 1512, y: 982, time: 0)
        _ = g.began(0, 500, 500, time: 1000)
        var out: [GestureAction] = []
        var x: Float = 500, t: Int64 = 1000
        while x < 900 { x += 20; t += 16; out += g.moved(0, x, 500, time: t) }
        XCTAssertFalse(views(out).isEmpty, "the picture moved to keep the cursor in view")
        let p = g.viewport.toView(g.cursorX, g.cursorY)
        XCTAssertLessThanOrEqual(p.x, 2000 * 0.85 + 1)
    }

    func testTouchDragNearTheEdgeOfAZoomedPictureMovesIt() {
        let g = gestures()
        g.viewport = view.zoomed(2.5, 1000, 500)
        _ = g.began(0, 1000, 500, time: 0)
        _ = g.tick(350)
        _ = g.moved(0, 1500, 500, time: 400)
        _ = g.moved(0, 1990, 500, time: 450)
        XCTAssertEqual(450 + DesktopGestures.FRAME_MS, g.tickAt)
        let out = g.tick(466)
        XCTAssertLessThan(views(out).first?.panX ?? 0, view.zoomed(2.5, 1000, 500).panX, "the picture slides left")
        XCTAssertEqual(1, moves(out).count, "the drag follows to what is now under the finger")
        _ = g.ended(0, 1990, 500, time: 500)
        XCTAssertNil(g.tickAt)
    }

    // MARK: Shortcuts

    func testEdgeSwipesPutTheCursorOnTheHostsEdge() {
        // The picture spans x 230…1770 of the 2000-wide view (black bars left and right) and all its height.
        let g = gestures()
        _ = g.began(0, 235, 500, time: 0)
        XCTAssertEqual([.moveTo(x: 0, y: 982), .feedback(.shortcut)], g.moved(0, 270, 502, time: 30))
        XCTAssertTrue(g.moved(0, 500, 502, time: 60).isEmpty, "the rest of the swipe does nothing")
        XCTAssertTrue(g.ended(0, 500, 502, time: 90).isEmpty)

        _ = g.began(0, 1000, 995, time: 1000)
        XCTAssertEqual([.moveTo(x: 1512, y: 1963), .feedback(.shortcut)], g.moved(0, 1000, 960, time: 1030))
        _ = g.ended(0, 1000, 960, time: 1060)

        _ = g.began(0, 1765, 5, time: 2000)
        XCTAssertEqual([.moveTo(x: 3023, y: 0), .feedback(.shortcut)], g.moved(0, 1740, 20, time: 2030), "a corner: the hot corner")
        _ = g.ended(0, 1740, 20, time: 2060)

        // Along the edge is not a swipe in: it scrolls.
        _ = g.began(0, 235, 500, time: 3000)
        XCTAssertEqual(1, moves(g.moved(0, 236, 540, time: 3030)).count)
        XCTAssertFalse(g.moved(0, 236, 560, time: 3060).contains(.feedback(.shortcut)))
        _ = g.ended(0, 236, 560, time: 3090)
    }

    func testTheScreenEdgeOutsideThePictureIsNoEdgeSwipe() {
        // The screen's edge, on the black bar: swiping back starts there, not an edge swipe.
        let g = gestures()
        _ = g.began(0, 5, 500, time: 0)
        let out = g.moved(0, 60, 502, time: 30)
        XCTAssertFalse(out.contains(.feedback(.shortcut)), "\(out)")
    }

    func testThreeFingerSwipes() {
        for (dx, dy, dir) in [(Float(-80), Float(0), SwipeDirection.left), (80, 0, .right), (0, -80, .up), (0, 80, .down)] {
            let g = gestures(.mouse)
            _ = g.began(0, 900, 500, time: 0); _ = g.began(1, 1000, 500, time: 0); _ = g.began(2, 1100, 500, time: 0)
            let out = g.moved([(0, 900 + dx, 500 + dy), (1, 1000 + dx, 500 + dy), (2, 1100 + dx, 500 + dy)], time: 50)
            XCTAssertEqual([.swipe(dir), .feedback(.shortcut)], out)
            XCTAssertTrue(g.moved([(0, 900 + 2 * dx, 500 + 2 * dy)], time: 80).isEmpty, "once per swipe")
            _ = g.ended(0, 0, 0, time: 100); _ = g.ended(1, 0, 0, time: 100)
            XCTAssertTrue(g.ended(2, 0, 0, time: 100).isEmpty, "a swipe is no tap")
        }
    }

    func testFourFingersAreLeftToTheSystem() {
        let g = gestures()
        _ = g.began(0, 1000, 500, time: 0)
        _ = g.tick(350)
        _ = g.moved(0, 1100, 500, time: 400)
        _ = g.began(1, 900, 600, time: 450)
        _ = g.began(2, 1000, 600, time: 450)
        _ = g.began(3, 1100, 600, time: 450)
        var out: [GestureAction] = []
        for id in 0...3 { out += g.moved(id, 500, 500, time: 500) + g.ended(id, 500, 500, time: 600) }
        XCTAssertTrue(out.isEmpty, "\(out)")
    }

    // MARK: Odds and ends

    func testASecondFingerEndsADrag() {
        let g = gestures()
        _ = g.began(0, 1000, 500, time: 0)
        _ = g.tick(350)
        _ = g.moved(0, 1100, 500, time: 400)
        XCTAssertEqual([.button(1, down: false)], g.began(1, 900, 500, time: 450))
        XCTAssertTrue(g.moved(0, 1200, 500, time: 500).isEmpty)
        XCTAssertTrue((g.ended(1, 900, 500, time: 550) + g.ended(0, 1200, 500, time: 600)).isEmpty)
    }

    func testTheFingerLeftAfterTwoDoesNothing() {
        let g = gestures()
        _ = g.began(0, 900, 500, time: 0); _ = g.began(1, 1100, 500, time: 0)
        _ = g.moved([(0, 900, 540), (1, 1100, 540)], time: 30)
        _ = g.ended(1, 1100, 540, time: 60)
        XCTAssertTrue(g.moved(0, 1300, 500, time: 100).isEmpty)
        XCTAssertTrue(g.ended(0, 1300, 500, time: 150).isEmpty)
    }

    func testCancelLetsEverythingGo() {
        let g = gestures()
        _ = g.began(0, 1000, 500, time: 0)
        _ = g.tick(350)
        _ = g.moved(0, 1100, 500, time: 400)
        XCTAssertEqual([.button(1, down: false)], g.cancel())
        XCTAssertNil(g.tickAt)
        XCTAssertNil(g.indicator)
    }

    func testThePhonesCursorStandsWhileItMovesIt() {
        let g = gestures(.mouse)
        g.hostCursor(x: 100, y: 100, time: 0)
        XCTAssertEqual(100, g.cursorX)
        _ = g.began(0, 500, 500, time: 1000)
        _ = g.moved(0, 600, 500, time: 1050)
        let local = g.cursorX
        XCTAssertGreaterThan(local, 100)
        g.hostCursor(x: 100, y: 100, time: 1200)
        XCTAssertEqual(local, g.cursorX, "a late echo does not pull the cursor back")
        g.hostCursor(x: 700, y: 800, time: 2000)
        XCTAssertEqual(700, g.cursorX, "the host moved it itself")
        XCTAssertEqual(800, g.cursorY)
    }
}
