/// The remote screen inside the view: fitted with letterboxing, then zoomed and panned locally.
/// Zoom never reaches the host; coordinates always come out in the display's native pixels.
/// Port of Android `desktop-core/DesktopGestures.kt` (roamtty #218). Sizes are view points on iOS
/// (Android uses pixels with a density; pass `density: 1` to `DesktopGestures` for points).
public struct Viewport: Equatable, Sendable {
    public var viewWidth: Float, viewHeight: Float
    public var remoteWidth: Int, remoteHeight: Int
    public var zoom: Float = 1, panX: Float = 0, panY: Float = 0

    public static let MAX_ZOOM: Float = 5

    public init(viewWidth: Float, viewHeight: Float, remoteWidth: Int, remoteHeight: Int, zoom: Float = 1, panX: Float = 0, panY: Float = 0) {
        self.viewWidth = viewWidth; self.viewHeight = viewHeight; self.remoteWidth = remoteWidth; self.remoteHeight = remoteHeight
        self.zoom = zoom; self.panX = panX; self.panY = panY
    }

    /// View pixels per native pixel at zoom 1.
    public var baseScale: Float {
        remoteWidth <= 0 || remoteHeight <= 0 ? 1 : min(viewWidth / Float(remoteWidth), viewHeight / Float(remoteHeight))
    }
    public var scale: Float { baseScale * zoom }
    public var contentWidth: Float { Float(remoteWidth) * scale }
    public var contentHeight: Float { Float(remoteHeight) * scale }
    /// Top-left of the content in the view.
    public var left: Float { (viewWidth - contentWidth) / 2 + panX }
    public var top: Float { (viewHeight - contentHeight) / 2 + panY }

    public func toRemote(_ x: Float, _ y: Float) -> (x: Int, y: Int) {
        (clampInt((x - left) / scale, max(0, remoteWidth - 1)), clampInt((y - top) / scale, max(0, remoteHeight - 1)))
    }

    public func contains(_ x: Float, _ y: Float) -> Bool { x >= left && y >= top && x < left + contentWidth && y < top + contentHeight }

    public func toView(_ rx: Float, _ ry: Float) -> (x: Float, y: Float) { (left + rx * scale, top + ry * scale) }

    /// Keeps the zoomed content covering the view where it can, and centred where it cannot.
    public func clamped() -> Viewport {
        func limit(_ content: Float, _ view: Float, _ pan: Float) -> Float {
            if content <= view { return 0 }
            let slack = (content - view) / 2
            return min(max(pan, -slack), slack)
        }
        var v = self
        v.panX = limit(contentWidth, viewWidth, panX)
        v.panY = limit(contentHeight, viewHeight, panY)
        return v
    }

    public func panned(_ dx: Float, _ dy: Float) -> Viewport {
        var v = self; v.panX += dx; v.panY += dy
        return v.clamped()
    }

    /// Zooms by `factor` keeping the point under (`fx`, `fy`) where it is.
    public func zoomed(_ factor: Float, _ fx: Float, _ fy: Float) -> Viewport {
        let next = min(max(zoom * factor, 1), Viewport.MAX_ZOOM)
        let ratio = next / zoom
        // The focus stays put: its offset from the view centre plus pan scales with the zoom.
        let cx = viewWidth / 2
        let cy = viewHeight / 2
        var v = self
        v.zoom = next
        v.panX = fx - cx - (fx - cx - panX) * ratio
        v.panY = fy - cy - (fy - cy - panY) * ratio
        return v.clamped()
    }
}

/// Kotlin's `toInt().coerceIn(0, hi)`: truncates toward zero, NaN as 0.
private func clampInt(_ v: Float, _ hi: Int) -> Int {
    let i: Int = v.isNaN ? 0 : v >= Float(Int32.max) ? Int(Int32.max) : v <= Float(Int32.min) ? Int(Int32.min) : Int(v)
    return min(max(i, 0), hi)
}

private func hypot(_ x: Float, _ y: Float) -> Float { (x * x + y * y).squareRoot() }

public enum PointerMode: Sendable { case touch, mouse }

/// What a gesture asks for: remote input, or a local change to the viewport.
public enum GestureAction: Equatable, Sendable {
    case moveTo(x: Int, y: Int)
    case moveBy(dx: Int, dy: Int)
    case button(Int, down: Bool)
    /// 1/120 of a notch; positive `dy` scrolls up.
    case wheel(dx: Int, dy: Int)
    case view(Viewport)
}

