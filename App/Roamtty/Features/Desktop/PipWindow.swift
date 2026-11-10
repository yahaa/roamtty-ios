import SwiftUI
import UIKit
import RoamttyDesktopCore

/// Where the small window sits (`x`, `y`: fractions of the room it moves in, 0, 0 the top left) and how wide it is
/// (`fraction` of the screen), remembered under its key once moved or resized (Android `PipState`).
@MainActor final class PipState: ObservableObject {
    let key: String
    @Published var x: Double
    @Published var y: Double
    @Published var fraction: Double
    private let defaults: UserDefaults

    init(key: String, defaultFraction: Double, defaults: UserDefaults = .standard) {
        self.key = key; self.defaults = defaults
        let saved = defaults.dictionary(forKey: "pip.\(key)") as? [String: Double]
        x = saved?["x"] ?? 1
        y = saved?["y"] ?? 0
        fraction = saved?["fraction"] ?? defaultFraction
    }

    func save() { defaults.set(["x": x, "y": y, "fraction": fraction], forKey: "pip.\(key)") }
}

/// The small window: a host's desktop over its terminal (Android `PipWindow`), placed in a page-sized box whose
/// coordinates `room` is in.
///
/// Not `focused`, the window is a thing to place: a drag puts it anywhere in `room` (dropped on the close target that
/// appears at the bottom, it is `onClose`), a pinch or the grip in its corner resizes it, and a tap is `onTap`
/// (which focuses it). `focused`, every touch on the picture is the desktop's, exactly as on the desktop page; the
/// window is then moved by the bar above it, which also holds the keyboard (`onKeyboard`, lit while
/// `keyboardOpen`), full screen (`onFull`) and close, and shows the connection's `status` colour and a `detail`
/// (the latency).
struct PipWindow<Content: View>: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: PipState
    let room: CGRect
    /// What `PipState.fraction` is a fraction of: the screen's width.
    let reference: CGFloat
    /// The picture's width / height.
    let aspect: CGFloat
    var focused = false
    var label = ""
    var keyboardOpen = false
    var status: Color?
    var detail = ""
    var onTap: () -> Void
    var onClose: () -> Void
    var onKeyboard: () -> Void
    var onFull: () -> Void
    @ViewBuilder var content: () -> Content

    /// Set while the window is dragged: its top left so far.
    @State private var dragPos: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var hot = false
    @State private var pinchStart: Double?
    /// Set while the grip is dragged: the width so far, the width it started at and the top corner that stays put.
    @State private var resizing: (width: CGFloat, start: CGFloat, fixed: CGPoint)?
    /// The grip keeps its side once used, so it is where the finger left it; a move picks the side with room again.
    @State private var handleSide: Bool?
    @State private var appeared = false
    private let barHeight: CGFloat = 32
    private let closeRadius: CGFloat = 24
    private let gripSize: CGFloat = 32
    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    private var r: PipRect { PipRect(room.minX, room.minY, room.maxX, room.maxY) }
    private var size: CGSize {
        let fraction = resizing.map { Double($0.width / reference) } ?? state.fraction
        let s = PipLayout.size(room: r, reference: reference, fraction: fraction, aspect: aspect)
        return CGSize(width: s.width, height: s.height)
    }
    private var placed: CGRect {
        let p = PipLayout.place(room: r, width: size.width, height: size.height, fx: state.x, fy: state.y)
        return CGRect(x: p.left, y: p.top, width: p.width, height: p.height)
    }
    private var topLeft: CGPoint {
        if let dragPos { return dragPos }
        if let resizing {
            let w = size.width
            // The left grip keeps the right corner, the right grip the left one: the side the drag started on, not
            // one guessed from the placement (which moves as the width grows).
            return CGPoint(x: handleSide == true ? resizing.fixed.x - w : resizing.fixed.x, y: resizing.fixed.y)
        }
        return placed.origin
    }
    private var frame: CGRect { CGRect(origin: topLeft, size: size) }
    private var handleOnLeft: Bool {
        handleSide ?? PipLayout.handleOnLeft(room: r, window: PipRect(frame.minX, frame.minY, frame.maxX, frame.maxY))
    }
    private var closeTarget: CGPoint { CGPoint(x: room.midX, y: room.maxY - 40) }

    var body: some View {
        if room.width > 0, room.height > 0 {
            ZStack(alignment: .topLeading) {
                window
                if focused { bar }
                if dragPos == nil { grip }
                if dragPos != nil { closeButton }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { withAnimation(.easeOut(duration: 0.22)) { appeared = true } }
        }
    }

    // MARK: Window

    private var window: some View {
        let f = frame
        return ZStack {
            Color.black
            content()
            if !focused {
                // Unfocused this layer takes the touches, to place the window; focused the picture takes every one.
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { onTap() }
                    .gesture(SimultaneousGesture(moveGesture, pinchGesture).onEnded { _ in finishPlacing() })
                    .accessibilityIdentifier("pip-desktop-place")
            }
            shape.strokeBorder(focused ? Palette.accent : Palette.foreground.opacity(0.10), lineWidth: focused ? 2 : 0.5)
                .allowsHitTesting(false)
        }
        .frame(width: f.width, height: f.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        .scaleEffect((dragPos != nil ? 1.04 : 1) * (hot ? 0.6 : 1) * (appeared ? 1 : 0.6))
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hot)
        .offset(x: f.minX, y: f.minY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.text("桌面小窗，点按后在小窗里操作桌面", "Desktop window; tap to use the desktop in it"))
        .accessibilityIdentifier("pip-desktop")
    }

    /// One finger drags the window (or onto ✕ to close it).
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global).onChanged { value in
            guard pinchStart == nil else { return }
            let start = dragStart ?? topLeft
            dragStart = start
            let pos = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
            dragPos = pos
            let s = size
            let over = PipLayout.overClose(cx: pos.x + s.width / 2, cy: pos.y + s.height / 2,
                                           tx: closeTarget.x, ty: closeTarget.y, radius: closeRadius * 2.4)
            if over && !hot { UISelectionFeedbackGenerator().selectionChanged() }
            hot = over
        }
    }

    /// Two fingers resize it.
    private var pinchGesture: some Gesture {
        MagnificationGesture().onChanged { zoom in
            let start = pinchStart ?? state.fraction
            pinchStart = start
            dragPos = nil; dragStart = nil; hot = false
            state.fraction = PipLayout.pinched(start, zoom: Double(zoom))
        }
    }

    private func finishPlacing() {
        if pinchStart != nil {
            // Grows and shrinks about its centre, kept inside.
            let p = placed, s = size
            keep(left: p.midX - s.width / 2, top: p.midY - s.height / 2, size: s)
        } else if let pos = dragPos {
            if hot { onClose() } else { keep(left: pos.x, top: pos.y, size: size); handleSide = nil }
        }
        pinchStart = nil; dragPos = nil; dragStart = nil; hot = false
    }

    /// Remembers where the window is now, at the size it is now.
    private func keep(left: CGFloat, top: CGFloat, size s: CGSize) {
        let f = PipLayout.fractions(room: r, width: s.width, height: s.height, left: left, top: top)
        state.x = f.x; state.y = f.y
        state.fraction = PipLayout.clampFraction(Double(s.width / reference))
        state.save()
    }

    // MARK: Bar

    /// Focused: above the window (below it when there is no room above, over its top edge when there is room for
    /// neither), translucent and low; moves it and holds
    /// its buttons. Narrow windows drop the latency first (under 220pt), then the name (under 190pt: Android's 160 leaves
    /// iOS's wider name font only an ellipsis); the buttons always stay.
    private var bar: some View {
        let f = frame
        let top = PipLayout.barTop(room: r, window: PipRect(f.minX, f.minY, f.maxX, f.maxY), bar: barHeight, gap: 4)
        let barShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                GripDots().frame(width: 8, height: 13)
                if let status { Circle().fill(status).frame(width: 6, height: 6).padding(.leading, 8) }
                // Room for at least a few letters of the name beside the three buttons, not a lone "…".
                if f.width >= 190 {
                    Text(label).font(.system(size: 12)).foregroundStyle(Palette.foreground).lineLimit(1).padding(.leading, 6)
                }
                if !detail.isEmpty && f.width >= 220 {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1).padding(.leading, 6)
                        .accessibilityIdentifier("pip-desktop-detail")
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 10).frame(maxHeight: .infinity).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global).onChanged { value in
                let start = dragStart ?? topLeft
                dragStart = start
                let pos = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
                dragPos = pos
                let s = size
                let over = PipLayout.overClose(cx: pos.x + s.width / 2, cy: pos.y + s.height / 2,
                                               tx: closeTarget.x, ty: closeTarget.y, radius: closeRadius * 2.4)
                if over && !hot { UISelectionFeedbackGenerator().selectionChanged() }
                hot = over
            }.onEnded { _ in finishPlacing() })
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pip-desktop-move")
            barButton("ic_keyboard", model.text("键盘", "Keyboard"), id: "pip-desktop-keyboard", lit: keyboardOpen, action: onKeyboard)
            barButton("ic_fullscreen", model.text("打开全屏桌面", "Open the desktop full screen"), id: "pip-desktop-full", action: onFull)
            barButton("ic_close", model.text("关闭桌面小窗", "Close the desktop window"), id: "pip-desktop-close", action: onClose)
        }
        .frame(width: f.width, height: barHeight)
        .background(Palette.surfaceVariant.opacity(0.62), in: barShape)
        .overlay(barShape.strokeBorder(Palette.foreground.opacity(0.14), lineWidth: 0.5))
        .offset(x: f.minX, y: top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pip-desktop-bar")
    }

    private func barButton(_ icon: String, _ label: String, id: String, lit: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AppIcon(icon, size: 18).foregroundStyle(lit ? Palette.accent : Palette.foreground)
                .frame(width: 36, height: barHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
        .accessibilityAddTraits(lit ? .isSelected : [])
    }

    // MARK: Grip and close target

    /// The resize grip, in the bottom corner with room to grow.
    private var grip: some View {
        let f = frame, left = handleOnLeft
        return GripCorner(onLeft: left)
            .frame(width: 14, height: 14).padding(5)
            .frame(width: gripSize, height: gripSize, alignment: left ? .bottomLeading : .bottomTrailing)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { value in
                let current = resizing ?? {
                    let fixed = left ? CGPoint(x: f.maxX, y: f.minY) : f.origin
                    handleSide = left
                    return (f.width, f.width, fixed)
                }()
                let w = PipLayout.resized(width: Double(current.start), dx: Double(value.translation.width),
                                          dy: Double(value.translation.height), onLeft: left, aspect: Double(aspect))
                let clamped = min(max(CGFloat(w), reference * CGFloat(PipLayout.minFraction)), reference * CGFloat(PipLayout.maxFraction))
                resizing = (clamped, current.start, current.fixed)
            }.onEnded { _ in
                guard let resizing else { return }
                let s = PipLayout.size(room: r, reference: reference, fraction: Double(resizing.width / reference), aspect: aspect)
                let fs = CGSize(width: s.width, height: s.height)
                keep(left: handleOnLeft ? resizing.fixed.x - fs.width : resizing.fixed.x, top: resizing.fixed.y, size: fs)
                self.resizing = nil
            })
            .offset(x: left ? f.minX : f.maxX - gripSize, y: f.maxY - gripSize)
            .accessibilityLabel(model.text("调整小窗大小", "Resize the window"))
            .accessibilityIdentifier("pip-desktop-resize")
    }

    /// The dock's close button, alone, while a drag can end on it.
    private var closeButton: some View {
        ZStack {
            Circle().fill(hot ? Palette.accentPanel : Palette.surfaceVariant)
            if hot { Circle().strokeBorder(Palette.accent, lineWidth: 2) }
            AppIcon("ic_close", size: 20).foregroundStyle(hot ? Palette.accent : Palette.foreground)
        }
        .frame(width: closeRadius * 2, height: closeRadius * 2)
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .offset(x: closeTarget.x - closeRadius, y: closeTarget.y - closeRadius)
        .allowsHitTesting(false)
        .accessibilityIdentifier("pip-close-target")
    }
}

