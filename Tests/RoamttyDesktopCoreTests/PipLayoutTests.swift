import XCTest
@testable import RoamttyDesktopCore

/// The small window's geometry, the same cases as Android's PipLayoutTest.
final class PipLayoutTests: XCTestCase {
    private let room = PipRect(0, 0, 1000, 2000)

    func testSizeFollowsTheFractionAndAspect() {
        let (w, h) = PipLayout.size(room: room, reference: 1000, fraction: 0.7, aspect: 1.6)
        XCTAssertEqual(w, 700, accuracy: 0.01)
        XCTAssertEqual(h, 437.5, accuracy: 0.01)
    }

    func testFractionIsClampedToTheAllowedRange() {
        XCTAssertEqual(PipLayout.size(room: room, reference: 1000, fraction: 0.1, aspect: 1.6).width, 300, accuracy: 0.01)
        XCTAssertEqual(PipLayout.size(room: room, reference: 1000, fraction: 3, aspect: 1.6).width, 1000, accuracy: 0.01)
    }

    func testARoomTooLowShrinksItKeepingItsAspect() {
        let (w, h) = PipLayout.size(room: PipRect(0, 0, 1000, 300), reference: 1000, fraction: 1, aspect: 1.6)
        XCTAssertEqual(h, 300, accuracy: 0.01)
        XCTAssertEqual(w, 480, accuracy: 0.01)
    }

    func testPlaceSpansTheFreeRoom() {
        XCTAssertEqual(PipLayout.place(room: room, width: 200, height: 100, fx: 0, fy: 0), PipRect(0, 0, 200, 100))
        XCTAssertEqual(PipLayout.place(room: room, width: 200, height: 100, fx: 1, fy: 1), PipRect(800, 1900, 1000, 2000))
        XCTAssertEqual(PipLayout.place(room: room, width: 200, height: 100, fx: 0.5, fy: 0.5), PipRect(400, 950, 600, 1050))
        // Out-of-range fractions stay inside.
        XCTAssertEqual(PipLayout.place(room: room, width: 200, height: 100, fx: 3, fy: -1), PipRect(800, 0, 1000, 100))
    }

    func testFractionsRoundTripAndClampADropOutside() {
        let f = PipLayout.fractions(room: room, width: 200, height: 100, left: 400, top: 950)
        XCTAssertEqual(f.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(f.y, 0.5, accuracy: 0.001)
        let out = PipLayout.fractions(room: room, width: 200, height: 100, left: 5000, top: -300)
        XCTAssertEqual(out.x, 1); XCTAssertEqual(out.y, 0)
        // A window as wide as the room has nowhere to go sideways.
        XCTAssertEqual(PipLayout.fractions(room: room, width: 1000, height: 100, left: 50, top: 0).x, 0, accuracy: 0.001)
    }

    func testTheSamePlaceWhenTheRoomShrinks() {
        let f = PipLayout.fractions(room: room, width: 200, height: 100, left: 800, top: 1900)
        XCTAssertEqual(PipLayout.place(room: PipRect(0, 0, 1000, 1200), width: 200, height: 100, fx: f.x, fy: f.y), PipRect(800, 1100, 1000, 1200))
    }

    func testTheHandleIsOnTheSideWithRoomToGrow() {
        XCTAssertTrue(PipLayout.handleOnLeft(room: room, window: PipRect(700, 0, 1000, 200)))
        XCTAssertFalse(PipLayout.handleOnLeft(room: room, window: PipRect(0, 0, 300, 200)))
        // Full width, or nearly: it stays on the right rather than jumping with a pixel.
        XCTAssertFalse(PipLayout.handleOnLeft(room: room, window: PipRect(0, 0, 1000, 600)))
        XCTAssertFalse(PipLayout.handleOnLeft(room: room, window: PipRect(0.5, 0, 1000, 600)))
    }

    func testDraggingTheHandleOutwardsGrows() {
        XCTAssertEqual(PipLayout.resized(width: 400, dx: 100, dy: 62.5, onLeft: false, aspect: 1.6), 500, accuracy: 0.01)
        XCTAssertEqual(PipLayout.resized(width: 400, dx: -100, dy: 62.5, onLeft: true, aspect: 1.6), 500, accuracy: 0.01)
        XCTAssertEqual(PipLayout.resized(width: 400, dx: -100, dy: -62.5, onLeft: false, aspect: 1.6), 300, accuracy: 0.01)
    }

    func testTheBarGoesAboveElseBelowElseOverTheTopEdge() {
        XCTAssertEqual(PipLayout.barTop(room: room, window: PipRect(0, 600, 500, 900), bar: 32, gap: 8), 560, accuracy: 0.01)
        XCTAssertEqual(PipLayout.barTop(room: room, window: PipRect(0, 0, 500, 300), bar: 32, gap: 8), 308, accuracy: 0.01)
        // As tall as the room: over its top edge, still inside.
        XCTAssertEqual(PipLayout.barTop(room: room, window: PipRect(0, 0, 500, 2000), bar: 32, gap: 8), 8, accuracy: 0.01)
        XCTAssertEqual(PipLayout.barTop(room: PipRect(0, 10, 1000, 2000), window: PipRect(0, 10, 500, 2000), bar: 32, gap: 0), 10, accuracy: 0.01)
    }

    func testCloseTargetIsARadius() {
        XCTAssertTrue(PipLayout.overClose(cx: 500, cy: 1900, tx: 510, ty: 1910, radius: 50))
        XCTAssertFalse(PipLayout.overClose(cx: 500, cy: 1700, tx: 510, ty: 1910, radius: 50))
    }

    func testPinchScalesWithinTheRange() {
        XCTAssertEqual(PipLayout.pinched(0.7, zoom: 1.2), 0.84, accuracy: 0.001)
        XCTAssertEqual(PipLayout.pinched(0.9, zoom: 2), PipLayout.maxFraction, accuracy: 0.001)
        XCTAssertEqual(PipLayout.pinched(0.5, zoom: 0.2), PipLayout.minFraction, accuracy: 0.001)
    }
}