/// Turns touches into desktop input (plan §5.2). Touch mode: tap = left click where the finger is,
/// long press = right click, one finger dragging = a left-button drag from where it landed.
/// Mouse mode: one finger moves the cursor relatively, tap and long press click where it is, and a tap
/// then hold and drag drags, as on a laptop's touchpad: a tap's release waits `DOUBLE_TAP_MS` for that
/// second touch, so the host sees one press held through the drag, never a click and then a press.
/// Both: two fingers scroll, pinching zooms and pans locally, and once zoomed in two fingers move the
/// picture, scrolling only past its edge. Times are milliseconds; `tick` fires long presses and delayed releases.
public final class DesktopGestures {
    public static let LONG_PRESS_MS: Int64 = 500
    public static let DOUBLE_TAP_MS: Int64 = 300
    /// Wheel units (1/120 notch) per dp of two-finger travel.
    public static let WHEEL_PER_PX: Float = 4
    public static let MOUSE_SPEED: Float = 1.5

    public var mode: PointerMode
    private let density: Float
    public var viewport = Viewport(viewWidth: 1, viewHeight: 1, remoteWidth: 1, remoteHeight: 1)
    private let slop: Float
    private var downX: Float = 0, downY: Float = 0, lastX: Float = 0, lastY: Float = 0
    private var downAt: Int64 = 0
    private var moved = false, longPressed = false, dragging = false
    /// Mouse mode: the left button is still down after a tap, until this time.
    private var releaseAt: Int64?
    /// Mouse mode: this touch began while a tap still held the button.
    private var afterTap = false
    /// A second finger came and went: the rest of this touch does nothing.
    private var spent = false
    private var twoFinger: TwoFinger?
    private var down = false
    private var relRemainderX: Float = 0, relRemainderY: Float = 0

    private final class TwoFinger {
        var cx: Float, cy: Float, span: Float
        let startCx: Float, startCy: Float, startSpan: Float
        var kind = 0 // 0 undecided, 1 scroll, 2 pinch
        var wheelX: Float = 0, wheelY: Float = 0
        init(_ cx: Float, _ cy: Float, _ span: Float) { self.cx = cx; self.cy = cy; self.span = span; startCx = cx; startCy = cy; startSpan = span }
    }

    public init(mode: PointerMode = .touch, density: Float = 1) {
        self.mode = mode
        self.density = density
        slop = 10 * density
    }

    private var longPressAt: Int64? {
        down && !moved && !longPressed && !dragging && !afterTap && !spent && twoFinger == nil ? downAt + Self.LONG_PRESS_MS : nil
    }

    /// When `tick` next needs calling, for a long press or a tap's release; nil when nothing is pending.
    public var tickAt: Int64? { [longPressAt, releaseAt].compactMap { $0 }.min() }

    public func down(_ x: Float, _ y: Float, time: Int64) -> [GestureAction] {
        var out: [GestureAction] = []
        let held = releaseAt
        releaseAt = nil
        down = true
        downX = x; downY = y; lastX = x; lastY = y; downAt = time
        moved = false; longPressed = false; dragging = false; afterTap = false; spent = false
        // Mouse mode, a tap a moment ago: its press carries on into whatever this touch does.
        if let held, time < held, mode == .mouse { afterTap = true }
        else if held != nil { out.append(.button(1, down: false)) }
        return out
    }

    public func move(_ x: Float, _ y: Float, time: Int64) -> [GestureAction] {
        if !down || twoFinger != nil || spent { return [] }
        let dx = x - lastX, dy = y - lastY
        lastX = x; lastY = y
        if !moved && hypot(x - downX, y - downY) < slop { return [] }
        moved = true
        if longPressed { return [] }
        if mode == .mouse { if afterTap { dragging = true }; return rel(dx, dy) }
        if dragging { return [moveTo(x, y)] }
        // The press goes where the finger landed, so the drag picks up what was under it.
        dragging = true
        return [moveTo(downX, downY), .button(1, down: true), moveTo(x, y)]
    }

