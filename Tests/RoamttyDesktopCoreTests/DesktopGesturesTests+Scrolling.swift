import XCTest
@testable import RoamttyDesktopCore

/// Moving and scrolling.
extension DesktopGesturesTests {
    func testTouchSlideScrollsWhatIsUnderTheFinger() {
        let g = gestures()
        _ = g.began(0, 1000, 500, time: 0)
        XCTAssertTrue(g.moved(0, 1000, 505, time: 16).isEmpty, "within the slop nothing happens yet")
        let first = g.moved(0, 1000, 530, time: 32)
        XCTAssertEqual(.moveTo(x: 1512, y: 982), first.first, "the host scrolls what is under its cursor: put it under the finger")
        XCTAssertNil(g.tickAt, "a slide is never a hold")
        var out = first
        var y: Float = 530, t: Int64 = 32
        while y < 800 { y += 25; t += 16; out += g.moved(0, 1000, y, time: t) }
        XCTAssertTrue(buttons(out).isEmpty, "a slide presses nothing: \(out)")
        XCTAssertEqual(1, moves(out).count, "the cursor stays put while scrolling")
        XCTAssertFalse(wheels(out).isEmpty)
        XCTAssertTrue(wheels(out).allSatisfy { $0.1 > 0 && $0.0 == 0 }, "finger down pulls the page down: \(wheels(out))")
        XCTAssertTrue(views(out).isEmpty, "at full size the picture stays put")
        // A flick carries on after lifting, slowing down.
        XCTAssertTrue(buttons(g.ended(0, 1000, y, time: t + 5)).isEmpty, "no click after a slide")
        XCTAssertEqual(t + 5 + DesktopGestures.FRAME_MS, g.tickAt)
        var coast: [(Int, Int)] = []
        while let at = g.tickAt, coast.count < 1000 { coast += wheels(g.tick(at)) }
        XCTAssertGreaterThan(coast.count, 5)
        XCTAssertTrue(coast.allSatisfy { $0.1 > 0 })
        XCTAssertNil(g.tickAt)
    }

    func testTouchSlideStoppedBeforeLiftingDoesNotCoast() {
        let g = gestures()
        _ = g.began(0, 1000, 300, time: 0)
        for i in 1...10 { _ = g.moved(0, 1000, 300 + Float(i) * 20, time: Int64(i) * 16) }
        _ = g.ended(0, 1000, 500, time: 400)
        XCTAssertNil(g.tickAt)
    }

    func testZoomedInTouchSlideMovesThePictureThenScrolls() {
        let g = gestures()
        g.viewport = view.zoomed(2, 1000, 500)
        let before = g.viewport
        _ = g.began(0, 1000, 500, time: 0)
        let pan = g.moved(0, 980, 480, time: 30) + g.moved(0, 960, 460, time: 60)
        XCTAssertFalse(views(pan).isEmpty, "the picture follows the finger, as a zoomed photo")
        XCTAssertTrue(wheels(pan).isEmpty, "inside the picture's slack nothing scrolls: \(pan)")
        XCTAssertLessThan(g.viewport.panY, before.panY)
        // Far past the top edge: the picture stops there and the rest scrolls the host.
        let past = g.moved(0, 960, -3000, time: 90)
        guard case .view(let edge)? = past.first else { return XCTFail("\(past)") }
        XCTAssertEqual(edge, edge.clamped())
        XCTAssertLessThan(wheels(past).last?.1 ?? 0, 0, "past the edge the host scrolls: \(past)")
        XCTAssertTrue(buttons(past).isEmpty)
    }

    func testTouchTwoFingerScrollPutsTheCursorBetweenTheFingers() {
        let g = gestures()
        _ = g.began(0, 900, 300, time: 0); _ = g.began(1, 1100, 300, time: 0)
        let out = g.moved([(0, 900, 340), (1, 1100, 340)], time: 30)
        XCTAssertEqual(.moveTo(x: 1512, y: 589), out.first)
        XCTAssertFalse(wheels(out).isEmpty)
    }

