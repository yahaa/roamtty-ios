import SwiftUI
import UIKit
import RoamttyCore

/// The toolbox: the dock of controls (floating or pinned), the pet's arrow keys, and the dock's session and
/// settings menus.
extension TerminalScreen {
    func cursorFrame(in viewport: CGSize) -> CGRect? {
        guard let row = runtime.cursorRowBounds else { return nil }
        let inset = Self.inset(landscape: viewport.width > viewport.height)
        let height: CGFloat = 32, width: CGFloat = keyboardVisible ? 80 : 40
        let y = inset.top + row.midY
        return CGRect(x: runtime.terminalView.bounds.width + inset.leading + inset.trailing - width, y: y - height / 2, width: width, height: height)
    }
    func petCenter(in viewport: CGSize) -> CGPoint {
        let frame = TerminalDockGeometry.frame(viewport: viewport, content: CGSize(width: 48, height: 48), avoiding: cursorFrame(in: viewport))
        return CGPoint(x: frame.midX, y: frame.midY)
    }
    /// Up above the pet, Down below it and Left to its left; the pet stays put between them.
    func petArrowBounds(in viewport: CGSize) -> CGRect {
        let center = petCenter(in: viewport)
        return CGRect(x: center.x - 64, y: center.y - 56, width: 88, height: 112)
    }
    func petArrows(center: CGPoint) -> some View {
        ZStack(alignment: .topLeading) {
            CursorKeyButton(icon: "ic_expand_up", label: model.text("发送上方向键", "Send Up arrow"), id: "pet-arrow-up") { runtime.sendPetArrow("A") }
                .position(x: center.x, y: center.y - 40)
            CursorKeyButton(icon: "ic_expand_down", label: model.text("发送下方向键", "Send Down arrow"), id: "pet-arrow-down") { runtime.sendPetArrow("B") }
                .position(x: center.x, y: center.y + 40)
            CursorKeyButton(icon: "ic_expand_left", label: model.text("发送左方向键", "Send Left arrow"), id: "pet-arrow-left") { runtime.sendPetArrow("D") }
                .position(x: center.x - 44, y: center.y)
        }
    }
    func collapseIfFloating() { if !toolbox.pinned { toolbox.collapseDock(at: now) } }
    func dock(in viewport: CGSize, twoColumns: Bool, reserved: Bool) -> some View {
        let rows = twoColumns ? 1 + (dockControlCount + 1) / 2 : 2 + dockControlCount
        let width: CGFloat = twoColumns ? 96 : 48, height = CGFloat(rows) * 48
        let frame = TerminalDockGeometry.frame(viewport: viewport, content: CGSize(width: width, height: height + 12), endInset: reserved ? 0 : 8, avoiding: reserved ? nil : cursorFrame(in: viewport))
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                if twoColumns {
                    HStack(spacing: 0) { collapseButton; sessionMenu }
                    LazyVGrid(columns: [GridItem(.fixed(48), spacing: 0), GridItem(.fixed(48), spacing: 0)], spacing: 0) { dockControls }
                } else {
                    collapseButton; sessionMenu
                    dockControls
                }
            }.padding(.vertical, 6)
        }.frame(width: frame.width, height: frame.height)
            .background(reserved ? Color.clear : Palette.surfaceVariant.opacity(0.78), in: RoundedRectangle(cornerRadius: twoColumns ? 24 : 24))
            .shadow(color: .black.opacity(reserved ? 0 : 0.25), radius: reserved ? 0 : 4, y: 2)
            .position(x: frame.midX, y: frame.midY).accessibilityIdentifier("terminal-dock")
    }
    /// The keys below the dock's collapse and session keys; `dockControlCount` sizes the dock for them.
    /// Android `TerminalPane` primaryControls: desktop (when probe YES) before files, then commands and settings.
    @ViewBuilder var dockControls: some View {
        if showDesktopDock { desktopDockButton }
        if showVoiceDock { voiceDockButton }
        dockButton("ic_cloud_upload", model.text("上传文件", "Upload files"), id: "upload-file", enabled: connected) { fileAction = .upload }
        dockButton("ic_cloud_download", model.text("下载文件", "Download files"), id: "download-file", enabled: connected) { fileAction = .download }
        dockButton("ic_image", model.text("插入图片", "Insert image"), id: "select-image", enabled: connected) { photoPicker = true }
        if !isAgentSession {
            dockButton("ic_commands", model.text("常用命令", "Common commands"), id: "common-commands", enabled: connected) { _ = runtime.terminalView.resignFirstResponder(); commandSheet = true }
        }
        settingsMenu
    }
    var dockControlCount: Int { 4 + (isAgentSession ? 0 : 1) + (showDesktopDock ? 1 : 0) + (showVoiceDock ? 1 : 0) }
    var collapseButton: some View {
        Button {
            runtime.controlArmed = false; runtime.shiftArmed = false
            toolbox.collapseDock(at: now); model.settings.toolboxPinned = false; model.saveSettings()
        } label: {
            // Android: countdown ring on ✕ while a floating dock's quiet spell runs.
            ZStack {
                if toolbox.floatingDock, TerminalToolboxState.dockHideSeconds > 0 {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { _ in
                        let p = toolbox.dockHideProgress(at: ProcessInfo.processInfo.systemUptime)
                        ZStack {
                            Circle().stroke(Palette.foreground.opacity(0.12), lineWidth: 2)
                            Circle().trim(from: 0, to: p)
                                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                                .rotationEffect(.degrees(-90))
                        }.frame(width: 32, height: 32)
                    }
                }
                AppIcon("ic_close", size: 20)
            }.frame(width: 48, height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(model.text("收起操作栏", "Hide toolbar")).accessibilityIdentifier("collapse-dock")
    }
    func dockButton(_ icon: String, _ label: String, id: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button { toolbox.touchDock(at: now); action(); collapseIfFloating() } label: { AppIcon(icon).frame(width: 48, height: 48).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(Palette.foreground.opacity(enabled ? 1 : 0.38)).disabled(!enabled)
            .accessibilityLabel(label).accessibilityIdentifier(id)
    }
    var openSessions: [SessionRecord] { model.sessionsNewestFirst.filter { model.runtimes[$0.id] != nil } }
    var sessionMenu: some View {
        Menu {
            Button(model.text("返回主机详情", "Back to host details")) { afterMenuSelection { model.path = model.host(runtime.host.id) == nil ? [] : [.host(runtime.host.id)] } }
            // Closing ends the session on the server, without asking, and returns to the session list.
            Button(runtime.record.external ? model.text("断开当前会话", "Detach session") : model.text("关闭当前会话", "Close session")) {
                afterMenuSelection { model.closeSession(runtime.record) }
            }.accessibilityIdentifier("close-session")
            // A tmux pane restarts over the live connection; a plain shell restarts by reconnecting.
            Button(model.text("重启当前会话", "Restart session")) { restartConfirm = true }
                .disabled(runtime.record.mode == .tmux && !connected).accessibilityIdentifier("restart-session")
            Divider()
            ForEach(openSessions) { other in
                let otherRuntime = model.runtimes[other.id]
                let phase = otherRuntime?.phase ?? .disconnected
                let title = (other.id == runtime.record.id ? "✓ " : "") + model.sessionTitle(other) + " · " + model.phaseText(phase)
                let inCall = otherRuntime?.voice.active ?? false
                Button {
                    if other.id != runtime.record.id { afterMenuSelection { model.openSession(other) } }
                } label: {
                    if inCall {
                        Label(title, systemImage: "phone.fill")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                AppIcon("ic_sessions")
                Circle().fill(connected ? Palette.accent : Palette.danger).frame(width: 8, height: 8).offset(x: 3, y: -3)
            }.foregroundStyle(Palette.accent).frame(width: 48, height: 48).contentShape(Rectangle())
        }.onTapGesture { _ = runtime.terminalView.resignFirstResponder(); toolbox.touchDock(at: now) }
            .accessibilityLabel(model.text("切换会话：", "Switch session: ") + model.sessionTitle(runtime.record)).accessibilityIdentifier("session-switcher")
    }
    /// For a menu item that can take the dock off the screen. UIKit asks the menu's button for its dismissal preview
    /// as soon as the item's action returns, and aborts if the button has left the window. SwiftUI normally removes it
    /// later, but putting the keyboard away lays the page out on the spot, so such work waits for the next turn.
    func afterMenuSelection(_ action: @escaping () -> Void) { DispatchQueue.main.async(execute: action) }
    var settingsMenu: some View {
        let size = Int(model.settings.fontSize.rounded())
        return Menu {
            Button(model.text("编辑文本", "Edit text")) { afterMenuSelection { editor = true; _ = runtime.terminalView.resignFirstResponder() } }.accessibilityIdentifier("menu-edit-text")
            Button(toolbox.pinned ? model.text("取消固定操作栏", "Unpin toolbar") : model.text("固定操作栏", "Pin toolbar")) {
                let pinned = !toolbox.pinned; toolbox.setPinned(pinned, at: now); if !pinned { toolbox.openDock(at: now) }
                model.settings.toolboxPinned = pinned; model.saveSettings()
            }.accessibilityIdentifier("terminal-pin-tools")
            Button(model.text("隐藏操作栏", "Hide toolbar")) {
                afterMenuSelection {
                    toolbox.collapseDock(at: now); editor = false; _ = runtime.terminalView.resignFirstResponder()
                    model.settings.toolboxPinned = false; model.saveSettings()
                }
            }
            Button(model.text("粘贴", "Paste")) { afterMenuSelection { pasteIntoEditor(); collapseIfFloating() } }.accessibilityIdentifier("menu-paste")
            Divider()
            Button(model.text("增大字号 · \(size) pt", "Larger text · \(size) pt")) { setFontSize(model.settings.fontSize + 1) }
            Button(model.text("减小字号 · \(size) pt", "Smaller text · \(size) pt")) { setFontSize(model.settings.fontSize - 1) }
        } label: { AppIcon("ic_settings").frame(width: 48, height: 48).contentShape(Rectangle()) }
            .onTapGesture { toolbox.touchDock(at: now) }
            .accessibilityLabel(model.text("终端设置", "Terminal settings")).accessibilityIdentifier("terminal-menu")
    }
    func setFontSize(_ size: Double) {
        model.settings.fontSize = min(28, max(8, size.rounded())); model.saveSettings(); collapseIfFloating()
    }
}
