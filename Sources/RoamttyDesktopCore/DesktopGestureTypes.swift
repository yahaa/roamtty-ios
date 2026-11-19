import Foundation

public enum PointerMode: Sendable { case touch, mouse }

public enum SwipeDirection: Sendable, Equatable { case up, down, left, right }

/// What the phone should feel or show, never sent to the host.
public enum GestureFeedback: Sendable, Equatable {
    /// A hold was recognised: lift for a right click, or move to drag.
    case hold
    /// A held finger started a drag: the button went down.
    case pickup
    /// A click that needed a hold or a second finger (right, middle).
    case click
    /// A three-finger swipe, an edge swipe or a smart zoom.
    case shortcut
}

/// What a gesture asks for: remote input, a local change to the viewport, or feedback.
public enum GestureAction: Equatable, Sendable {
    case moveTo(x: Int, y: Int)
    /// 1 left, 2 right, 3 middle.
    case button(Int, down: Bool)
    /// 1/120 of a notch; positive `dy` scrolls up.
    case wheel(dx: Int, dy: Int)
    case view(Viewport)
    /// Three fingers swiped: the page turns it into the host's shortcut.
    case swipe(SwipeDirection)
    case feedback(GestureFeedback)
}

/// A hold in progress, for the ring the page draws under the fingers (view points).
public struct HoldIndicator: Equatable, Sendable {
    public let x: Float, y: Float
    public let fingers: Int
    /// False while waiting for the hold, true once it fired.
    public let armed: Bool
    /// When the hold fires, while waiting for it.
    public let firesAt: Int64
}

/// Three-finger swipes as the host's own shortcuts: up shows every window, down the desktop (the
/// plugin's actions, which know each system), left and right switch to the desktop on that side.
public enum DesktopSwipeShortcut {
    public static func frames(_ direction: SwipeDirection, os: String) -> [[UInt8]] {
        func combo(_ keys: [Int]) -> [[UInt8]] {
            keys.map { DesktopProtocol.key($0, down: true) } + keys.reversed().map { DesktopProtocol.key($0, down: false) }
        }
        let modifiers: [Int]
        switch os.lowercased() {
        case "macos": modifiers = [HidUsage.LEFT_CTRL]
        case "windows": modifiers = [HidUsage.LEFT_CTRL, HidUsage.LEFT_GUI]
        default: modifiers = [HidUsage.LEFT_CTRL, HidUsage.LEFT_ALT]
        }
        switch direction {
        case .up: return [DesktopProtocol.action(DesktopProtocol.ACTION_ALL_WINDOWS)]
        case .down: return [DesktopProtocol.action(DesktopProtocol.ACTION_SHOW_DESKTOP)]
        // Fingers going left bring in the desktop on the right, as on a trackpad.
        case .left: return combo(modifiers + [HidUsage.RIGHT])
        case .right: return combo(modifiers + [HidUsage.LEFT])
        }
    }
}
