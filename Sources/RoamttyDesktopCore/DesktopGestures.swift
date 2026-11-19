import Foundation

/// Touches to desktop input, after Apple's trackpad (docs/DESKTOP-GESTURES.md). The number of fingers
/// is the mouse button: one is left, two right, three middle. Taps act at once; holding a finger
/// (two for the right button) until the ring fills picks it up: lift to click with that button, or
/// move to drag. Two fingers scroll the host, with inertia; pinching zooms the picture locally.
/// `.mouse` is trackpad mode: one finger moves the cursor, with acceleration, and clicks act where it
/// is. `.touch` is direct touch, as on a phone: taps and holds act where the finger is, and a slide
/// scrolls what is under it, with inertia (zoomed in, it moves the picture first, then scrolls past its edge).
/// The cursor is the phone's: moves go out as absolute positions, so the host adds no acceleration
/// of its own and the cursor drawn here is where the host's is. Times are milliseconds.
public final class DesktopGestures {
    // The recognizer's state is internal rather than private only because its parts live in sibling files
    // (`DesktopGestures+*.swift`).
    public static let HOLD_MS: Int64 = 350
    /// Two fingers rest a moment before scrolling, so their hold is longer.
    public static let HOLD2_MS: Int64 = 500
    public static let DOUBLE_TAP_MS: Int64 = 300
    /// A multi-finger tap lifts within this.
    public static let TAP_MS: Int64 = 350
    /// Inertia frames.
    public static let FRAME_MS: Int64 = 16
    /// UIScrollView's normal deceleration, per millisecond.
    public static let DECELERATION: Float = 0.998

    public var mode: PointerMode
    let density: Float
    public var viewport = Viewport(viewWidth: 1, viewHeight: 1, remoteWidth: 1, remoteHeight: 1)
    /// Movement under this (view points) is still a tap or a hold.
    let slop: Float
    var doubleTapRadius: Float { 20 * density }
    var edgeZone: Float { 16 * density }

    /// The phone's cursor in native pixels: where the last move put it, or where the host said.
    public internal(set) var cursorX: Float = 0, cursorY: Float = 0
    public internal(set) var hasCursor = false
    var lastLocalMoveAt: Int64 = .min / 2
    /// The time of the event being handled.
    var now: Int64 = 0
    public internal(set) var indicator: HoldIndicator?

    struct Finger { var x: Float, y: Float, startX: Float, startY: Float }
    var fingers: [Int: Finger] = [:]
    /// Finger ids in landing order: multi-finger gestures use the first ones.
    var order: [Int] = []

    enum Phase {
        case idle
        case pending, moving, holdArmed, dragging, edgeDone
        case pending2, scroll, pinch, hold2Armed, rightDrag
        case pending3, swiped
        case spent
    }
    var phase = Phase.idle
    var peak = 0
    var startedAt: Int64 = 0
    var downX: Float = 0, downY: Float = 0
    /// Whether every finger stayed within the slop so far.
    var still = true
    var holdAt: Int64?
    var edge: (left: Bool, right: Bool, top: Bool, bottom: Bool)?
    /// Multi-finger centroid where the count last changed, and on the last move.
    var anchorX: Float = 0, anchorY: Float = 0, anchorSpan: Float = 0
    var lastX: Float = 0, lastY: Float = 0, lastSpan: Float = 0
    var lastMoveAt: Int64 = 0
    /// Smoothed velocity of the finger or centroid, points per millisecond.
    var vx: Float = 0, vy: Float = 0
    var wheelX: Float = 0, wheelY: Float = 0
    /// Touch mode: the last tap, so a second one nearby lands on the same pixel.
    var lastTap: LastTap?
    struct LastTap { let x: Float, y: Float, rx: Int, ry: Int, at: Int64 }
    /// A two-finger tap's right click waits a moment for a second tap, which zooms instead.
    var pendingRight: (at: Int64, x: Float, y: Float)?
    /// `panFirst`: a one-finger flick in touch mode, which moves a zoomed picture before scrolling.
    var inertia: (vx: Float, vy: Float, at: Int64, panFirst: Bool)?
    /// Touch mode: dragging near the edge of a zoomed picture moves it; when the last frame was.
    var autoPanAt: Int64?

