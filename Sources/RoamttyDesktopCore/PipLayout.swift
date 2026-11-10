import Foundation

/// A rectangle in points, for `PipLayout`.
public struct PipRect: Equatable, Sendable {
    public var left: Double, top: Double, right: Double, bottom: Double
    public init(_ left: Double, _ top: Double, _ right: Double, _ bottom: Double) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    public var width: Double { right - left }
    public var height: Double { bottom - top }
    public var centerX: Double { (left + right) / 2 }
    public var centerY: Double { (top + bottom) / 2 }
}

/// Where the small window (a host's desktop over its terminal) goes and how big it is, as Android's `PipLayout`.
/// Its size is a fraction of the screen it was dragged or pinched to; its place is wherever it was dragged, kept as
/// fractions of the room it can move in, so it stays in the same spot when that room changes (the keyboard opens,
/// the phone turns).
public enum PipLayout {
    public static let minFraction = 0.3
    public static let maxFraction = 1.0

    /// The window's size: `fraction` of `reference` wide at `aspect` (width / height), kept inside `room`: a room
    /// too low makes it smaller, keeping its aspect.
    public static func size(room: PipRect, reference: Double, fraction: Double, aspect: Double) -> (width: Double, height: Double) {
        let a = max(aspect, 0.1)
        var w = max(min(reference * clampFraction(fraction), room.width), 1)
        var h = w / a
        if h > room.height { h = max(room.height, 1); w = h * a }
        return (w, h)
    }

    /// A `w`×`h` window at `fx`, `fy` of the room it can move in: 0, 0 the top left corner, 1, 1 the bottom right.
    public static func place(room: PipRect, width w: Double, height h: Double, fx: Double, fy: Double) -> PipRect {
        let left = room.left + max(room.width - w, 0) * min(max(fx, 0), 1)
        let top = room.top + max(room.height - h, 0) * min(max(fy, 0), 1)
        return PipRect(left, top, left + w, top + h)
    }

    /// The fractions `place` takes for a `w`×`h` window dropped with its top left at `left`, `top` (kept inside).
    public static func fractions(room: PipRect, width w: Double, height h: Double, left: Double, top: Double) -> (x: Double, y: Double) {
        let freeX = room.width - w, freeY = room.height - h
        return (freeX > 0 ? min(max((left - room.left) / freeX, 0), 1) : 0,
                freeY > 0 ? min(max((top - room.top) / freeY, 0), 1) : 0)
    }

    /// Where the focused window's `bar`-high bar goes: `gap` above it, else `gap` below it, else (a window as tall as
    /// the room, or the keyboard up) over its top edge, so it always stays inside `room` and its buttons reachable.
    public static func barTop(room: PipRect, window: PipRect, bar: Double, gap: Double) -> Double {
        if window.top - bar - gap >= room.top { return window.top - bar - gap }
        if window.bottom + gap + bar <= room.bottom { return window.bottom + gap }
        return max(min(window.top + gap, room.bottom - bar), room.top)
    }

    /// Whether the resize handle goes on the window's left: the side with more room to grow into (the right on a tie).
    public static func handleOnLeft(room: PipRect, window: PipRect) -> Bool {
        window.left - room.left > room.right - window.right + 1
    }

    /// The width a drag of the resize handle by `dx`, `dy` gives a `width` window at `aspect`: outwards (away from
    /// the window, right or left as `onLeft` says, and down) grows it, both directions counting.
    public static func resized(width: Double, dx: Double, dy: Double, onLeft: Bool, aspect: Double) -> Double {
        width + ((onLeft ? -dx : dx) + dy * max(aspect, 0.1)) / 2
    }

    /// Whether a window dragged with its centre at `cx`, `cy` is over the close target centred at `tx`, `ty`.
    public static func overClose(cx: Double, cy: Double, tx: Double, ty: Double, radius: Double) -> Bool {
        hypot(cx - tx, cy - ty) <= radius
    }

    /// The fraction a pinch by `zoom` from `start` gives, within `minFraction` and `maxFraction`.
    public static func pinched(_ start: Double, zoom: Double) -> Double { clampFraction(start * zoom) }

    public static func clampFraction(_ f: Double) -> Double { min(max(f, minFraction), maxFraction) }
}
