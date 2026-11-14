import XCTest

/// The steps the two modes share.
extension DesktopGestureUITests {
    func twoFingerScroll() throws {
        let before = picture()
        // A flick: the wheel keeps going after the fingers lift.
        try Touches.perform([[(pic(0.45, 0.75), 0), (pic(0.45, 0.25), 0.15)], [(pic(0.55, 0.75), 0), (pic(0.55, 0.25), 0.15)]])
        let during = expect(["w*"], "two fingers scroll")
        none("b", "scrolling presses nothing")
        none("z", "scrolling leaves the picture alone")
        let first = during.first { $0.hasPrefix("w") }.flatMap { Int($0.split(separator: ",").last ?? "") } ?? 0
        XCTAssertLessThan(first, 0, "fingers going up scroll down: \(during)")
        let countAtLift = probeCount()
        pause(0.6)
        XCTAssertGreaterThan(probeCount(), countAtLift + 3, "inertia carries the scroll on after lifting")
        pause(1)
        let back: [Touches.Finger] = [[(pic(0.45, 0.25), 0), (pic(0.45, 0.75), 0.15)], [(pic(0.55, 0.25), 0), (pic(0.55, 0.75), 0.15)]]
        if share(before, picture()) <= 0.004 {
            // At the end of the document already, as touch mode allows: the flick the other way must scroll it.
            let end = picture()
            try Touches.perform(back)
            assertChanged(end, "the document under the cursor scrolled (back from its end)")
        } else {
            capture("scrolled")
            pause(2)
            try Touches.perform(back)
        }
        pause(2.5)
    }

    func probeCount() -> Int {
        guard probe.exists else { return 0 }
        return Int(probe.label.split(separator: " ").first?.dropFirst() ?? "") ?? 0
    }

    func pinchAndSmartZoom(touch: Bool) throws {
        try Touches.perform([[(at(0.45, 0.5), 0), (at(0.3, 0.5), 0.4)], [(at(0.55, 0.5), 0), (at(0.7, 0.5), 0.4)]])
        let pinch = expect(["z*"], "pinch zooms")
        none("w", "pinching does not scroll")
        none("b", "pinching does not click")
        XCTAssertGreaterThan(Double(pinch.last { $0.hasPrefix("z") }?.dropFirst() ?? "") ?? 0, 1.5)
        capture("pinched")
        pause()
        // Zoomed in, two fingers still scroll the host.
        try Touches.perform([[(at(0.45, 0.6), 0), (at(0.45, 0.45), 0.4)], [(at(0.55, 0.6), 0), (at(0.55, 0.45), 0.4)]])
        expect(["w*"], "zoomed in, two fingers scroll")
        none("z", "zoomed in, scrolling leaves the picture alone")
        pause(1.5)
        if touch {
            // Zoomed in, one finger moves the picture, as a zoomed photo; the host does not scroll.
            // Sideways: in portrait the zoomed picture still fits the height, so only its width can move.
            try Touches.perform([[(at(0.5, 0.5), 0), (at(0.4, 0.5), 0.5)]])
            expect(["m*", "z*"], "zoomed in, one finger moves the picture")
            none("w", "inside the zoomed picture, a slide does not scroll the host")
            none("b", "moving the picture presses nothing")
            capture("touch: zoomed picture moved")
            pause()
        }
        // Two-finger double tap: out to the whole screen, then in to 2.5×, then out.
        let a = at(0.45, 0.4), b = at(0.55, 0.4)
        for (step, zoom) in [("smart zoom out", "z1.00"), ("smart zoom in", "z2.50"), ("smart zoom back out", "z1.00")] {
            try Touches.perform([[(a, 0), (a, 0.06)], [(b, 0), (b, 0.06)]], then: [[(a, 0.2), (a, 0.26)], [(b, 0.2), (b, 0.26)]])
            expect([zoom, "fshortcut"], step)
            none("b", "\(step) does not right click")
            pause()
        }
    }

    func edgeSwipes(trackpad: Bool) throws {
        let left = pic(0, 0.5)
        try Touches.perform([[(CGPoint(x: left.x + 4, y: left.y), 0), (CGPoint(x: left.x + 80, y: left.y), 0.2)]])
        expect(["m0,*", "fshortcut"], "a swipe in from the left edge puts the cursor on the host's left edge")
        pause()
        let bottom = pic(0.5, 1)
        try Touches.perform([[(CGPoint(x: bottom.x, y: bottom.y - 4), 0), (CGPoint(x: bottom.x, y: bottom.y - 80), 0.2)]])
        expect(["m*", "fshortcut"], "a swipe up from the bottom edge reaches the host's bottom edge")
        capture(trackpad ? "trackpad: cursor on the bottom edge" : "touch: cursor on the bottom edge")
        pause()
    }

    func threeFingerSwipes() throws {
        for (dx, dy, token) in [(CGFloat(0), CGFloat(-0.25), "sup"), (0, 0.25, "sdown"), (-0.3, 0, "sleft"), (0.3, 0, "sright")] {
            let fingers = [0.4, 0.5, 0.6].map { fx -> [(CGPoint, Double)] in
                [(at(fx, 0.5), 0), (at(fx + dx, 0.5 + dy), 0.3)]
            }
            try Touches.perform(fingers)
            expect([token, "fshortcut"], "three-finger swipe \(token)")
            capture("three-finger \(token)")
            pause(1.5)
            if token == "sup" { escape() }
            if token == "sdown" {
                // Showing the desktop again brings the windows back.
                try Touches.perform(fingers)
                pause(1.5)
            }
        }
    }
}
