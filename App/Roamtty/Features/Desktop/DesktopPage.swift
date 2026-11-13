import SwiftUI
import UIKit
import RoamttyCore
import RoamttyDesktopCore

/// The remote desktop page (Android `DesktopPage`, design D1–D11): picture, rail / tab bar, 操作 / 键盘
/// panels, stats, status card. State lives in `DesktopController` / `DesktopPageModel`.
struct DesktopPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: DesktopController
    @State private var showDisconnect = false
    @State private var keyboardOverlap: CGFloat = 0
    @State private var composingText = ""
    @State private var shortcutBar = false
    @State private var latchRevision = 0
    @State private var panel: DesktopPanel = .none
    @State private var keyboardPage: DesktopKeyboardPage = .ime
    @State private var virtualMouse = false
    @State private var showStats = false
    /// Closing the figures with their ✕ says once where to bring them back.
    @State private var statsHint = false
    @ObservedObject private var statsBox: DesktopStatsBox
    @State private var pointerMode: PointerMode = .touch
    @State private var imeFocused = false
    /// Landscape: the Dynamic Island (or notch) is on the leading edge, beside the picture.
    @State private var islandLeading = true
    @State private var railWidth: CGFloat = 0
    /// Portrait: how tall the bottom rail stands, from the screen's bottom edge.
    @State private var railHeight: CGFloat = 0

    private var keyboardPanel: some View {
        DesktopKeyboardPanel(controller: controller, composingText: $composingText, shortcutBar: $shortcutBar,
                             latchRevision: $latchRevision, keyboardPage: $keyboardPage, imeFocused: $imeFocused) { dismissPanel() }
    }

    init(controller: DesktopController) {
        self.controller = controller
        _statsBox = ObservedObject(wrappedValue: controller.statsBox)
    }

    private var english: Bool { model.english }
    private var page: DesktopPageModel { controller.page }

    var body: some View {
        GeometryReader { geo in
            // Keyboard avoidance changes the proposed height, not the window's orientation.
            let windowSize = Self.keyWindow?.bounds.size ?? geo.size
            let landscape = windowSize.width > windowSize.height
            ZStack {
                Color.black.ignoresSafeArea()
                if landscape { landscapeLayout(geo) } else { portraitLayout(geo) }
                #if DEBUG
                probes
                #endif
                if panel == .operations {
                    // The panel opens just beside the rail, which reaches past the safe area.
                    // Portrait: it stands on the bottom rail, which stays visible and live.
                    operationsPanel(size: geo.size, landscape: landscape,
                                    trailing: max(8, railWidth + 8 - geo.safeAreaInsets.trailing),
                                    bottom: landscape ? 0 : max(0, railHeight - geo.safeAreaInsets.bottom))
                        .transition(.move(edge: landscape ? .trailing : .bottom))
                }
            }
            .animation(.easeOut(duration: 0.2), value: panel)
            .onPreferenceChange(RailWidthKey.self) { railWidth = $0 }
            .onPreferenceChange(RailHeightKey.self) { railHeight = $0 }
        }
        // UIKit's hidden IME can include an input-assistant row that SwiftUI's automatic
        // avoidance misses after rotation. Reserve the entire keyboard frame explicitly.
        .ignoresSafeArea(.keyboard)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, let window = Self.keyWindow else { return }
            let localFrame = window.convert(frame, from: nil)
            keyboardOverlap = localFrame.intersects(window.bounds) ? max(0, window.bounds.maxY - localFrame.minY) : 0
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardOverlap = 0 }
        // A half turn keeps the size, so nothing else re-lays the page out when the island changes sides.
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateIslandSide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { updateIslandSide() }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        // Swipes from the screen's edges are the desktop's (edge swipes, drags to the Dock): the system's
        // own edge gestures need a second swipe, and the home indicator fades. Swiping back still works
        // from the black bars beside the picture (InteractivePopGesture), and 操作 › 返回 always does.
        .defersSystemGestures(on: .vertical)
        .persistentSystemOverlays(.hidden)
        .task {
            try? await Task.sleep(for: .milliseconds(1500))
            while !Task.isCancelled {
                saveThumbnail()
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
            }
        }
        .onAppear { restoreState() }
        .onDisappear {
            // Leaving pauses and keeps the link for the keep-alive window (phase 5).
            saveThumbnail()
            resetKeyboardState()
            controller.hidden("page")
        }
        .confirmationDialog(model.text("断开连接？", "Disconnect?"), isPresented: $showDisconnect, titleVisibility: .visible) {
            Button(model.text("断开连接", "Disconnect"), role: .destructive) {
                model.closeDesktop(controller.host.id)
            }
            Button(model.text("取消", "Cancel"), role: .cancel) {}
        }
        .alert(model.text("提示", "Notice"), isPresented: Binding(
            get: { controller.notice != nil },
            set: { if !$0 { controller.notice = nil } })) {
            Button(model.text("好", "OK"), role: .cancel) { controller.notice = nil }
        } message: { Text(controller.notice ?? "") }
    }

    // MARK: Layout

    private func landscapeLayout(_ geo: GeometryProxy) -> some View {
        // Only the island's side keeps its safe inset: the picture and the rail use the other.
        let insets = geo.safeAreaInsets
        return HStack(spacing: 0) {
            // The picture always runs to the bottom edge, so the keyboard is measured from there.
            desktopWorkspace(landscape: true, bottomInset: keyboardPage == .ime ? keyboardOverlap : insets.bottom,
                             bleed: islandLeading ? 0 : insets.leading)
                .padding(.leading, islandLeading ? insets.leading : 0)
            // The rail reaches the screen edge and keeps clear of an island on that side.
            controlRail(landscape: true, edgeInset: insets.trailing, edgeClearance: islandLeading ? 0 : min(insets.trailing, 50))
                .background(GeometryReader { rail in Color.clear.preference(key: RailWidthKey.self, value: rail.size.width) })
        }
        // The picture runs under the home indicator too; the keyboard panel floats clear of it.
        // All regions: while the keyboard is up, the home indicator's inset counts as the keyboard's,
        // and keeping it would shrink the picture. The panel places itself from keyboardOverlap.
        .ignoresSafeArea(.all, edges: [.horizontal, .bottom])
    }

    private func portraitLayout(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            desktopWorkspace(landscape: false, bottomInset: max(0, keyboardOverlap - geo.safeAreaInsets.bottom))
            if panel != .keyboard {
                controlRail(landscape: false, edgeInset: geo.safeAreaInsets.bottom)
                    .background(GeometryReader { rail in Color.clear.preference(key: RailHeightKey.self, value: rail.size.height) })
            }
        }
        // The rail takes most of the home indicator's inset; the keyboard panel keeps it all.
        .ignoresSafeArea(.container, edges: panel == .keyboard ? [] : .bottom)
    }

    private func controlRail(landscape: Bool, edgeInset: CGFloat, edgeClearance: CGFloat = 0) -> some View {
        DesktopControlRail(controller: controller, panel: panel, landscape: landscape, edgeInset: edgeInset, edgeClearance: edgeClearance) { tapped in
            togglePanel(tapped)
            if tapped == .keyboard { imeFocused = panel == .keyboard && keyboardPage == .ime }
        }
    }

    #if DEBUG
    /// Test only: near-invisible lines the live UI tests read.
    @ViewBuilder
    private var probes: some View {
        if !controller.inputProbe.isEmpty {
            // What the gestures sent (ROAMTTY_DESKTOP_INPUT_PROBE=1).
            Text(controller.inputProbe).font(.system(size: 6)).opacity(0.02).allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .accessibilityIdentifier("desktop-input-probe")
        }
        if !controller.audioProbe.isEmpty {
            // ROAMTTY_DESKTOP_AUDIO_PROBE=1.
            Text(controller.audioProbe).font(.system(size: 6)).opacity(0.02).allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .accessibilityIdentifier("desktop-audio-probe")
        }
    }
    #endif

    /// Portrait: keep the video and its gesture viewport in the same unobscured rectangle, so only this
    /// column resizes for input. Landscape: the picture is short already, so it keeps its full size and
    /// the keyboard panel floats over its lower part; the rail retains its full-height touch targets.
    /// `bleed`: how far the picture runs past the leading safe area, where the stats stay clear of the corner.
    @ViewBuilder
    private func desktopWorkspace(landscape: Bool, bottomInset: CGFloat, bleed: CGFloat = 0) -> some View {
        if landscape {
            ZStack(alignment: .bottom) {
                desktopPicture(landscape: true, bleed: bleed)
                if panel == .keyboard {
                    keyboardPanel.fixedSize(horizontal: false, vertical: true).padding(.bottom, bottomInset)
                }
            }
        } else {
            portraitWorkspace(bottomInset: bottomInset)
        }
    }

    private func portraitWorkspace(bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            desktopPicture(landscape: false, bleed: 0)
            if panel == .keyboard {
                keyboardPanel.fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, panel == .keyboard && keyboardPage == .ime ? bottomInset : 0)
    }

    private func desktopPicture(landscape: Bool, bleed: CGFloat) -> some View {
        GeometryReader { geo in
            ZStack {
                DesktopVideoSurface(display: controller.display, content: contentFrame(in: geo.size))
                DesktopGestureOverlay(controller: controller, size: geo.size)
                DesktopStatsOverlay(controller: controller, statsBox: statsBox, showStats: showStats, landscape: landscape,
                                    pictureSpace: Self.pictureSpace) {
                    setShowStats(false)
                    statsHint = true
                }
                .padding(.leading, landscape ? bleed : 0)
                DesktopStatusOverlay(host: controller.host.name, phase: controller.phase,
                                     hasPicture: controller.videoSize.0 > 0, windowsHost: controller.windowsHost,
                                     log: controller.log.last ?? "", failure: controller.session.failure, english: english) {
                    if let host = model.host(controller.host.id) { model.openDesktop(host) }
                } onClose: { model.closeDesktop(controller.host.id) }
                if virtualMouse { virtualMouseOverlay }
                if statsHint { statsHintBanner }
            }
            .coordinateSpace(name: Self.pictureSpace)
            .clipped()
        }
    }

    private var statsHintBanner: some View {
        Text(model.text("网络状态已隐藏，可在「操作」中重新打开", "Network stats hidden; turn them back on in Ops"))
            .font(.system(size: 13)).foregroundStyle(DesktopTheme.ink)
            .padding(.horizontal, 14).padding(.vertical, 6).background(DesktopTheme.panel, in: Capsule())
            .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .accessibilityIdentifier("desktop-stats-hint")
            .task { try? await Task.sleep(for: .milliseconds(2500)); statsHint = false }
    }

    /// The 操作 panel over a dimmed page: beside the rail in landscape, standing on it in portrait.
    private func operationsPanel(size: CGSize, landscape: Bool, trailing: CGFloat, bottom: CGFloat) -> some View {
        ZStack(alignment: landscape ? .trailing : .bottom) {
            Color.black.opacity(0.4).ignoresSafeArea(edges: bottom > 0 ? [.top, .horizontal] : .all)
                .onTapGesture { dismissPanel() }
            DesktopOperationsPanel(controller: controller, statsBox: statsBox, pointerMode: $pointerMode, virtualMouse: $virtualMouse,
                                   showDisconnect: $showDisconnect, showStats: showStats, setShowStats: setShowStats) { dismissPanel() }
                .frame(width: landscape ? min(340, max(0, size.width - 80)) : size.width,
                       height: landscape ? size.height * 0.92 : min(size.height * 0.7, size.height - bottom))
                .background(DesktopTheme.panel, in: RoundedRectangle(cornerRadius: 18))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(.trailing, landscape ? trailing : 0)
        }
        .padding(.bottom, bottom)
    }

    private static let pictureSpace = "desktop-picture"

    /// The gesture view's viewport while it matches this picture, else the unzoomed fit.
    private func viewport(in size: CGSize) -> Viewport {
        let remote = controller.remoteSize
        if let vp = controller.viewport, vp.viewWidth == Float(size.width), vp.viewHeight == Float(size.height),
           vp.remoteWidth == max(1, remote.0), vp.remoteHeight == max(1, remote.1) { return vp }
        return Viewport(viewWidth: Float(size.width), viewHeight: Float(size.height),
                        remoteWidth: max(1, remote.0), remoteHeight: max(1, remote.1))
    }

    /// Where the zoomed and panned picture sits, as on Android; nil before the first frame.
    private func contentFrame(in size: CGSize) -> CGRect? {
        guard controller.remoteSize.0 > 0, size.width > 0 else { return nil }
        let vp = viewport(in: size)
        return CGRect(x: CGFloat(vp.left), y: CGFloat(vp.top), width: CGFloat(vp.contentWidth), height: CGFloat(vp.contentHeight))
    }

    private var virtualMouseOverlay: some View {
        VirtualMousePad { button, down in
            controller.input(DesktopProtocol.button(button, down: down))
        } wheel: { dx, dy in
            controller.input(DesktopProtocol.wheel(dx: dx, dy: dy))
        }
        .frame(width: 140, height: 160)
        .position(x: 100, y: 280)
    }

    // MARK: State

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.windows.first { $0.isKeyWindow }
    }

    /// The page shows the picture again, with the choices the controller and the settings kept.
    private func restoreState() {
        updateIslandSide()
        // The page shows the picture; leaving pauses the host unless the small window over the terminal takes it.
        controller.shown("page", small: false)
        showStats = model.settings.desktopShowStats
        page.showStats = showStats
        statsBox.place(model.settings.desktopStatsX, model.settings.desktopStatsY)
        statsBox.shown = showStats
        let appModel = model
        statsBox.onMoved = { [weak appModel] x, y in
            appModel?.settings.desktopStatsX = Double(x); appModel?.settings.desktopStatsY = Double(y); appModel?.saveSettings()
        }
        pointerMode = page.pointerMode
        virtualMouse = page.virtualMouse
        keyboardPage = page.keyboardPage
    }

    private func setShowStats(_ on: Bool) {
        showStats = on; statsBox.shown = on; controller.setShowStats(on); model.settings.desktopShowStats = on; model.saveSettings()
    }

    private func updateIslandSide() {
        let orientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.interfaceOrientation
        // Landscape left: the home button's side, so the top of the phone, is on the right.
        islandLeading = orientation != .landscapeLeft
    }

    private func togglePanel(_ p: DesktopPanel) {
        panel = panel == p ? .none : p
        page.panel = panel
        if panel != .keyboard { resetKeyboardState() }
    }
    private func dismissPanel() { panel = .none; page.dismissPanel(); resetKeyboardState() }

    private func resetKeyboardState() {
        imeFocused = false
        composingText = ""
        shortcutBar = false
        keyboardPage = .ime
        page.keyboardPage = .ime
        for hid in [HidUsage.LEFT_CTRL, HidUsage.LEFT_ALT, HidUsage.LEFT_GUI, HidUsage.LEFT_SHIFT] where page.latch.state(hid) != .off {
            page.tapModifier(hid)
        }
        latchRevision += 1
    }

    private func saveThumbnail() {
        let hostID = controller.host.id
        controller.display.snapshot { image in
            guard let image, model.host(hostID) != nil else { return }
            model.desktopThumbnails.save(image, for: hostID)
        }
    }
}

private struct RailHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct RailWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
