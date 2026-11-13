import SwiftUI
import UIKit
import RoamttyCore
import RoamttyDesktopCore

/// A touch that starts on the network figures: a still hold picks them up to move them, anything else is
/// replayed to the picture as it came.
extension DesktopGestureView {
    func armHold() {
        holdTimer?.invalidate(); holdTimer = nil
        guard let at = overlay.holdAt else { return }
        let timer = Timer(timeInterval: max(0, Double(at - Self.nowMs()) / 1000), target: TickTarget(self),
                          selector: #selector(TickTarget.hold), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    func holdFired() {
        if routing == .pending, overlay.tick(Self.nowMs()) == .box { pickUp() }
    }

    /// The waiting touch is the picture's: what it did so far goes to `gestures` first, in order.
    func toPicture() {
        routing = .picture
        holdTimer?.invalidate(); holdTimer = nil
        let replay = held
        held = []
        for h in replay {
            switch h {
            case let .began(id, x, y, t): apply(gestures.began(id, x, y, time: t))
            case let .moved(m, t): apply(gestures.moved(m, time: t))
            case let .ended(id, x, y, t): apply(gestures.ended(id, x, y, time: t))
            }
        }
    }

    /// A still hold: the figures follow the finger; nothing of this touch reaches the host.
    func pickUp() {
        guard routing != .box else { return }
        routing = .box
        holdTimer?.invalidate(); holdTimer = nil
        held = []
        controller?.statsBox.startDrag(at: boxPoint)
        impact.impactOccurred()
    }

    func endRouting() {
        if routing == .box { controller?.statsBox.endDrag() }
        routing = .none
        overlay.reset()
        held = []
        boxTouch = nil
        holdTimer?.invalidate(); holdTimer = nil
    }
}
