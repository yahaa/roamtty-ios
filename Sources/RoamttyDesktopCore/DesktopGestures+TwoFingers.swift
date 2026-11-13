import Foundation

/// Two fingers: scrolling, with inertia, and pinching.
extension DesktopGestures {
    func centroid(_ count: Int) -> (x: Float, y: Float, span: Float) {
        let pts = order.prefix(count).compactMap { fingers[$0] }
        guard !pts.isEmpty else { return (lastX, lastY, lastSpan) }
        let x = pts.map(\.x).reduce(0, +) / Float(pts.count), y = pts.map(\.y).reduce(0, +) / Float(pts.count)
        let span = pts.count >= 2 ? length(pts[1].x - pts[0].x, pts[1].y - pts[0].y) : 0
        return (x, y, span)
    }

    func moveTwo(time: Int64) -> [GestureAction] {
        let c = centroid(2)
        let dx = c.x - lastX, dy = c.y - lastY
        let dt = Float(max(1, time - lastMoveAt))
        track(dx / dt, dy / dt)
        var out: [GestureAction] = []
        if phase == .pending2 {
            if abs(c.span - anchorSpan) > 24 * density {
                phase = .pinch
            } else if length(c.x - anchorX, c.y - anchorY) > 12 * density {
                phase = .scroll
            }
            if phase != .pending2 { flushRight(&out); holdAt = nil; indicator = nil }
            if phase == .scroll && mode == .touch { out.append(moveTo(anchorX, anchorY)) }
        }
        switch phase {
        case .scroll:
            out += scroll(dx, dy)
        case .pinch:
            if lastSpan > 0 {
                viewport = viewport.zoomed(c.span / lastSpan, c.x, c.y).panned(dx, dy)
                out.append(.view(viewport))
            }
        case .hold2Armed:
            if length(c.x - anchorX, c.y - anchorY) >= slop {
                phase = .rightDrag
                indicator = nil
                if mode == .touch {
                    out += [moveTo(anchorX, anchorY), .button(2, down: true), .feedback(.pickup), moveTo(c.x, c.y)]
                    lastX = c.x; lastY = c.y
                    armAutoPan(time)
                } else {
                    out += [.button(2, down: true), .feedback(.pickup)] + follow(c.x, c.y, dx, dy)
                }
            }
        case .rightDrag:
            if mode == .touch { lastX = c.x; lastY = c.y; armAutoPan(time) }
            out += follow(c.x, c.y, dx, dy)
        default:
            break
        }
        lastX = c.x; lastY = c.y; lastSpan = c.span; lastMoveAt = time
        return out
    }

    /// Wheel units per point of finger travel: about what moves the content with the fingers.
    var wheelPerPoint: Float { min(max(2.5 / viewport.scale, 2), 12) / density }

    /// Touch mode, one finger: zoomed in, the picture follows the finger, and only what is left past
    /// its edge scrolls the host, as a zoomed photo on a phone; at full size it all scrolls.
    func swipe(_ dx: Float, _ dy: Float) -> [GestureAction] {
        var out: [GestureAction] = []
        var rx = dx, ry = dy
        if viewport.zoom > 1 {
            let next = viewport.panned(dx, dy)
            rx -= next.panX - viewport.panX
            ry -= next.panY - viewport.panY
            if next != viewport { viewport = next; out.append(.view(next)) }
        }
        return out + scroll(rx, ry)
    }

    /// Fingers moving down pull the page down, as on a phone: the wheel scrolls up.
    func scroll(_ dx: Float, _ dy: Float) -> [GestureAction] {
        wheelX += dx * wheelPerPoint
        wheelY += dy * wheelPerPoint
        let wx = Int(wheelX), wy = Int(wheelY)
        // A few units at a time: macOS turns three of them into one pixel and drops the rest.
        guard abs(wx) >= 3 || abs(wy) >= 3 else { return [] }
        wheelX -= Float(wx); wheelY -= Float(wy)
        return [.wheel(dx: -wx, dy: wy)]
    }

    func track(_ nvx: Float, _ nvy: Float) {
        vx = vx * 0.4 + nvx * 0.6
        vy = vy * 0.4 + nvy * 0.6
    }
}
