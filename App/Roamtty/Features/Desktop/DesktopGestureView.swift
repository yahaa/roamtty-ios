import SwiftUI
import UIKit
import RoamttyCore
import RoamttyDesktopCore

/// The page's touch surface: hands the picture's touches to `DesktopGestureView`.
struct DesktopGestureOverlay: UIViewRepresentable {
    @ObservedObject var controller: DesktopController
    let size: CGSize
    /// In the small window over the terminal: a hardware keyboard types on the host only while `keys`, and edge
    /// swipes stay the system's.
    var small = false
    var keys = true

    func makeUIView(context: Context) -> DesktopGestureView {
        let view = DesktopGestureView()
        view.small = small
        view.controller = controller
        return view
    }
    func updateUIView(_ uiView: DesktopGestureView, context: Context) {
        uiView.controller = controller
        uiView.boundsSize = size
        uiView.hostCursorChanged(controller.cursor)
        if small {
            uiView.accessibilityIdentifier = "pip-desktop-gestures"
            if keys, uiView.window != nil, !uiView.isFirstResponder { uiView.becomeFirstResponder() }
            if !keys, uiView.isFirstResponder { uiView.resignFirstResponder() }
        }
    }
    static func dismantleUIView(_ uiView: DesktopGestureView, coordinator: ()) {
        uiView.stopTicking()
        uiView.controller = nil
    }
}
///
/// The view's state is internal rather than private only because its parts live in sibling files
/// (`DesktopGestureView+*.swift`).
final class DesktopGestureView: UIView {
    weak var controller: DesktopController?
    var boundsSize: CGSize = .zero
    /// The small window's picture: it takes the keyboard only when asked (`DesktopGestureOverlay.keys`).
    var small = false
    let gestures = DesktopGestures(mode: .touch, density: 1)
    /// Fires once, when `gestures` next needs a tick (a hold, a waiting right click, inertia); nil while nothing waits.
    var tickTimer: Timer?
    /// The timer's target: the run loop retains it, never the view.
    final class TickTarget: NSObject {
        weak var view: DesktopGestureView?
        init(_ view: DesktopGestureView) { self.view = view }
        @objc func tick() { view?.tick() }
        @objc func hold() { view?.holdFired() }
    }
    /// Each finger's id for `gestures`, for as long as it touches.
    var touchIDs: [ObjectIdentifier: Int] = [:]
    var nextTouchID = 0
    var lastTouchEnded: Int64 = 0

    /// A touch that starts on the network figures waits: a still hold moves them, anything else is replayed to
    /// the picture as it came (`OverlayTouch`), so the figures never take a gesture from the desktop.
    let overlay = OverlayTouch(slop: 10)
    /// Who has the touches since the first finger came down, until the last lifts.
    var routing: OverlayTouch.Owner = .none
    /// What a waiting touch did so far, replayed to `gestures` if it turns out to be the picture's.
    enum Held {
        case began(Int, Float, Float, Int64)
        case moved([(id: Int, x: Float, y: Float)], Int64)
        case ended(Int, Float, Float, Int64)
    }
    var held: [Held] = []
    var holdTimer: Timer?
    var boxTouch: ObjectIdentifier?
    var boxPoint: CGPoint = .zero

    let cursorLayer = CALayer()
    var cursorShape: CursorImage?
    var cursorShown: RemoteCursor?
    let ringLayer = CAShapeLayer()
    var ringShown: HoldIndicator?
    let impact = UIImpactFeedbackGenerator(style: .medium)
    let tapFeel = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        cursorLayer.contentsScale = UIScreen.main.scale
        cursorLayer.contentsGravity = .resize
        cursorLayer.magnificationFilter = .nearest
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 2
        layer.addSublayer(cursorLayer)
        ringLayer.isHidden = true
        ringLayer.zPosition = 1
        layer.addSublayer(ringLayer)
        accessibilityIdentifier = "desktop-gestures"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    deinit { tickTimer?.invalidate(); holdTimer?.invalidate() }

    /// Three-finger swipes are the host's, not the system's undo and redo.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    /// Arms the timer for `gestures.tickAt`, instead of ticking every display frame while the page shows.
    func scheduleTick() {
        tickTimer?.invalidate(); tickTimer = nil
        guard window != nil, let at = gestures.tickAt else { return }
        let timer = Timer(timeInterval: max(0, Double(at - Self.nowMs()) / 1000), target: TickTarget(self),
                          selector: #selector(TickTarget.tick), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func stopTicking() {
        touchIDs.removeAll()
        endRouting()
        apply(gestures.cancel())
        tickTimer?.invalidate(); tickTimer = nil
    }

    /// The clock touches carry: seconds since boot.
    static func nowMs() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
    static func ms(_ touch: UITouch) -> Int64 { Int64(touch.timestamp * 1000) }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncViewport()
        refreshCursor()
    }

    func syncViewport() {
        guard let c = controller else { return }
        gestures.mode = c.page.pointerMode
        let w = Float(bounds.width > 0 ? bounds.width : boundsSize.width)
        let h = Float(bounds.height > 0 ? bounds.height : boundsSize.height)
        var vp = gestures.viewport
        vp.viewWidth = max(1, w); vp.viewHeight = max(1, h)
        let remote = (max(1, c.remoteSize.0), max(1, c.remoteSize.1))
        // A new screen size starts unzoomed, as on Android.
        if (vp.remoteWidth, vp.remoteHeight) != remote { vp = Viewport(viewWidth: vp.viewWidth, viewHeight: vp.viewHeight, remoteWidth: remote.0, remoteHeight: remote.1) }
        show(vp.clamped())
    }

