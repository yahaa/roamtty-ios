import SwiftUI
import RoamttyDesktopCore

/// A host's desktop in the small window (Android `DesktopMiniContent`): the desktop page's own picture and gestures
/// (`DesktopVideoSurface`, `DesktopGestureOverlay`) on the same connection. Not `focused`, the window takes the
/// touches (to be placed) and the host sends the picture at a lower rate; `focused`, the picture takes every touch,
/// at full rate, and a hardware keyboard types on the host unless the `keyboard` panel holds the input. Before the
/// first picture (or after a failure) a line says where the desktop is.
struct DesktopMiniContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: DesktopController
    var focused = false
    var keyboard = false
    /// The owner name the small window registers with the controller (`DesktopController.shown`).
    private static let owner = "pip"

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                DesktopVideoSurface(display: controller.display, content: contentFrame(in: geo.size))
                    .accessibilityIdentifier("pip-desktop-surface")
                DesktopGestureOverlay(controller: controller, size: geo.size, small: true, keys: focused && !keyboard)
                    .allowsHitTesting(focused)
                if let status { statusCard(status) }
            }
        }
        .onAppear { controller.shown(Self.owner, small: !focused) }
        .onChange(of: focused) { controller.shown(Self.owner, small: !$0) }
        .onDisappear { controller.hidden(Self.owner) }
    }

    private var status: String? {
        switch controller.phase {
        case .failed: return model.text("桌面已断开", "Desktop disconnected")
        case .needsAction: return model.text("需要在电脑上操作", "Something needs doing on the computer")
        case .recovering: return model.text("连接中断", "Connection lost")
        default: return controller.videoSize.0 > 0 ? nil : model.text("正在打开桌面", "Opening the desktop")
        }
    }

    private func statusCard(_ text: String) -> some View {
        let busy: Bool = { if case .failed = controller.phase { return false }; return true }()
        return VStack(spacing: 4) {
            Text(controller.host.name).font(.system(size: 11)).foregroundStyle(Self.inkDim).lineLimit(1)
            if busy { ProgressView().controlSize(.mini).tint(DesktopKeyboardPanel.accent) }
            Text(text).font(.system(size: 13)).foregroundStyle(DesktopKeyboardPanel.ink).multilineTextAlignment(.center).lineLimit(2)
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x21 / 255))
        .allowsHitTesting(false)
        .accessibilityIdentifier("pip-desktop-status")
    }
    private static let inkDim = Color(red: 154 / 255, green: 154 / 255, blue: 161 / 255)

    /// Where the zoomed and panned picture sits, as on the desktop page; nil before the first frame.
    private func contentFrame(in size: CGSize) -> CGRect? {
        let remote = controller.remoteSize
        guard remote.0 > 0, size.width > 0 else { return nil }
        let vp: Viewport
        if let v = controller.viewport, v.viewWidth == Float(size.width), v.viewHeight == Float(size.height),
           v.remoteWidth == max(1, remote.0), v.remoteHeight == max(1, remote.1) {
            vp = v
        } else {
            vp = Viewport(viewWidth: Float(size.width), viewHeight: Float(size.height), remoteWidth: max(1, remote.0), remoteHeight: max(1, remote.1))
        }
        return CGRect(x: CGFloat(vp.left), y: CGFloat(vp.top), width: CGFloat(vp.contentWidth), height: CGFloat(vp.contentHeight))
    }
}

/// The terminal page's small window on `controller`: the window, placed and remembered under `stateKey`, with the
/// connection's status dot and latency on its bar.
struct PipDesktopWindow: View {
    @ObservedObject var controller: DesktopController
    @StateObject private var state: PipState
    let room: CGRect
    let reference: CGFloat
    var focused: Bool
    var keyboardOpen: Bool
    var onTap: () -> Void
    var onClose: () -> Void
    var onKeyboard: () -> Void
    var onFull: () -> Void

    init(controller: DesktopController, stateKey: String, defaultFraction: Double, room: CGRect, reference: CGFloat,
         focused: Bool, keyboardOpen: Bool, onTap: @escaping () -> Void, onClose: @escaping () -> Void,
         onKeyboard: @escaping () -> Void, onFull: @escaping () -> Void) {
        self.controller = controller
        _state = StateObject(wrappedValue: PipState(key: stateKey, defaultFraction: defaultFraction))
        self.room = room; self.reference = reference; self.focused = focused; self.keyboardOpen = keyboardOpen
        self.onTap = onTap; self.onClose = onClose; self.onKeyboard = onKeyboard; self.onFull = onFull
    }

    var body: some View {
        let video = controller.videoSize
        PipWindow(state: state, room: room, reference: reference, aspect: video.1 > 0 ? CGFloat(video.0) / CGFloat(video.1) : 1.6,
                  focused: focused, label: controller.host.name, keyboardOpen: keyboardOpen, status: status, detail: detail,
                  onTap: onTap, onClose: onClose, onKeyboard: onKeyboard, onFull: onFull) {
            DesktopMiniContent(controller: controller, focused: focused, keyboard: keyboardOpen)
        }
    }

    private var status: Color {
        switch controller.phase {
        case .connected: return Palette.success
        case .failed: return Palette.danger
        default: return Palette.accent
        }
    }
    private var detail: String {
        guard case .connected = controller.phase, let rtt = controller.stats.rttMs else { return "" }
        return "\(rtt) ms"
    }
}
