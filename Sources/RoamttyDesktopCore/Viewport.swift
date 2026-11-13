import Foundation

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

/// The length of the vector (x, y).
func length(_ x: Float, _ y: Float) -> Float { (x * x + y * y).squareRoot() }
