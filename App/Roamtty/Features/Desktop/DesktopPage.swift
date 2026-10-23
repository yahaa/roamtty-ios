#if canImport(UIKit)
import SwiftUI
import UIKit
import RoamttyCore
import RoamttyDesktopCore

/// The remote desktop page (Android `DesktopPage`, design D1–D11): picture, rail / tab bar, 操作 / 键盘
/// panels, stats, status card. State lives in `DesktopController` / `DesktopPageModel`.
struct DesktopPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: DesktopController
    @State private var showDisconnect = false
    @State private var imeText = ""
    @State private var panel: DesktopPanel = .none
    @State private var keyboardPage: DesktopKeyboardPage = .ime
    @State private var virtualMouse = false
    @State private var showStats = false
    @State private var pointerMode: PointerMode = .touch
    @FocusState private var imeFocused: Bool

    private var english: Bool { model.english }
    private var page: DesktopPageModel { controller.page }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                DesktopVideoSurface(display: controller.display)
                    .ignoresSafeArea()
                DesktopGestureOverlay(controller: controller, size: geo.size)
                    .ignoresSafeArea()
                cursorOverlay
                statsOverlay
                statusCard
                if panel == .operations { operationsPanel.transition(.move(edge: landscape ? .trailing : .bottom)) }
                if panel == .keyboard { keyboardPanel.transition(.move(edge: landscape ? .trailing : .bottom)) }
                if landscape { landscapeRail(safe: geo.safeAreaInsets) }
                else { portraitTabBar }
                if virtualMouse { virtualMouseOverlay }
            }
            .animation(.easeOut(duration: 0.2), value: panel)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            while !Task.isCancelled {
                saveThumbnail()
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { break }
            }
        }
        .onAppear {
            controller.resume()
            showStats = model.settings.desktopShowStats
            page.showStats = showStats
            pointerMode = page.pointerMode
            virtualMouse = page.virtualMouse
            keyboardPage = page.keyboardPage
        }
        .onDisappear {
            // Leaving pauses and keeps the link for the keep-alive window (phase 5).
            saveThumbnail()
            controller.pause()
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

    // MARK: Rail / tab bar

    private func landscapeRail(safe: EdgeInsets) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                railItem("ic_operations", model.text("操作", "Ops"), selected: panel == .operations) {
                    togglePanel(.operations)
                }
                railItem("ic_keyboard", model.text("键盘", "Keys"), selected: panel == .keyboard) {
                    togglePanel(.keyboard); imeFocused = panel == .keyboard && keyboardPage == .ime
                }
                railItem("ic_show_desktop", model.text("显示桌面", "Desktop"), selected: false) {
                    controller.input(DesktopProtocol.action(DesktopProtocol.ACTION_SHOW_DESKTOP))
                }
                railItem("ic_windows_all", model.text("所有窗口", "Windows"), selected: false) {
                    controller.input(DesktopProtocol.action(DesktopProtocol.ACTION_ALL_WINDOWS))
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            .padding(.trailing, max(8, safe.trailing))
        }
    }

    private var portraitTabBar: some View {
        VStack {
            Spacer()
            HStack {
                tabItem("ic_operations", model.text("操作", "Ops"), selected: panel == .operations) {
                    togglePanel(.operations)
                }
                tabItem("ic_keyboard", model.text("键盘", "Keys"), selected: panel == .keyboard) {
                    togglePanel(.keyboard); imeFocused = panel == .keyboard && keyboardPage == .ime
                }
                tabItem("ic_show_desktop", model.text("显示桌面", "Desktop"), selected: false) {
                    controller.input(DesktopProtocol.action(DesktopProtocol.ACTION_SHOW_DESKTOP))
                }
                tabItem("ic_windows_all", model.text("所有窗口", "Windows"), selected: false) {
                    controller.input(DesktopProtocol.action(DesktopProtocol.ACTION_ALL_WINDOWS))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.black.opacity(0.7).ignoresSafeArea(edges: .bottom))
        }
    }

    private func railItem(_ icon: String, _ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                AppIcon(icon, size: 22).foregroundStyle(selected ? Palette.accent : .white)
                Text(title).font(.system(size: 10)).foregroundStyle(selected ? Palette.accent : .white.opacity(0.85))
            }
            .frame(width: 64, height: 56)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    private func tabItem(_ icon: String, _ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                AppIcon(icon, size: 22).foregroundStyle(selected ? Palette.accent : .white)
                Text(title).font(.system(size: 11)).foregroundStyle(selected ? Palette.accent : .white.opacity(0.85))
            }
            .frame(maxWidth: .infinity).frame(height: 52).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    // MARK: Operations panel

    private var operationsPanel: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { dismissPanel() }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(model.text("操作", "Operations")).font(.headline).foregroundStyle(.white)
                    Spacer()
                    Button { dismissPanel() } label: { AppIcon("ic_close", size: 20).foregroundStyle(.white) }
                }.padding(16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            opChip("ic_exit", model.text("退出", "Exit")) {
                                dismissPanel(); dismissDesktopKeepingLink()
                            }
                            opChip("ic_folder", model.text("文件", "Files")) {
                                dismissPanel()
                                model.path.append(.files(controller.host.id))
                            }
                            opChip("ic_copy", model.text("剪贴板", "Clipboard")) { sendClipboard() }
                            Button { fetchClipboard() } label: {
                                Text(model.text("获取远程", "Get remote")).font(.footnote).foregroundStyle(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .background(Color.white.opacity(0.12), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                        if let note = controller.clipNote ?? page.clipNote {
                            Text(note).font(.caption).foregroundStyle(.white.opacity(0.7))
                        }
                        Toggle(isOn: Binding(
                            get: { controller.viewOnly },
                            set: { controller.setViewOnly($0) }
                        )) { Text(model.text("仅观看", "View only")).foregroundStyle(.white) }
                        .tint(Palette.accent)

                        Text(model.text("操作方式", "Pointer mode")).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                        Picker("", selection: Binding(
                            get: { pointerMode == .mouse ? 1 : 0 },
                            set: { pointerMode = $0 == 1 ? .mouse : .touch; controller.setPointerMode(pointerMode) }
                        )) {
                            Text(model.text("屏幕触控", "Touch")).tag(0)
                            Text(model.text("鼠标指针", "Trackpad")).tag(1)
                        }.pickerStyle(.segmented)

                        Toggle(isOn: Binding(
                            get: { virtualMouse },
                            set: { virtualMouse = $0; page.virtualMouse = $0 }
                        )) { Label { Text(model.text("虚拟鼠标", "Virtual mouse")).foregroundStyle(.white) } icon: { AppIcon("ic_mouse", size: 18).foregroundStyle(.white) } }
                        .tint(Palette.accent)

                        Text(model.text("帧率", "Frame rate")).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                        Picker("", selection: Binding(get: { controller.fps }, set: { controller.setFps($0) })) {
                            ForEach(DesktopPreferences.fpsOptions, id: \.self) { Text("\($0)").tag($0) }
                        }.pickerStyle(.segmented)

                        Text(model.text("画质", "Quality")).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                        Picker("", selection: Binding(get: { controller.quality }, set: { controller.setQuality($0) })) {
                            ForEach(DesktopPreferences.qualities, id: \.self) { Text(page.qualityLabel($0)).tag($0) }
                        }.pickerStyle(.segmented)
                        if let estimate = DesktopStatsText.meteredEstimate(kbps: controller.stats.kbps, english: english) {
                            Text(estimate).font(.caption).foregroundStyle(.white.opacity(0.6))
                        }

                        if let displays = controller.hello?.displays, displays.count > 1 {
                            Text(model.text("显示器", "Display")).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                            ForEach(displays, id: \.id) { d in
                                Button {
                                    controller.setDisplay(d.id)
                                } label: {
                                    HStack {
                                        Text(d.name.isEmpty ? model.text("显示器 \(d.id)", "Display \(d.id)") : d.name)
                                        Spacer()
                                        if controller.displayIndex == d.id { AppIcon("ic_check", size: 18) }
                                    }.foregroundStyle(.white).padding(.vertical, 6)
                                }.buttonStyle(.plain)
                            }
                        }

                        Toggle(isOn: Binding(
                            get: { controller.lockOnClose },
                            set: { controller.setLockOnClose($0) }
                        )) { Text(model.text("断开后锁定电脑", "Lock after disconnect")).foregroundStyle(.white) }
                        .tint(Palette.accent)

                        Toggle(isOn: Binding(
                            get: { showStats },
                            set: {
                                showStats = $0
                                controller.setShowStats($0)
                                model.settings.desktopShowStats = $0
                                model.saveSettings()
                            }
                        )) { Text(model.text("显示网络状态", "Show network stats")).foregroundStyle(.white) }
                        .tint(Palette.accent)

                        Button(role: .destructive) { showDisconnect = true } label: {
                            HStack {
                                AppIcon("ic_power", size: 18)
                                Text(model.text("断开连接", "Disconnect"))
                            }
                            .foregroundStyle(Palette.danger)
                            .frame(maxWidth: .infinity).padding(12)
                            .background(Palette.danger.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).padding(.top, 8)
                    }.padding(.horizontal, 16).padding(.bottom, 24)
                }
            }
            .frame(maxWidth: 360)
            .background(Color(white: 0.12).opacity(0.96))
            .ignoresSafeArea(edges: .trailing)
        }
    }

    private func opChip(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                AppIcon(icon, size: 20)
                Text(title).font(.caption2)
            }
            .foregroundStyle(.white)
            .frame(width: 64, height: 52)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    // MARK: Keyboard

    private var keyboardPanel: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { dismissPanel(); imeFocused = false }
            VStack(spacing: 0) {
                Picker("", selection: Binding(
                    get: { keyboardPage },
                    set: { keyboardPage = $0; page.keyboardPage = $0; imeFocused = $0 == .ime }
                )) {
                    Text(model.text("输入法", "IME")).tag(DesktopKeyboardPage.ime)
                    Text(model.text("电脑键盘", "PC keys")).tag(DesktopKeyboardPage.more)
                }.pickerStyle(.segmented).padding(12)
                if keyboardPage == .ime { imePage } else { pcKeysPage }
            }
            .background(Color(white: 0.12).opacity(0.97))
        }
    }

    private var imePage: some View {
        VStack(spacing: 8) {
            TextField(model.text("输入后发送到远程…", "Type to send…"), text: $imeText)
                .focused($imeFocused)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .padding(12)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
                .onSubmit { commitIME() }
                .onChange(of: imeText) { value in
                    // Commit each completed character; composing is ignored by the model.
                    if !value.isEmpty { commitIME() }
                }
            HStack {
                Button(model.text("退格", "Backspace")) {
                    page.imeControlKey(backspace: true).forEach(controller.input)
                }.buttonStyle(RoamButtonStyle())
                Button(model.text("回车", "Enter")) {
                    page.imeControlKey(backspace: false).forEach(controller.input)
                }.buttonStyle(RoamButtonStyle())
            }.padding(.bottom, 12)
        }.padding(.horizontal, 12)
    }

    private var pcKeysPage: some View {
        let os = controller.hello?.os ?? controller.host.system
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.text("修饰键", "Modifiers")).font(.caption).foregroundStyle(.white.opacity(0.6))
                FlowKeys(keys: DesktopPageModel.modifierKeys(os: os).map { ($0.label, [$0.hid]) }) { keys in
                    if keys.count == 1 { page.tapModifier(keys[0]) }
                }
                Text(model.text("组合键", "Combos")).font(.caption).foregroundStyle(.white.opacity(0.6))
                FlowKeys(keys: DesktopPageModel.comboKeys(os: os).map { ($0.label, $0.keys) }) { keys in
                    page.combo(keys).forEach { controller.input(DesktopProtocol.key($0.hid, down: $0.down)) }
                }
                Text(model.text("更多", "More")).font(.caption).foregroundStyle(.white.opacity(0.6))
                FlowKeys(keys: DesktopPageModel.moreKeys().map { ($0.label, [$0.hid]) }) { keys in
                    page.pressKey(keys[0]).forEach { controller.input(DesktopProtocol.key($0.hid, down: $0.down)) }
                }
                Button(model.text("Esc", "Esc")) {
                    page.pressKey(HidUsage.ESCAPE).forEach { controller.input(DesktopProtocol.key($0.hid, down: $0.down)) }
                }.buttonStyle(RoamButtonStyle()).padding(.bottom, 16)
            }.padding(12)
        }.frame(maxHeight: 320)
    }

    // MARK: Overlays

    private var statsOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            let poor: Bool = { if case .connected(let p, _) = controller.phase { return p }; return false }()
            let recovering: Bool = { if case .recovering = controller.phase { return true }; return false }()
            if showStats {
                ForEach(Array(DesktopStatsText.lines(stats: controller.stats, poor: poor, recovering: recovering,
                                                     transport: .unknown, english: english).enumerated()), id: \.offset) { _, line in
                    Text(line.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(toneColor(line.tone))
                }
            } else if let warn = DesktopStatsText.warning(poor: poor, recovering: recovering, english: english) {
                Text(warn.text).font(.system(size: 12, weight: .medium)).foregroundStyle(toneColor(warn.tone))
                    .padding(6).background(Color.black.opacity(0.45), in: Capsule())
            }
            Spacer()
        }
        .padding(.top, 12).padding(.leading, 12)
        .allowsHitTesting(false)
    }

    private var statusCard: some View {
        Group {
            switch controller.phase {
            case .connecting(let step, _):
                card(title: model.text("连接中", "Connecting"),
                     detail: stepLabel(step),
                     log: controller.log.last)
            case .needsAction(let needs):
                card(title: model.text("需要操作", "Action needed"),
                     detail: needs.joined(separator: " · "),
                     log: controller.windowsHost
                        ? model.text("请先在这台电脑上登录桌面", "Sign in on that computer first")
                        : controller.log.last)
            case .recovering:
                card(title: model.text("恢复中", "Recovering"),
                     detail: model.text("保留上一帧 · 通常很快恢复", "Keeping the last frame · usually recovers quickly"),
                     log: controller.log.last)
            case .failed(let message):
                card(title: model.text("连接失败", "Failed"), detail: message, log: nil, failed: true)
            default:
                EmptyView()
            }
        }
    }

    private func card(title: String, detail: String, log: String?, failed: Bool = false) -> some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white).opacity(failed ? 0 : 1)
            Text(title).font(.headline).foregroundStyle(.white)
            Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
            if let log, !log.isEmpty {
                Text(log).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
            }
            if failed {
                Button(model.text("重试", "Retry")) { controller.start() }.buttonStyle(RoamButtonStyle(filled: true))
                Button(model.text("关闭", "Close")) { model.closeDesktop(controller.host.id) }.buttonStyle(RoamButtonStyle())
            }
        }
        .padding(20).frame(width: 280)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var cursorOverlay: some View {
        if pointerMode == .mouse || virtualMouse, let cursor = controller.cursor, cursor.visible {
            // Approximate: place at remote coords scaled into the view (letterboxed).
            GeometryReader { geo in
                let vp = Viewport(viewWidth: Float(geo.size.width), viewHeight: Float(geo.size.height),
                                  remoteWidth: max(1, controller.videoSize.0), remoteHeight: max(1, controller.videoSize.1))
                let pt = vp.toView(Float(cursor.x), Float(cursor.y))
                Circle().fill(Color.white).frame(width: 8, height: 8)
                    .position(x: CGFloat(pt.x), y: CGFloat(pt.y))
                    .allowsHitTesting(false)
            }
        }
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

    // MARK: Helpers


    private func togglePanel(_ p: DesktopPanel) {
        panel = panel == p ? .none : p
        page.panel = panel
        if panel != .keyboard { imeFocused = false }
    }
    private func dismissPanel() { panel = .none; page.dismissPanel(); imeFocused = false }

    private func toneColor(_ tone: DesktopStatsText.Tone) -> Color {
        switch tone {
        case .ink: return .white
        case .dim: return .white.opacity(0.65)
        case .warn: return Palette.warning
        case .bad: return Palette.danger
        }
    }

    private func stepLabel(_ step: DesktopPhase.Step) -> String {
        switch step {
        case .login: return model.text("SSH 登录…", "Signing in…")
        case .install: return model.text("安装桌面插件…", "Installing desktop plugin…")
        case .start: return model.text("启动插件…", "Starting plugin…")
        case .firstFrame: return model.text("等待首帧…", "Waiting for first frame…")
        }
    }

    private func commitIME() {
        let text = imeText
        imeText = ""
        switch page.commitIME(text, composing: false) {
        case .frames(let frames): frames.forEach(controller.input)
        case .composingIgnored: break
        }
    }

    private func sendClipboard() {
        let text = UIPasteboard.general.string ?? ""
        controller.clipNote = page.clipSentNote(empty: text.isEmpty)
        if !text.isEmpty { controller.send(DesktopProtocol.clipSet(text)) }
    }

    private func fetchClipboard() {
        controller.send(DesktopProtocol.req(DesktopProtocol.REQ_CLIP_GET))
    }

    private func saveThumbnail() {
        let hostID = controller.host.id
        controller.display.snapshot { image in
            guard let image, model.host(hostID) != nil else { return }
            model.desktopThumbnails.save(image, for: hostID)
        }
    }

    private func dismissDesktopKeepingLink() {
        if model.path.last == .desktop(controller.host.id) { _ = model.path.popLast() }
        else { model.path.removeAll { $0 == .desktop(controller.host.id) } }
    }
}