    func testTrackpadMovesTheCursorFasterTheFasterTheFinger() {
        func travel(_ step: Float, every ms: Int64) -> Int {
            let g = gestures(.mouse)
            g.hostCursor(x: 1000, y: 1000, time: 0)
            _ = g.began(0, 500, 500, time: 1000)
            var x: Float = 500, t: Int64 = 1000, last = 1000
            while x < 800 { x += step; t += ms; if let m = moves(g.moved(0, x, 500, time: t)).last { last = m.0 } }
            return last - 1000
        }
        let slow = travel(2, every: 16), fast = travel(30, every: 16)
        XCTAssertGreaterThan(fast, slow * 3, "slow \(slow), fast \(fast)")
        XCTAssertEqual(0.5, DesktopGestures.pointerGain(10))
        XCTAssertEqual(4, DesktopGestures.pointerGain(100_000))
    }

    func testTwoFingersScrollWithInertia() {
        let g = gestures()
        _ = g.began(0, 900, 300, time: 0); _ = g.began(1, 1100, 300, time: 0)
        XCTAssertTrue(g.moved([(0, 900, 305), (1, 1100, 305)], time: 16).isEmpty)
        var out: [GestureAction] = []
        var y: Float = 305, t: Int64 = 16
        while y < 500 { y += 20; t += 16; out += g.moved([(0, 900, y), (1, 1100, y)], time: t) }
        XCTAssertFalse(wheels(out).isEmpty)
        XCTAssertTrue(wheels(out).allSatisfy { $0.1 > 0 && $0.0 == 0 }, "fingers moving down scroll up: \(wheels(out))")
        XCTAssertTrue(buttons(out).isEmpty)
        _ = g.ended(0, 900, y, time: t + 5)
        _ = g.ended(1, 1100, y, time: t + 5)
        XCTAssertEqual(t + 5 + DesktopGestures.FRAME_MS, g.tickAt, "a flick carries on")
        var coast: [(Int, Int)] = []
        var now = t + 5
        while let at = g.tickAt, now < t + 20_000 { now = at; coast += wheels(g.tick(at)) }
        XCTAssertGreaterThan(coast.count, 5)
        XCTAssertTrue(coast.allSatisfy { $0.1 > 0 })
        XCTAssertLessThan(abs(coast.last!.1), abs(coast.first!.1), "it slows down")
        XCTAssertNil(g.tickAt, "and stops")
    }

    func testPauseBeforeLiftingLeavesNoInertia() {
        let g = gestures()
        _ = g.began(0, 900, 300, time: 0); _ = g.began(1, 1100, 300, time: 0)
        for i in 1...10 { _ = g.moved([(0, 900, 300 + Float(i) * 20), (1, 1100, 300 + Float(i) * 20)], time: Int64(i) * 16) }
        _ = g.ended(0, 900, 500, time: 400); _ = g.ended(1, 1100, 500, time: 400)
        XCTAssertNil(g.tickAt)
    }

    func testANewTouchStopsInertia() {
        let g = gestures()
        _ = g.began(0, 900, 300, time: 0); _ = g.began(1, 1100, 300, time: 0)
        for i in 1...10 { _ = g.moved([(0, 900, 300 + Float(i) * 20), (1, 1100, 300 + Float(i) * 20)], time: Int64(i) * 16) }
        _ = g.ended(0, 900, 500, time: 165); _ = g.ended(1, 1100, 500, time: 165)
        XCTAssertNotNil(g.tickAt)
        _ = g.began(0, 900, 500, time: 200)
        XCTAssertEqual(200 + DesktopGestures.HOLD_MS, g.tickAt, "only the new touch's hold is pending")
    }

    func testZoomedInTwoFingersStillScrollTheHost() {
        let g = gestures()
        g.viewport = view.zoomed(2, 1000, 500)
        let before = g.viewport
        _ = g.began(0, 900, 500, time: 0); _ = g.began(1, 1100, 500, time: 0)
        let out = g.moved([(0, 860, 460), (1, 1060, 460)], time: 30) + g.moved([(0, 820, 420), (1, 1020, 420)], time: 60)
        XCTAssertTrue(views(out).isEmpty, "the picture stays put: \(out)")
        XCTAssertFalse(wheels(out).isEmpty)
        XCTAssertEqual(before, g.viewport)
    }

    // MARK: The picture
}
