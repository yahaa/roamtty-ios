import SwiftUI
import UIKit
import RoamttyCore
import RoamttyTransport

/// Android `TerminalPane`: the terminal fills the page with no bars. Controls live in the toolbox ghost, its
/// shortcut ring and the dock it opens; notices float on the upper golden section over the preserved grid.
struct TerminalScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runtime: SessionRuntime
    @StateObject private var draft = DraftController()
    @State private var toolbox = TerminalToolboxState()
    @State private var keyboardVisible = false
    @State private var commandSheet = false
    @State private var fileAction: TerminalFileAction?
    @State private var launchAfterFiles: AppSheet?
    @State private var closeConfirm = false
    @State private var reverifySheet = false
    @State private var editor = false
    @State private var renaming = false
    @State private var renameText = ""
    private var connected: Bool { runtime.phase == .connected }
    private var dockAvailable: Bool { connected && !editor && !commandSheet }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// The terminal view sits inside these insets of its viewport, as on Android (10 / 6 / 6 dp).
    private static let inset = EdgeInsets(top: 6, leading: 10, bottom: 0, trailing: 6)

    var body: some View {
        GeometryReader { page in
            let landscape = page.size.width > page.size.height
            let twoColumns = TerminalDockGeometry.twoColumns(landscape: landscape, keyboardVisible: keyboardVisible, height: page.size.height)
            let reserved = dockAvailable && toolbox.pinned
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ZStack {
                            NativeTerminal(runtime: runtime, settings: model.settings).clipped()
                                .overlay { if connected && !editor { CursorRowButtons(runtime: runtime, trailingInset: Self.inset.trailing) } }
                                .padding(Self.inset)
                            notice
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if editor { editorBar(landscape: landscape) }
                    }
                    if reserved {
                        dock(in: CGSize(width: twoColumns ? 96 : 48, height: page.size.height), twoColumns: twoColumns, reserved: true)
                            .frame(width: twoColumns ? 96 : 48, height: page.size.height)
                    }
                }
                if dockAvailable && !reserved {
                    if toolbox.dockVisible { dock(in: page.size, twoColumns: twoColumns, reserved: false) }
                    else if toolbox.ghostVisible {
                        let frame = TerminalDockGeometry.frame(viewport: page.size, content: CGSize(width: 48, height: 48), avoiding: cursorFrame())
                        GhostShortcuts(runtime: runtime, toolbox: $toolbox, center: CGPoint(x: frame.midX, y: frame.midY), viewport: page.size) {
                            withAnimation(.easeOut(duration: 0.18)) { toolbox.openDock(at: now) }
                        }.transition(.opacity.combined(with: .offset(x: 24)))
                    }
                }
            }
        }
        // No visible status bar: expose the phase for VoiceOver and UI tests.
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1).accessibilityElement().accessibilityIdentifier("terminal-phase")
                .accessibilityLabel(model.phaseText(runtime.phase))
                .accessibilityValue((runtime.record.mode == .tmux ? "tmux" : "SSH") + " " + runtime.transportName)
        }
        // The terminal colour runs under the status bar and home indicator, like Android's edge-to-edge pane.
        .background(Color(uiColor: runtime.terminalView.nativeBackgroundColor).ignoresSafeArea())
        .foregroundStyle(Palette.foreground)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            toolbox.setPinned(model.settings.toolboxPinned, at: now)
            runtime.onFontScaled = { size in model.settings.fontSize = size; model.saveSettings() }
        }
        .onDisappear { toolbox.closeRing(); runtime.pendingPaste = nil; runtime.terminalView.resignFirstResponder() }
        .onChange(of: runtime.workspaceTouches) { _ in if dockAvailable { toolbox.workspaceTouch(at: now) } }
        .onChange(of: runtime.phase) { phase in
            if phase == .connected { toolbox.wake(at: now); runtime.message = nil }
            else { toolbox.closeRing(); runtime.pendingPaste = nil }
        }
        .onChange(of: model.settings.toolboxPinned) { pinned in if pinned != toolbox.pinned { toolbox.setPinned(pinned, at: now) } }
        .onChange(of: commandSheet) { _ in toolbox.closeRing() }
        .onChange(of: editor) { _ in toolbox.closeRing() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardVisible = frame.height > 0 && frame.minY < UIScreen.main.bounds.maxY
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .task(id: toolbox.deadline) {
            guard let deadline = toolbox.deadline else { return }
            do { try await Task.sleep(nanoseconds: UInt64(max(0, deadline - now) * 1_000_000_000)); withAnimation(.easeOut(duration: 0.4)) { toolbox.expire(at: now) } } catch { }
        }
        .alert(model.text("关闭此连接？", "Close this connection?"), isPresented: $closeConfirm) {
            Button(model.text("取消", "Cancel"), role: .cancel) { }
            Button(model.text("关闭连接", "Close connection"), role: .destructive) { model.closeSession(runtime.record) }.accessibilityIdentifier("terminal-close-confirm")
        } message: {
            Text(runtime.record.mode == .tmux ? model.text("远端 tmux 会话会继续运行，会话卡片保留，可稍后重连。", "The remote tmux session keeps running and its card stays, so you can reconnect later.")
                 : model.text("普通 SSH shell 会结束；需要保留的任务请先放入 tmux。", "The plain SSH shell will end. Move work you need to keep into tmux first."))
        }
        .alert(model.text("修改会话标题", "Rename session"), isPresented: $renaming) {
            TextField(model.sessionDefaultTitle(runtime.record), text: $renameText).accessibilityIdentifier("session-title-input")
            Button(model.text("取消", "Cancel"), role: .cancel) { }
            Button(model.text("保存", "Save")) { model.renameSession(runtime.record.id, title: String(renameText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))) }
        } message: { Text(model.text("主机名与会话标题在同一行显示。标题留空则显示会话编号。", "The host name and session title share one line. Leave the title empty to show the session number.")) }
        .modifier(TerminalPasteConfirmation(runtime: runtime, enabled: !commandSheet))
        .sheet(isPresented: $commandSheet) { CommandSheet(runtime: runtime).environmentObject(model) }
        .sheet(item: $fileAction, onDismiss: {
            // The root launch sheet must wait until its child picker has gone.
            if let launchAfterFiles { self.launchAfterFiles = nil; model.sheet = launchAfterFiles }
        }) { action in
            TerminalFileActions(runtime: runtime, action: action) { agent, directory in
                launchAfterFiles = .launch(runtime.host, agent, directory: directory)
                fileAction = nil
            }.environmentObject(model)
        }
        .sheet(isPresented: $reverifySheet) { FingerprintReview(host: runtime.host).environmentObject(model) }
    }

    @ViewBuilder private var notice: some View {
        if runtime.phase != .connected {
            GoldenSectionLayout {
                if runtime.phase.active {
                    TerminalConnectionProgress(phase: runtime.phase) { runtime.close() }
                } else {
                    TerminalConnectionNotice(phase: runtime.phase, message: runtime.message,
                                             onReconnect: { model.reconnect(runtime.record) },
                                             onShell: { model.reconnect(runtime.record, shell: true) },
                                             onReverify: { reverifySheet = true })
                }
            }
        } else if let message = runtime.message {
            GoldenSectionLayout { TerminalInputNotice(message: message) { runtime.message = nil } }
        }
    }

    // MARK: Editor

    @ViewBuilder private func editorBar(landscape: Bool) -> some View {
        let field = DraftEditor(controller: draft, placeholder: model.text("输入文本后，在这里确认", "Type text, then confirm here"), maxLines: keyboardVisible ? 2 : (landscape ? 3 : 4))
            .background(RoundedRectangle(cornerRadius: 10).stroke(Palette.secondary.opacity(0.7), lineWidth: 1))
        let collapse = Button(model.text("收起", "Hide")) { editor = false; runtime.terminalView.resignFirstResponder(); hideKeyboard() }.buttonStyle(TextActionStyle())
        let enter = Button { _ = runtime.send("\r") } label: { Text(landscape ? model.text("回车 ↵", "Enter ↵") : "↵").font(landscape ? .subheadline.weight(.medium) : .system(size: 22)) }
            .buttonStyle(TextActionStyle()).disabled(!connected).accessibilityLabel(model.text("回车", "Enter")).accessibilityIdentifier("prompt-enter")
        let send = Button(model.text("发送文本", "Send text")) { _ = runtime.pasteText(draft.text) }
            .buttonStyle(FilledButtonStyle()).disabled(draft.text.isEmpty || !connected).accessibilityIdentifier("prompt-send")
        if landscape {
            HStack(spacing: 4) { field; DraftInputControls(controller: draft); collapse; enter; send }.padding(.horizontal, 4).padding(.vertical, 2)
        } else {
            VStack(spacing: 0) {
                field
                HStack(spacing: 0) { DraftInputControls(controller: draft); Spacer(); collapse.frame(minWidth: 48); enter.frame(minWidth: 48); send.frame(minWidth: 88) }
            }.padding(4)
        }
    }
    private func hideKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
    /// Android stages clipboard text in the editor instead of typing it straight into the program.
    private func pasteIntoEditor() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        draft.insert(text); editor = true; runtime.terminalView.resignFirstResponder()
    }

    // MARK: Dock

    private func cursorFrame() -> CGRect? {
        guard let row = runtime.cursorRowBounds else { return nil }
        let height: CGFloat = runtime.cursorRowKey == .arrows ? 64 : 32
        let y = Self.inset.top + row.midY
        return CGRect(x: runtime.terminalView.bounds.width + Self.inset.leading + Self.inset.trailing - 40, y: y - height / 2, width: 40, height: height)
    }
    private func collapseIfFloating() { if !toolbox.pinned { toolbox.collapseDock(at: now) } }
    private func dock(in viewport: CGSize, twoColumns: Bool, reserved: Bool) -> some View {
        let controls = dockControls
        let rows = twoColumns ? 1 + (controls.count + 1) / 2 : 2 + controls.count
        let width: CGFloat = twoColumns ? 96 : 48, height = CGFloat(rows) * 48
        let frame = TerminalDockGeometry.frame(viewport: viewport, content: CGSize(width: width, height: height + 12), endInset: reserved ? 0 : 8, avoiding: reserved ? nil : cursorFrame())
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                if twoColumns {
                    HStack(spacing: 0) { collapseButton; sessionMenu }
                    LazyVGrid(columns: [GridItem(.fixed(48), spacing: 0), GridItem(.fixed(48), spacing: 0)], spacing: 0) { ForEach(controls.indices, id: \.self) { controls[$0] } }
                } else {
                    collapseButton; sessionMenu
                    ForEach(controls.indices, id: \.self) { controls[$0] }
                }
            }.padding(.vertical, 6)
        }.frame(width: frame.width, height: frame.height)
            .background(reserved ? Color.clear : Palette.surfaceVariant.opacity(0.78), in: RoundedRectangle(cornerRadius: twoColumns ? 24 : 24))
            .shadow(color: .black.opacity(reserved ? 0 : 0.25), radius: reserved ? 0 : 4, y: 2)
            .position(x: frame.midX, y: frame.midY).accessibilityIdentifier("terminal-dock")
    }
    private var dockControls: [AnyView] {
        let files = connected
        return [
            AnyView(dockButton("ic_cloud_upload", model.text("上传文件", "Upload files"), id: "upload-file", enabled: files) { fileAction = .upload }),
            AnyView(dockButton("ic_cloud_download", model.text("下载文件", "Download files"), id: "download-file", enabled: files) { fileAction = .download }),
            AnyView(dockButton("ic_image", model.text("插入图片", "Insert image"), id: "select-image", enabled: files) { fileAction = .image }),
            AnyView(dockButton("ic_commands", model.text("常用命令", "Common commands"), id: "common-commands", enabled: connected) { runtime.terminalView.resignFirstResponder(); commandSheet = true }),
            AnyView(settingsMenu),
        ]
    }
    private var collapseButton: some View {
        Button {
            runtime.controlArmed = false; runtime.shiftArmed = false
            toolbox.collapseDock(at: now); model.settings.toolboxPinned = false; model.saveSettings()
        } label: { AppIcon("ic_close", size: 20).frame(width: 48, height: 48).contentShape(Rectangle()) }
            .buttonStyle(.plain).accessibilityLabel(model.text("收起操作栏", "Hide toolbar")).accessibilityIdentifier("collapse-dock")
    }
    private func dockButton(_ icon: String, _ label: String, id: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button { action(); collapseIfFloating() } label: { AppIcon(icon).frame(width: 48, height: 48).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(Palette.foreground.opacity(enabled ? 1 : 0.38)).disabled(!enabled)
            .accessibilityLabel(label).accessibilityIdentifier(id)
    }
    private var openSessions: [SessionRecord] { model.records.filter { model.runtimes[$0.id] != nil } }
    private var sessionMenu: some View {
        Menu {
            Button(model.text("返回主机列表", "Back to hosts")) { model.path = [] }
            Button(model.text("返回主机详情", "Back to host details")) { model.path = [.host(runtime.host.id)] }
            Button(model.text("修改会话标题", "Rename session")) { renameText = runtime.record.title; renaming = true }
            if runtime.record.mode == .tmux {
                Button(model.text("新会话", "New session")) {
                    let host = model.host(runtime.host.id) ?? runtime.host
                    model.launch(host, mode: host.mode, directory: "~", agent: nil, mosh: nil)
                }.accessibilityIdentifier("new-session")
            }
            Divider()
            ForEach(openSessions) { other in
                let phase = model.runtimes[other.id]?.phase ?? .disconnected
                Button((other.id == runtime.record.id ? "✓ " : "") + model.sessionTitle(other) + " · " + model.phaseText(phase)) {
                    if other.id != runtime.record.id { model.openSession(other) }
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                AppIcon("ic_sessions")
                Circle().fill(connected ? Palette.accent : Palette.danger).frame(width: 8, height: 8).offset(x: 3, y: -3)
            }.foregroundStyle(Palette.accent).frame(width: 48, height: 48).contentShape(Rectangle())
        }.onTapGesture { runtime.terminalView.resignFirstResponder() }
            .accessibilityLabel(model.text("切换会话：", "Switch session: ") + model.sessionTitle(runtime.record)).accessibilityIdentifier("session-switcher")
    }
    private var settingsMenu: some View {
        let size = Int(model.settings.fontSize.rounded())
        return Menu {
            Button(model.text("编辑文本", "Edit text")) { editor = true; runtime.terminalView.resignFirstResponder() }.accessibilityIdentifier("menu-edit-text")
            Button(toolbox.pinned ? model.text("取消固定操作栏", "Unpin toolbar") : model.text("固定操作栏", "Pin toolbar")) {
                let pinned = !toolbox.pinned; toolbox.setPinned(pinned, at: now); if !pinned { toolbox.openDock(at: now) }
                model.settings.toolboxPinned = pinned; model.saveSettings()
            }.accessibilityIdentifier("terminal-pin-tools")
            Button(model.text("隐藏操作栏", "Hide toolbar")) {
                toolbox.collapseDock(at: now); editor = false; runtime.terminalView.resignFirstResponder()
                model.settings.toolboxPinned = false; model.saveSettings()
            }
            Button(model.text("粘贴", "Paste")) { pasteIntoEditor(); collapseIfFloating() }.accessibilityIdentifier("menu-paste")
            Divider()
            Button(model.text("增大字号 · \(size) pt", "Larger text · \(size) pt")) { setFontSize(model.settings.fontSize + 1) }
            Button(model.text("减小字号 · \(size) pt", "Smaller text · \(size) pt")) { setFontSize(model.settings.fontSize - 1) }
            Divider()
            Button(model.text("关闭连接", "Close connection")) {
                collapseIfFloating()
                if runtime.phase.active { closeConfirm = true } else { model.closeSession(runtime.record) }
            }.accessibilityIdentifier("terminal-close")
        } label: { AppIcon("ic_settings").frame(width: 48, height: 48).contentShape(Rectangle()) }
            .accessibilityLabel(model.text("终端设置", "Terminal settings")).accessibilityIdentifier("terminal-menu")
    }
    private func setFontSize(_ size: Double) {
        model.settings.fontSize = min(28, max(8, size.rounded())); model.saveSettings(); collapseIfFloating()
    }
}

private struct TerminalPasteConfirmation: ViewModifier {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runtime: SessionRuntime
    var enabled = true
    var onSent: () -> Void = { }
    func body(content: Content) -> some View {
        content.alert(model.text("发送多行文本？", "Send multiple lines?"), isPresented: Binding(get: { enabled && runtime.pendingPaste != nil }, set: { if !$0 { runtime.pendingPaste = nil } }), presenting: runtime.pendingPaste) { text in
            Button(model.text("发送", "Send")) { runtime.pendingPaste = nil; if runtime.pasteText(text, confirmed: true) { onSent() } }.disabled(runtime.phase != .connected).accessibilityIdentifier("terminal-paste-send")
            Button(model.text("取消", "Cancel"), role: .cancel) { runtime.pendingPaste = nil }.accessibilityIdentifier("terminal-paste-cancel")
        } message: { _ in Text(model.text("远端尚未启用 bracketed paste。文本中的换行可能立即执行命令，请确认当前程序能安全接收多行输入。", "The remote program has not enabled bracketed paste. Newlines may run commands immediately. Confirm that it can safely receive multiple lines.")) }
    }
}
