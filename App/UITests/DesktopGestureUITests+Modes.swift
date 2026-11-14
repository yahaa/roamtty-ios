import XCTest

/// Every gesture of trackpad mode and of touch mode, checked by what reaches the host.
extension DesktopGestureUITests {
    func testTrackpadModeGestures() throws {
        try launch(pointer: "mouse")
        let mid = at(0.5, 0.5)
        // Wherever an earlier run left the cursor (on the Dock, say), the clicks start in the middle.
        try centerCursor()

        try Touches.tap([mid])
        expect(["b1d", "b1u"], "one-finger tap clicks at once")
        none("m", "a tap does not move the cursor")
        pause()

        try Touches.perform([[(mid, 0), (mid, 0.06)]], then: [[(mid, 0.2), (mid, 0.26)]])
        expect(["b1d", "b1u", "b1d", "b1u"], "double tap is a double click")
        pause()

        try Touches.perform([[(at(0.3, 0.5), 0), (at(0.6, 0.45), 0.35)]])
        expect(["m*"], "one finger moves the cursor")
        none("b", "moving presses nothing")
        pause()

        try centerCursor()
        var before = picture()
        try Touches.tap([at(0.45, 0.5), at(0.55, 0.5)])
        expect(["b2d", "b2u", "fclick"], within: 2, "two-finger tap right clicks")
        pause(0.5)
        assertChanged(before, "a menu opened on the host")
        capture("trackpad: right click menu")
        escape()

        try Touches.tap([at(0.4, 0.5), at(0.5, 0.5), at(0.6, 0.5)])
        expect(["b3d", "b3u", "fclick"], "three-finger tap middle clicks")
        pause()

        before = picture()
        try Touches.perform([[(mid, 0), (mid, 0.6)]])
        expect(["fhold", "b2d", "b2u", "fclick"], "hold and lift right clicks")
        pause(0.5)
        assertChanged(before, "a menu opened on the host")
        capture("trackpad: hold menu")
        escape()

        try Touches.perform([[(at(0.4, 0.4), 0), (at(0.4, 0.4), 0.5), (at(0.55, 0.5), 1.0)]])
        expect(["fhold", "b1d", "fpickup", "m*", "b1u"], "hold and move drags")
        pause()

        try Touches.perform([[(at(0.45, 0.4), 0), (at(0.45, 0.4), 0.7), (at(0.45, 0.55), 1.2)],
                             [(at(0.55, 0.4), 0), (at(0.55, 0.4), 0.7), (at(0.55, 0.55), 1.2)]])
        expect(["fhold", "b2d", "fpickup", "m*", "b2u"], "two-finger hold and move right drags")
        pause(1)
        escape()

        try centerCursor()
        try twoFingerScroll()
        try pinchAndSmartZoom(touch: false)
        try edgeSwipes(trackpad: true)
        try threeFingerSwipes()
    }

    // MARK: Touch mode

    func testTouchModeGestures() throws {
        try launch(pointer: "touch")
        let mid = at(0.5, 0.5)

        try Touches.tap([mid])
        let tap = expect(["m*", "b1d", "b1u"], "tap clicks where the finger is")
        pause()

        // A second tap a few points off lands on the same pixel.
        let jitter = CGPoint(x: mid.x + 4, y: mid.y + 3)
        try Touches.perform([[(mid, 0), (mid, 0.06)]], then: [[(jitter, 0.18), (jitter, 0.24)]])
        let double = expect(["m*", "b1d", "b1u", "m*", "b1d", "b1u"], "double tap")
        let moves = double.filter { $0.hasPrefix("m") }
        XCTAssertEqual(Set(moves).count, 1, "both clicks on one pixel: \(double)")
        XCTAssertEqual(moves.first, tap.first { $0.hasPrefix("m") })
        pause()

        // One finger flicks the document under it, as on a phone: the cursor goes there, then the
        // wheel, and the scroll carries on after lifting.
        let page = picture()
        try Touches.perform([[(pic(0.5, 0.75), 0), (pic(0.5, 0.25), 0.15)]])
        let slide = expect(["m*", "w*"], "one finger scrolls what is under it")
        none("b", "a slide presses nothing")
        none("z", "at full size a slide leaves the picture alone")
        XCTAssertLessThan(slide.first { $0.hasPrefix("w") }.flatMap { Int($0.split(separator: ",").last ?? "") } ?? 0, 0,
                          "finger going up scrolls down: \(slide)")
        let lifted = probeCount()
        pause(0.6)
        XCTAssertGreaterThan(probeCount(), lifted + 3, "a flick carries on after lifting")
        pause(1)
        if share(page, picture()) <= 0.004 {
            // At the end of the document already: the flick the other way must scroll it.
            let end = picture()
            try Touches.perform([[(pic(0.5, 0.25), 0), (pic(0.5, 0.75), 0.15)]])
            assertChanged(end, "the document under the finger scrolled (back from its end)")
        } else {
            capture("touch: one-finger scroll")
            pause(2)
            try Touches.perform([[(pic(0.5, 0.25), 0), (pic(0.5, 0.75), 0.15)]])
        }
        pause(2.5)

        var before = picture()
        try Touches.perform([[(mid, 0), (mid, 0.6)]])
        expect(["m*", "fhold", "b2d", "b2u", "fclick"], "hold and lift right clicks")
        pause(0.5)
        assertChanged(before, "a menu opened on the host")
        capture("touch: hold menu")
        pause(1)
        escape()

        try Touches.perform([[(at(0.4, 0.4), 0), (at(0.4, 0.4), 0.5), (at(0.55, 0.5), 1.0)]])
        expect(["fhold", "m*", "b1d", "fpickup", "m*", "b1u"], "hold and move drags from where the finger landed")
        pause()

        before = picture()
        try Touches.tap([at(0.45, 0.5), at(0.55, 0.5)])
        expect(["m*", "b2d", "b2u", "fclick"], within: 2, "two-finger tap right clicks at the middle")
        pause(0.5)
        assertChanged(before, "a menu opened on the host")
        capture("touch: right click menu")
        pause(1)
        escape()

        try Touches.tap([at(0.4, 0.5), at(0.5, 0.5), at(0.6, 0.5)])
        expect(["m*", "b3d", "b3u", "fclick"], "three-finger tap middle clicks")
        pause()

        try twoFingerScroll()
        try pinchAndSmartZoom(touch: true)
        try edgeSwipes(trackpad: false)
    }
}
