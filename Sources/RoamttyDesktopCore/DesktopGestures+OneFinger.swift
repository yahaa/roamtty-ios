import Foundation

/// One finger: the cursor, drags, edge swipes and the picture that follows them.
extension DesktopGestures {
    func moveOne(_ x: Float, _ y: Float, time: Int64) -> [GestureAction] {
        let dx = x - lastX, dy = y - lastY
        let dt = Float(max(1, time - lastMoveAt))
        track(dx / dt, dy / dt)
        lastX = x; lastY = y; lastMoveAt = time
        let far = length(x - downX, y - downY) >= slop
        var out: [GestureAction] = []
        switch phase {
        case .pending:
            guard far else { return [] }
            flushRight(&out)
            holdAt = nil; indicator = nil
            if let e = edge, inward(e, x - downX, y - downY) {
                phase = .edgeDone
                return out + [toEdge(e), .feedback(.shortcut)]
            }
            phase = .moving
            // Touch mode scrolls what is under the finger: the host scrolls what is under its cursor.
            if mode == .touch { return out + [moveTo(downX, downY)] + swipe(dx, dy) }
            return out + follow(x, y, dx, dy)
        case .moving:
            return mode == .touch ? swipe(dx, dy) : follow(x, y, dx, dy)
        case .holdArmed:
            guard far else { return [] }
            phase = .dragging
            indicator = nil
            if mode == .touch {
                // The press goes where the finger landed, so the drag picks up what was under it.
                out = [moveTo(downX, downY), .button(1, down: true), .feedback(.pickup), moveTo(x, y)]
                armAutoPan(time)
                return out
            }
            return [.button(1, down: true), .feedback(.pickup)] + follow(x, y, dx, dy)
        case .dragging:
            if mode == .touch { armAutoPan(time) }
            return follow(x, y, dx, dy)
        default:
            return []
        }
    }

    /// Trackpad: the cursor travels the finger's way, faster the faster it goes. Touch: it is under the finger.
    func follow(_ x: Float, _ y: Float, _ dx: Float, _ dy: Float) -> [GestureAction] {
        if mode == .touch { return [moveTo(x, y)] }
        let gain = Self.pointerGain(length(vx, vy) * 1000)
        let s = viewport.scale
        setCursor(cursorX + dx * gain / s, cursorY + dy * gain / s)
        return [.moveTo(x: Int(cursorX), y: Int(cursorY))] + keepCursorInView()
    }

    /// Pointer acceleration, after macOS: slow for precision, up to 4× for a flick across the screen.
    public static func pointerGain(_ pointsPerSecond: Float) -> Float {
        min(max(0.8 * powf(pointsPerSecond / 150, 0.6), 0.5), 4)
    }

    /// Trackpad, zoomed in: the picture follows a cursor that reaches its outer 15%.
    func keepCursorInView() -> [GestureAction] {
        guard viewport.zoom > 1 else { return [] }
        let p = viewport.toView(cursorX, cursorY)
        let mx = viewport.viewWidth * 0.15, my = viewport.viewHeight * 0.15
        var dx: Float = 0, dy: Float = 0
        if p.x < mx { dx = mx - p.x } else if p.x > viewport.viewWidth - mx { dx = viewport.viewWidth - mx - p.x }
        if p.y < my { dy = my - p.y } else if p.y > viewport.viewHeight - my { dy = viewport.viewHeight - my - p.y }
        if dx == 0 && dy == 0 { return [] }
        let next = viewport.panned(dx, dy)
        if next == viewport { return [] }
        viewport = next
        return [.view(next)]
    }

    func armAutoPan(_ time: Int64) {
        if autoPanAt == nil && viewport.zoom > 1 && edgeDepth(lastX, lastY) != (0, 0) { autoPanAt = time }
    }

