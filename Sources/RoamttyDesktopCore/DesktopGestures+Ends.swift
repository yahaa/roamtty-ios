import Foundation

/// What a gesture comes to when the last finger lifts: clicks, taps and the smart zoom.
extension DesktopGestures {
    func finish(time: Int64) -> [GestureAction] {
        var out: [GestureAction] = []
        switch phase {
        case .pending:
            flushRight(&out)
            if mode == .touch {
                // Where the finger landed, or a moment ago nearby: a double-click lands on one pixel.
                var r = viewport.toRemote(downX, downY)
                if let t = lastTap, startedAt - t.at <= Self.DOUBLE_TAP_MS, length(downX - t.x, downY - t.y) <= doubleTapRadius {
                    r = (t.rx, t.ry)
                }
                lastTap = LastTap(x: downX, y: downY, rx: r.x, ry: r.y, at: time)
                setCursor(Float(r.x), Float(r.y))
                out += [.moveTo(x: r.x, y: r.y), .button(1, down: true), .button(1, down: false)]
            } else {
                out += [.button(1, down: true), .button(1, down: false)]
            }
        case .moving where mode == .touch:
            let speed = time - lastMoveAt > 60 ? 0 : length(vx, vy)
            if speed > 0.05 { inertia = (vx, vy, time, true) }
        case .holdArmed:
            out += rightClick(downX, downY)
        case .dragging:
            out.append(.button(1, down: false))
        case .pending2:
            if still && time - startedAt <= Self.TAP_MS {
                if pendingRight != nil {
                    pendingRight = nil
                    out += smartZoom(anchorX, anchorY)
                } else {
                    pendingRight = (time + Self.DOUBLE_TAP_MS, anchorX, anchorY)
                }
            }
        case .pending3:
            if still && time - startedAt <= Self.TAP_MS {
                if mode == .touch { out.append(moveTo(anchorX, anchorY)) }
                out += [.button(3, down: true), .button(3, down: false), .feedback(.click)]
            }
        default:
            break
        }
        phase = .idle; peak = 0; holdAt = nil; indicator = nil; autoPanAt = nil
        return out
    }

    func rightClick(_ x: Float, _ y: Float) -> [GestureAction] {
        (mode == .touch ? [moveTo(x, y)] : []) + [.button(2, down: true), .button(2, down: false), .feedback(.click)]
    }

    func flushRight(_ out: inout [GestureAction]) {
        guard let p = pendingRight else { return }
        pendingRight = nil
        out += rightClick(p.x, p.y)
    }

    /// Two-finger double tap, as on a Mac: zoom in on that spot, or back out to the whole screen.
    func smartZoom(_ x: Float, _ y: Float) -> [GestureAction] {
        if viewport.zoom > 1.01 {
            viewport = Viewport(viewWidth: viewport.viewWidth, viewHeight: viewport.viewHeight,
                                remoteWidth: viewport.remoteWidth, remoteHeight: viewport.remoteHeight)
        } else {
            viewport = viewport.zoomed(2.5 / viewport.zoom, x, y)
        }
        return [.view(viewport), .feedback(.shortcut)]
    }
}