// MARK: - Gesture overlay

private struct DesktopGestureOverlay: UIViewRepresentable {
    @ObservedObject var controller: DesktopController
    let size: CGSize

    func makeUIView(context: Context) -> DesktopGestureView {
        let view = DesktopGestureView()
        view.controller = controller
        return view
    }
    func updateUIView(_ uiView: DesktopGestureView, context: Context) {
        uiView.controller = controller
        uiView.boundsSize = size
    }
}

final class DesktopGestureView: UIView {
    weak var controller: DesktopController?
    var boundsSize: CGSize = .zero
    private let gestures = DesktopGestures(mode: .touch, density: 1)
    private var timer: CADisplayLink?
    private var twoFingerActive = false
    private var lastPoint: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        timer = CADisplayLink(target: self, selector: #selector(tick))
        timer?.add(to: .main, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    deinit { timer?.invalidate() }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncViewport()
    }

    private func syncViewport() {
        guard let c = controller else { return }
        gestures.mode = c.page.pointerMode
        let w = Float(bounds.width > 0 ? bounds.width : boundsSize.width)
        let h = Float(bounds.height > 0 ? bounds.height : boundsSize.height)
        var vp = gestures.viewport
        vp.viewWidth = max(1, w); vp.viewHeight = max(1, h)
        vp.remoteWidth = max(1, c.videoSize.0); vp.remoteHeight = max(1, c.videoSize.1)
        gestures.viewport = vp.clamped()
    }

    @objc private func tick() {
        apply(gestures.tick(Int64(Date().timeIntervalSince1970 * 1000)))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        syncViewport()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let active = (event?.allTouches ?? touches).filter { $0.phase != .ended && $0.phase != .cancelled }
        if active.count >= 2 {
            let pts = active.prefix(2).map { $0.location(in: self) }
            if !twoFingerActive {
                twoFingerActive = true
                apply(gestures.twoDown(Float(pts[0].x), Float(pts[0].y), Float(pts[1].x), Float(pts[1].y)))
            }
            return
        }
        if let t = touches.first {
            let p = t.location(in: self); lastPoint = p
            apply(gestures.down(Float(p.x), Float(p.y), time: now))
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let active = Array((event?.allTouches ?? touches).filter { $0.phase != .ended && $0.phase != .cancelled })
        if active.count >= 2 {
            let pts = active.prefix(2).map { $0.location(in: self) }
            if !twoFingerActive {
                twoFingerActive = true
                apply(gestures.twoDown(Float(pts[0].x), Float(pts[0].y), Float(pts[1].x), Float(pts[1].y)))
            } else {
                apply(gestures.twoMove(Float(pts[0].x), Float(pts[0].y), Float(pts[1].x), Float(pts[1].y)))
            }
            return
        }
        if let t = touches.first {
            let p = t.location(in: self); lastPoint = p
            apply(gestures.move(Float(p.x), Float(p.y), time: now))
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let remaining = (event?.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled && !touches.contains($0) }
        if twoFingerActive && remaining.count < 2 {
            gestures.twoUp()
            twoFingerActive = false
        }
        if remaining.isEmpty {
            let p = touches.first?.location(in: self) ?? lastPoint
            apply(gestures.up(Float(p.x), Float(p.y), time: now))
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        twoFingerActive = false
        apply(gestures.cancel())
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
    override func didMoveToWindow() { becomeFirstResponder() }

    private func apply(_ actions: [GestureAction]) {
        guard let c = controller else { return }
        for a in actions {
            switch a {
            case .moveTo(let x, let y):
                c.input(DesktopProtocol.abs(display: c.displayIndex, x: x, y: y))
            case .moveBy(let dx, let dy):
                c.input(DesktopProtocol.rel(dx: dx, dy: dy))
            case .button(let b, let down):
                c.input(DesktopProtocol.button(b, down: down))
            case .wheel(let dx, let dy):
                c.input(DesktopProtocol.wheel(dx: dx, dy: dy))
            case .view(let vp):
                gestures.viewport = vp
            }
        }
    }
}

// MARK: - Small helpers

private struct FlowKeys: View {
    let keys: [(String, [Int])]
    let action: ([Int]) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, item in
                Button(item.0) { action(item.1) }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct VirtualMousePad: View {
    var click: (Int, Bool) -> Void
    var wheel: (Int, Int) -> Void
    @State private var drag: CGSize = .zero
    var body: some View {
        VStack(spacing: 8) {
            Text(modelText).font(.caption2).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 8) {
                mouseBtn(modelTextLeft) { click(1, true); click(1, false) }
                mouseBtn(modelTextRight) { click(2, true); click(2, false) }
            }
            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.15))
                .frame(height: 48)
                .overlay(Text("⇅").foregroundStyle(.white.opacity(0.5)))
                .gesture(DragGesture().onChanged { v in
                    let dy = Int((-v.translation.height + drag.height) / 4)
                    if dy != 0 { wheel(0, dy); drag = .init(width: 0, height: v.translation.height) }
                }.onEnded { _ in drag = .zero })
        }
        .padding(10)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }
    private var modelText: String { "Virtual" }
    private var modelTextLeft: String { "L" }
    private var modelTextRight: String { "R" }
    private func mouseBtn(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).foregroundStyle(.white).frame(maxWidth: .infinity).padding(10)
                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
}
#endif