    public init(mode: PointerMode = .touch, density: Float = 1) {
        self.mode = mode
        self.density = density
        slop = 10 * density
    }

    /// When `tick` next needs calling; nil when nothing is pending.
    public var tickAt: Int64? {
        [holdAt, pendingRight?.at, inertia.map { $0.at + Self.FRAME_MS }, autoPanAt.map { $0 + Self.FRAME_MS }].compactMap { $0 }.min()
    }

    /// The host's cursor. While the phone moved it lately, the phone's own position stands.
    public func hostCursor(x: Int, y: Int, time: Int64) {
        if !hasCursor || time - lastLocalMoveAt > 500 {
            cursorX = Float(x); cursorY = Float(y); hasCursor = true
        }
    }

    // MARK: Touches

    public func began(_ id: Int, _ x: Float, _ y: Float, time: Int64) -> [GestureAction] {
        now = time
        var out: [GestureAction] = []
        inertia = nil
        fingers[id] = Finger(x: x, y: y, startX: x, startY: y)
        order.removeAll { $0 == id }
        order.append(id)
        let n = fingers.count
        peak = max(peak, n)
        switch n {
        case 1:
            phase = .pending; peak = 1; startedAt = time; still = true
            downX = x; downY = y; lastX = x; lastY = y; lastMoveAt = time; vx = 0; vy = 0
            holdAt = time + Self.HOLD_MS
            edge = edgeOf(x, y)
            indicator = HoldIndicator(x: x, y: y, fingers: 1, armed: false, firesAt: time + Self.HOLD_MS)
        case 2:
            switch phase {
            case .pending, .moving:
                phase = .pending2
                let c = centroid(2)
                anchorX = c.x; anchorY = c.y; anchorSpan = c.span; lastX = c.x; lastY = c.y; lastSpan = c.span
                lastMoveAt = time; vx = 0; vy = 0; wheelX = 0; wheelY = 0
                holdAt = time + Self.HOLD2_MS
                indicator = HoldIndicator(x: c.x, y: c.y, fingers: 2, armed: false, firesAt: time + Self.HOLD2_MS)
            default:
                out += endOneFinger()
            }
        case 3:
            switch phase {
            case .pending2:
                flushRight(&out)
                phase = .pending3
                let c = centroid(3)
                anchorX = c.x; anchorY = c.y; holdAt = nil; indicator = nil
            case .scroll, .pinch:
                break // a third finger brushing the glass: the first two carry on
            default:
                out += endOneFinger() + endTwoFinger()
            }
        default:
            out += endOneFinger() + endTwoFinger()
        }
        return out
    }

    public func moved(_ id: Int, _ x: Float, _ y: Float, time: Int64) -> [GestureAction] {
        moved([(id, x, y)], time: time)
    }