    public func up(_ x: Float, _ y: Float, time: Int64) -> [GestureAction] {
        if !down { return [] }
        down = false
        if twoFinger != nil { return [] }
        if dragging { dragging = false; return [.button(1, down: false)] }
        if afterTap {
            afterTap = false
            // A second tap without a drag: a double-click.
            return [.button(1, down: false), .button(1, down: true), .button(1, down: false)]
        }
        if longPressed || moved || spent { return [] }
        if mode == .mouse {
            releaseAt = time + Self.DOUBLE_TAP_MS
            return [.button(1, down: true)]
        }
        // Where the finger landed: lifting drifts a few pixels.
        return [moveTo(downX, downY), .button(1, down: true), .button(1, down: false)]
    }

    public func tick(_ time: Int64) -> [GestureAction] {
        var out: [GestureAction] = []
        if let r = releaseAt, time >= r { releaseAt = nil; out.append(.button(1, down: false)) }
        guard let at = longPressAt, time >= at else { return out }
        longPressed = true
        if mode == .touch { out.append(moveTo(downX, downY)) }
        out.append(.button(2, down: true))
        out.append(.button(2, down: false))
        return out
    }

    /// A second finger landed: whatever one finger was doing ends.
    public func twoDown(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> [GestureAction] {
        var out: [GestureAction] = []
        if dragging || afterTap { out.append(.button(1, down: false)); dragging = false; afterTap = false }
        twoFinger = TwoFinger((x0 + x1) / 2, (y0 + y1) / 2, hypot(x1 - x0, y1 - y0))
        return out
    }

    public func twoMove(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> [GestureAction] {
        guard let t = twoFinger else { return [] }
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        let span = hypot(x1 - x0, y1 - y0)
        if t.kind == 0 {
            if abs(span - t.startSpan) > 24 * density { t.kind = 2 }
            else if hypot(cx - t.startCx, cy - t.startCy) > 12 * density {
                t.kind = 1
                // Zoomed in, the picture follows the fingers from where they landed, not from the slop.
                if viewport.zoom > 1 { t.cx = t.startCx; t.cy = t.startCy }
            }
        }
        var out: [GestureAction] = []
        switch t.kind {
        case 1:
            var dx = cx - t.cx, dy = cy - t.cy
            // Zoomed in, two fingers move the picture; only what is left past its edge scrolls the host.
            if viewport.zoom > 1 {
                let next = viewport.panned(dx, dy)
                dx -= next.panX - viewport.panX
                dy -= next.panY - viewport.panY
                if next != viewport { viewport = next; out.append(.view(next)) }
            }
            // Fingers moving down pull the page down, as on a phone: the wheel scrolls up.
            t.wheelX += dx * Self.WHEEL_PER_PX / density
            t.wheelY += dy * Self.WHEEL_PER_PX / density
            let wx = Int(t.wheelX), wy = Int(t.wheelY)
            if wx != 0 || wy != 0 {
                t.wheelX -= Float(wx); t.wheelY -= Float(wy)
                out.append(.wheel(dx: -wx, dy: wy))
            }
        case 2:
            if t.span > 0 {
                viewport = viewport.zoomed(span / t.span, cx, cy).panned(cx - t.cx, cy - t.cy)
                out.append(.view(viewport))
            }
        default:
            break
        }
        t.cx = cx; t.cy = cy; t.span = span
        return out
    }

    /// Fewer than two fingers again: the gesture is over until every finger lifts.
    public func twoUp() { twoFinger = nil; spent = true }

    /// The touch was taken away, or the screen is going: nothing may stay pressed.
    public func cancel() -> [GestureAction] {
        let out: [GestureAction] = dragging || afterTap || releaseAt != nil ? [.button(1, down: false)] : []
        down = false; dragging = false; afterTap = false; releaseAt = nil; twoFinger = nil
        return out
    }

    private func moveTo(_ x: Float, _ y: Float) -> GestureAction {
        let r = viewport.toRemote(x, y)
        return .moveTo(x: r.x, y: r.y)
    }

    /// Finger travel in view pixels to cursor travel in native pixels, as if dragging on the picture.
    private func rel(_ dx: Float, _ dy: Float) -> [GestureAction] {
        relRemainderX += dx / viewport.scale * Self.MOUSE_SPEED
        relRemainderY += dy / viewport.scale * Self.MOUSE_SPEED
        let ix = Int(relRemainderX), iy = Int(relRemainderY)
        if ix == 0 && iy == 0 { return [] }
        relRemainderX -= Float(ix); relRemainderY -= Float(iy)
        return [.moveBy(dx: ix, dy: iy)]
    }
}
