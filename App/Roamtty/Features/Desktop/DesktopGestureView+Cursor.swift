import SwiftUI
import UIKit
import RoamttyCore
import RoamttyDesktopCore

/// What the gestures draw on the phone: the cursor where the phone put it, and the hold ring.
extension DesktopGestureView {

    /// The host's cursor image at the picture's scale, kept between 15 and 24 pt (the picture is often a
    /// fifth of the host's size, and zoomed in five times); an arrow until it sends one, about iOS's own pointer size.
    func refreshCursor() {
        let visible = cursorShown?.visible ?? true
        guard gestures.hasCursor, visible, controller?.remoteSize.0 ?? 0 > 0 else { cursorLayer.isHidden = true; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let shape = cursorShown?.shape
        if shape != cursorShape || cursorLayer.contents == nil {
            cursorShape = shape
            if let shape, let image = Self.image(shape) {
                cursorLayer.contents = image
                cursorLayer.anchorPoint = CGPoint(x: CGFloat(shape.hotX) / CGFloat(max(1, shape.width)), y: CGFloat(shape.hotY) / CGFloat(max(1, shape.height)))
            } else {
                cursorLayer.contents = Self.arrow
                cursorLayer.anchorPoint = CGPoint(x: 1.5 / 14, y: 1.5 / 21)
            }
        }
        let vp = gestures.viewport
        if let shape = cursorShape {
            let size = CGFloat(max(1, shape.height, shape.width))
            let s = min(max(CGFloat(vp.scale), 15 / size), 24 / size)
            cursorLayer.bounds = CGRect(x: 0, y: 0, width: CGFloat(shape.width) * s, height: CGFloat(shape.height) * s)
        } else {
            cursorLayer.bounds = CGRect(x: 0, y: 0, width: 10, height: 15)
        }
        let p = vp.toView(gestures.cursorX, gestures.cursorY)
        cursorLayer.position = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        cursorLayer.isHidden = false
    }

    static func image(_ shape: CursorImage) -> CGImage? {
        guard shape.width > 0, shape.height > 0, shape.rgba.count >= shape.width * shape.height * 4,
              let provider = CGDataProvider(data: Data(shape.rgba) as CFData) else { return nil }
        return CGImage(width: shape.width, height: shape.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: shape.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The standard arrow, white with a black edge, its tip the hot spot.
    static let arrow: CGImage? = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: CGSize(width: 14, height: 21), format: format).image { ctx in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 1.5, y: 1.5))
            path.addLine(to: CGPoint(x: 1.5, y: 17))
            path.addLine(to: CGPoint(x: 5.5, y: 13.2))
            path.addLine(to: CGPoint(x: 8.3, y: 19.5))
            path.addLine(to: CGPoint(x: 10.8, y: 18.4))
            path.addLine(to: CGPoint(x: 8.1, y: 12.3))
            path.addLine(to: CGPoint(x: 13, y: 12.3))
            path.close()
            UIColor.white.setFill(); path.fill()
            UIColor.black.setStroke(); path.lineWidth = 1.2; path.lineJoinStyle = .round; path.stroke()
            _ = ctx
        }.cgImage
    }()

    /// The hold ring: it fills while a hold is coming, then turns solid, blue for the left button, red for the right.
    func refreshRing() {
        let next = gestures.indicator
        guard next != ringShown else { return }
        ringShown = next
        ringLayer.removeAllAnimations()
        guard let next else { ringLayer.isHidden = true; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let r: CGFloat = next.fingers > 1 ? 34 : 26
        ringLayer.path = UIBezierPath(arcCenter: .zero, radius: r, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true).cgPath
        ringLayer.position = CGPoint(x: CGFloat(next.x), y: CGFloat(next.y))
        let color = next.fingers > 1 ? UIColor.systemRed : UIColor.systemBlue
        ringLayer.lineWidth = 3
        ringLayer.isHidden = false
        if next.armed {
            ringLayer.strokeColor = color.cgColor
            ringLayer.fillColor = color.withAlphaComponent(0.3).cgColor
            ringLayer.strokeEnd = 1
            ringLayer.opacity = 1
        } else {
            // Nothing shows for a tap: the ring starts after a moment and fills as the hold comes.
            ringLayer.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
            ringLayer.fillColor = UIColor.clear.cgColor
            ringLayer.strokeEnd = 1
            // A tap lasts under 0.2 s: only a finger still down after that sees the ring.
            let delay = 0.2
            let total = max(0.05, Double(next.firesAt - Self.nowMs()) / 1000 - delay)
            let fill = CABasicAnimation(keyPath: "strokeEnd")
            fill.fromValue = 0; fill.toValue = 1
            fill.beginTime = CACurrentMediaTime() + delay; fill.duration = total
            fill.fillMode = .both
            ringLayer.add(fill, forKey: "fill")
        }
        CATransaction.commit()
        if next.armed { impact.prepare() } else { impact.prepare(); tapFeel.prepare() }
    }
}