    /// All the fingers that moved in one event.
    public func moved(_ touches: [(id: Int, x: Float, y: Float)], time: Int64) -> [GestureAction] {
        now = time
        for t in touches {
            guard var f = fingers[t.id] else { continue }
            f.x = t.x; f.y = t.y
            fingers[t.id] = f
            if length(f.x - f.startX, f.y - f.startY) >= slop { still = false }
        }
        guard !fingers.isEmpty else { return [] }
        var out: [GestureAction] = []
        switch phase {
        case .pending, .moving, .holdArmed, .dragging:
            guard let id = order.first, let f = fingers[id] else { return [] }
            out = moveOne(f.x, f.y, time: time)
        case .pending2, .scroll, .pinch, .hold2Armed, .rightDrag:
            guard fingers.count >= 2 else { return [] }
            out = moveTwo(time: time)
        case .pending3:
            guard fingers.count >= 3 else { return [] }
            let c = centroid(3)
            let dx = c.x - anchorX, dy = c.y - anchorY
            if length(dx, dy) >= 40 * density {
                phase = .swiped
                let dir: SwipeDirection = abs(dx) > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down)
                out = [.swipe(dir), .feedback(.shortcut)]
            }
        default:
            break
        }
        return out
    }

    public func ended(_ id: Int, _ x: Float, _ y: Float, time: Int64) -> [GestureAction] {
        guard let f = fingers[id] else { return [] }
        now = time
        if length(x - f.startX, y - f.startY) >= slop { still = false }
        fingers[id] = nil
        order.removeAll { $0 == id }
        let n = fingers.count
        var out: [GestureAction] = []
        if n < 2 {
            switch phase {
            case .scroll:
                // A pause before lifting leaves nothing to carry on.
                let speed = time - lastMoveAt > 60 ? 0 : length(vx, vy)
                if speed > 0.05 { inertia = (vx, vy, time, false) }
                phase = .spent
            case .pinch:
                phase = .spent
            case .hold2Armed:
                out += rightClick(anchorX, anchorY)
                phase = .spent
            case .rightDrag:
                out.append(.button(2, down: false))
                phase = .spent
            default:
                break
            }
        }
        if n == 0 { out += finish(time: time) }
        return out
    }

    /// The touches were taken away, or the screen is going: nothing may stay pressed.
    public func cancel() -> [GestureAction] {
        var out: [GestureAction] = []
        if phase == .dragging { out.append(.button(1, down: false)) }
        if phase == .rightDrag { out.append(.button(2, down: false)) }
        fingers.removeAll(); order.removeAll()
        phase = .idle; peak = 0; holdAt = nil; indicator = nil; pendingRight = nil; inertia = nil; autoPanAt = nil
        return out
    }

    public func tick(_ time: Int64) -> [GestureAction] {
        now = time
        var out: [GestureAction] = []
        if let p = pendingRight, time >= p.at { flushRight(&out) }
        if let at = holdAt, time >= at {
            holdAt = nil
            switch phase {
            case .pending where fingers.count == 1:
                flushRight(&out)
                phase = .holdArmed
                indicator = HoldIndicator(x: downX, y: downY, fingers: 1, armed: true, firesAt: at)
                if mode == .touch { out.append(moveTo(downX, downY)) }
                out.append(.feedback(.hold))
            case .pending2 where fingers.count >= 2:
                flushRight(&out)
                phase = .hold2Armed
                indicator = HoldIndicator(x: anchorX, y: anchorY, fingers: 2, armed: true, firesAt: at)
                if mode == .touch { out.append(moveTo(anchorX, anchorY)) }
                out.append(.feedback(.hold))
            default:
                break
            }
        }
        if var i = inertia, time >= i.at + Self.FRAME_MS {
            let dt = Float(time - i.at)
            let decay = Self.powf(Self.DECELERATION, dt)
            i.vx *= decay; i.vy *= decay; i.at = time
            out += i.panFirst ? swipe(i.vx * dt, i.vy * dt) : scroll(i.vx * dt, i.vy * dt)
            inertia = length(i.vx, i.vy) < 0.02 ? nil : i
        }
        if let at = autoPanAt, time >= at + Self.FRAME_MS { out += autoPan(time: time) }
        return out
    }

    // MARK: Helpers

    func setCursor(_ x: Float, _ y: Float) {
        cursorX = min(max(x, 0), Float(max(0, viewport.remoteWidth - 1)))
        cursorY = min(max(y, 0), Float(max(0, viewport.remoteHeight - 1)))
        hasCursor = true
        lastLocalMoveAt = now
    }

    func moveTo(_ x: Float, _ y: Float) -> GestureAction {
        let r = viewport.toRemote(x, y)
        setCursor(Float(r.x), Float(r.y))
        return .moveTo(x: r.x, y: r.y)
    }

    static func powf(_ base: Float, _ exp: Float) -> Float { Float(Foundation.pow(Double(base), Double(exp))) }
}