    /// How far into the edge band a point is, -1…1 on each axis (negative: left or top).
    func edgeDepth(_ x: Float, _ y: Float) -> (Float, Float) {
        let bx = min(60 * density, viewport.viewWidth * 0.15), by = min(60 * density, viewport.viewHeight * 0.15)
        func depth(_ v: Float, _ size: Float, _ band: Float) -> Float {
            if v < band { return -min(1, (band - v) / band) }
            if v > size - band { return min(1, (v - (size - band)) / band) }
            return 0
        }
        return (depth(x, viewport.viewWidth, bx), depth(y, viewport.viewHeight, by))
    }

    /// Touch mode: a drag held near the edge of a zoomed picture moves the picture, up to 600 pt/s.
    func autoPan(time: Int64) -> [GestureAction] {
        guard let at = autoPanAt, phase == .dragging || phase == .rightDrag, mode == .touch, viewport.zoom > 1 else { autoPanAt = nil; return [] }
        let (ex, ey) = edgeDepth(lastX, lastY)
        let dt = Float(time - at)
        let next = viewport.panned(-ex * 0.6 * dt, -ey * 0.6 * dt)
        autoPanAt = time
        if next == viewport { autoPanAt = nil; return [] }
        viewport = next
        return [.view(next), moveTo(lastX, lastY)]
    }

    /// The picture's edges, where they show in the view: a touch within the edge zone of one (on either
    /// side of it, along the picture) may be an edge swipe. The black bars beside the picture are not
    /// the picture's: swiping back from the screen's edge starts there.
    func edgeOf(_ x: Float, _ y: Float) -> (left: Bool, right: Bool, top: Bool, bottom: Bool)? {
        let v = viewport
        let pl = max(0, v.left), pr = min(v.viewWidth, v.left + v.contentWidth)
        let pt = max(0, v.top), pb = min(v.viewHeight, v.top + v.contentHeight)
        let alongY = y >= pt - edgeZone && y <= pb + edgeZone, alongX = x >= pl - edgeZone && x <= pr + edgeZone
        let e = (left: alongY && abs(x - pl) < edgeZone, right: alongY && abs(x - pr) < edgeZone,
                 top: alongX && abs(y - pt) < edgeZone, bottom: alongX && abs(y - pb) < edgeZone)
        return e.left || e.right || e.top || e.bottom ? e : nil
    }

    func inward(_ e: (left: Bool, right: Bool, top: Bool, bottom: Bool), _ dx: Float, _ dy: Float) -> Bool {
        (e.left && dx > abs(dy)) || (e.right && -dx > abs(dy)) || (e.top && dy > abs(dx)) || (e.bottom && -dy > abs(dx))
    }

    /// An edge swipe puts the cursor on the host's edge there (the Dock, the taskbar), or in its corner.
    func toEdge(_ e: (left: Bool, right: Bool, top: Bool, bottom: Bool)) -> GestureAction {
        let r = viewport.toRemote(downX, downY)
        var x = mode == .touch ? Float(r.x) : cursorX, y = mode == .touch ? Float(r.y) : cursorY
        if e.left { x = 0 } else if e.right { x = Float(viewport.remoteWidth - 1) }
        if e.top { y = 0 } else if e.bottom { y = Float(viewport.remoteHeight - 1) }
        setCursor(x, y)
        return .moveTo(x: Int(cursorX), y: Int(cursorY))
    }

    /// A second finger came while one was holding or dragging: that ends, and so does the gesture.
    func endOneFinger() -> [GestureAction] {
        var out: [GestureAction] = []
        if phase == .dragging { out.append(.button(1, down: false)) }
        if [.pending, .moving, .holdArmed, .dragging, .edgeDone].contains(phase) { phase = .spent }
        holdAt = nil; indicator = nil; autoPanAt = nil
        return out
    }

    func endTwoFinger() -> [GestureAction] {
        var out: [GestureAction] = []
        if phase == .rightDrag { out.append(.button(2, down: false)) }
        if [.pending2, .scroll, .pinch, .hold2Armed, .rightDrag, .pending3, .swiped].contains(phase) { phase = .spent }
        holdAt = nil; indicator = nil; autoPanAt = nil
        return out
    }
}