    func hostCursorChanged(_ cursor: RemoteCursor?) {
        guard let cursor, cursor != cursorShown else { return }
        cursorShown = cursor
        gestures.hostCursor(x: cursor.x, y: cursor.y, time: Self.nowMs())
        refreshCursor()
    }

    @objc func tick() {
        apply(gestures.tick(Self.nowMs()))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        syncViewport()
        #if DEBUG
        // A double tap's second tap belongs with the first.
        if touchIDs.isEmpty, Self.nowMs() - lastTouchEnded > 500 { controller?.probeGestureStarted() }
        #endif
        for t in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let first = touchIDs.isEmpty
            let id = nextTouchID; nextTouchID += 1
            touchIDs[ObjectIdentifier(t)] = id
            let p = t.location(in: self)
            if first {
                routing = overlay.down(onBox: controller?.statsBox.contains(p) == true, Float(p.x), Float(p.y), time: Self.ms(t))
                if routing == .pending {
                    boxTouch = ObjectIdentifier(t); boxPoint = p
                    held = [.began(id, Float(p.x), Float(p.y), Self.ms(t))]
                    armHold()
                    continue
                }
            } else if routing == .pending {
                overlay.otherFinger()
                toPicture()
            }
            if routing == .picture { apply(gestures.began(id, Float(p.x), Float(p.y), time: Self.ms(t))) }
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let moved = touches.compactMap { t -> (id: Int, x: Float, y: Float)? in
            guard let id = touchIDs[ObjectIdentifier(t)] else { return nil }
            let p = t.location(in: self)
            return (id, Float(p.x), Float(p.y))
        }
        guard !moved.isEmpty else { return }
        let time = touches.map(Self.ms).max() ?? Self.nowMs()
        let finger = touches.first { ObjectIdentifier($0) == boxTouch }.map { $0.location(in: self) }
        switch routing {
        case .picture:
            apply(gestures.moved(moved, time: time))
        case .pending:
            held.append(.moved(moved, time))
            guard let finger else { return }
            boxPoint = finger
            switch overlay.moved(Float(finger.x), Float(finger.y), time: time) {
            case .picture: toPicture()
            case .box: pickUp(); controller?.statsBox.drag(to: finger)
            default: break
            }
        case .box:
            if let finger { controller?.statsBox.drag(to: finger) }
        case .none:
            break
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(t)) else { continue }
            let p = t.location(in: self)
            switch routing {
            case .picture:
                apply(gestures.ended(id, Float(p.x), Float(p.y), time: Self.ms(t)))
            case .pending:
                // Only the first finger can be down while a touch waits.
                held.append(.ended(id, Float(p.x), Float(p.y), Self.ms(t)))
                if overlay.up(time: Self.ms(t)) == .box { pickUp(); controller?.statsBox.endDrag() } else { toPicture() }
            case .box:
                if ObjectIdentifier(t) == boxTouch { controller?.statsBox.endDrag(); boxTouch = nil }
            case .none:
                break
            }
            lastTouchEnded = Self.ms(t)
        }
        if touchIDs.isEmpty { endRouting() }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchIDs.removeAll()
        if routing == .picture { apply(gestures.cancel()) }
        endRouting()
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key, let hid = HidUsage.fromKeyboardHIDUsage(Int(key.keyCode.rawValue)) {
                controller?.input(DesktopProtocol.key(hid, down: true))
            }
        }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key, let hid = HidUsage.fromKeyboardHIDUsage(Int(key.keyCode.rawValue)) {
                controller?.input(DesktopProtocol.key(hid, down: false))
            }
        }
        super.pressesEnded(presses, with: event)
    }
    override var canBecomeFirstResponder: Bool { true }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            if !small {
                becomeFirstResponder()
                InteractivePopGesture.desktop = self
            }
            scheduleTick()
        } else {
            stopTicking()
            if InteractivePopGesture.desktop === self { InteractivePopGesture.desktop = nil }
        }
    }

    /// Whether an edge swipe from this point (view coordinates) is the desktop's: it starts on the picture.
    func keepsEdgeSwipe(at point: CGPoint) -> Bool {
        controller?.remoteSize.0 ?? 0 > 0 && gestures.viewport.contains(Float(point.x), Float(point.y))
    }

    func show(_ vp: Viewport) {
        gestures.viewport = vp
        // Layout calls this inside a SwiftUI update, which must not publish.
        DispatchQueue.main.async { [weak self] in
            if let c = self?.controller, c.viewport != vp { c.viewport = vp }
        }
    }

    func apply(_ actions: [GestureAction]) {
        // Every gesture call comes through here, so the next tick follows whatever it changed.
        defer { scheduleTick(); refreshCursor(); refreshRing() }
        guard let c = controller else { return }
        for a in actions {
            switch a {
            case .moveTo(let x, let y):
                c.input(DesktopProtocol.abs(display: c.displayIndex, x: x, y: y))
            case .button(let b, let down):
                c.input(DesktopProtocol.button(b, down: down))
            case .wheel(let dx, let dy):
                c.input(DesktopProtocol.wheel(dx: dx, dy: dy))
            case .view(let vp):
                show(vp)
            case .swipe(let direction):
                DesktopSwipeShortcut.frames(direction, os: c.hello?.os ?? c.host.system).forEach(c.input)
            case .feedback(let kind):
                switch kind {
                case .hold, .pickup: impact.impactOccurred()
                case .click, .shortcut: tapFeel.impactOccurred()
                }
            }
            #if DEBUG
            c.probeInput(a)
            #endif
        }
    }
}