/// Six dots: a handle to drag.
private struct GripDots: View {
    var body: some View {
        Canvas { context, size in
            for col in 0..<2 {
                for row in 0..<3 {
                    let c = CGPoint(x: size.width * (0.25 + 0.5 * CGFloat(col)), y: size.height * (0.2 + 0.3 * CGFloat(row)))
                    context.fill(Path(ellipseIn: CGRect(x: c.x - 1.2, y: c.y - 1.2, width: 2.4, height: 2.4)), with: .color(Palette.foreground.opacity(0.5)))
                }
            }
        }.allowsHitTesting(false)
    }
}

/// Two short diagonal strokes: a window's corner grip.
private struct GripCorner: View {
    let onLeft: Bool
    var body: some View {
        Canvas { context, size in
            let s = size.width
            var path = Path()
            if onLeft {
                path.move(to: CGPoint(x: 0, y: s * 0.35)); path.addLine(to: CGPoint(x: s * 0.65, y: s))
                path.move(to: CGPoint(x: 0, y: s * 0.75)); path.addLine(to: CGPoint(x: s * 0.25, y: s))
            } else {
                path.move(to: CGPoint(x: s, y: s * 0.35)); path.addLine(to: CGPoint(x: s * 0.35, y: s))
                path.move(to: CGPoint(x: s, y: s * 0.75)); path.addLine(to: CGPoint(x: s * 0.75, y: s))
            }
            context.stroke(path, with: .color(.black.opacity(0.45)), style: StrokeStyle(lineWidth: 3.8, lineCap: .round))
            context.stroke(path, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }.allowsHitTesting(false)
    }
}
