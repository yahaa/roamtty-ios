import SwiftUI
import RoamttyDesktopCore
import UIKit
import PhotosUI
import RoamttyCore
import RoamttyTransport

/// Android `TerminalPane`: the terminal fills the page with no bars. Controls live in the toolbox ghost, its
/// shortcut ring and the dock it opens; notices float on the upper golden section over the preserved grid.
///
/// The screen's parts are in `TerminalScreen+*.swift`, which is why its state is not private.
struct TerminalScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runtime: SessionRuntime
    @Environment(\.colorScheme) var scheme
    @StateObject var draft = DraftController()
    @State var toolbox = TerminalToolboxState()
    @State var keyboardVisible = false
    @State var commandSheet = false
    @State var usageSheet = false
    @State var voiceSheet = false
    @State var voiceSheetHeight: CGFloat = 420
    @State var fileAction: TerminalFileAction?
    /// A file a tapped path names, shown in the preview at its line.
    @State var tappedFile: TappedTerminalFile?
    /// A page on the server's loopback that a tapped link names.
    @State var portPreview: PortPreviewRequest?
    @State var launchAfterFiles: AppSheet?
    @State var photoPicker = false
    @State var photos: [PhotosPickerItem] = []
    /// Photos inserting into this terminal; their dialog follows them until each one has an outcome.
    @State var imageJobs: [UUID] = []
    @State var restartConfirm = false
    @State var reverifySheet = false
    @State var editor = false
    /// Until when a double tap's Up/Down/Left keys stay around the pet; each press restarts it.
    @State var petArrowsUntil: TimeInterval = 0
    /// The desktop's small window, focused: its touches and typing go to the desktop. A touch on the terminal gives
    /// the terminal its input back. Focusing does not bring up the keyboard; the bar's keyboard button does.
    @State var pipFocused = false
    @State var pipKeyboard = false
    @State var pipComposing = ""
    @State var pipShortcutBar = true
    @State var pipLatchRevision = 0
    @State var pipKeyboardPage: DesktopKeyboardPage = .ime
    @State var pipIMEFocused = false
    var connected: Bool { runtime.phase == .connected }
    var isAgentSession: Bool { runtime.activeAgentKind != nil }
    var dockAvailable: Bool { connected && !editor && !commandSheet && !usageSheet && !voiceSheet }
    var voiceControlsAvailable: Bool { runtime.voice.active && !editor && !commandSheet && !usageSheet && !voiceSheet }
    /// A double tap or a line starting with `/` brings arrow keys around the pet, while its ring and voice popover are closed.
    var petArrowsShown: Bool {
        dockAvailable && !toolbox.dockVisible && !toolbox.ringOpen
            && !(runtime.voice.active && runtime.voice.popoverOpen)
            && (petArrowsUntil > now || runtime.slashCommandLine)
    }
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// The terminal view sits inside these insets of its viewport, as on Android (portrait 4 / 4 / 6 dp; landscape 10 / 6 / 6 dp).
    static func inset(landscape: Bool) -> EdgeInsets {
        landscape ? EdgeInsets(top: 6, leading: 10, bottom: 0, trailing: 6) : EdgeInsets(top: 6, leading: 4, bottom: 0, trailing: 4)
    }

    var body: some View {
        let content = GeometryReader { page in layout(page) }
        // As on Android, the terminal draws under the transparent status bar, down to the bottom edge and, in
        // landscape, out to both sides instead of leaving the notch bands empty; only the keyboard still pushes it up.
        .ignoresSafeArea(.container)
        .persistentSystemOverlays(.hidden)
        // No visible status bar: expose the phase for VoiceOver and UI tests.
        .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1).accessibilityElement().accessibilityIdentifier("terminal-phase")
                .accessibilityLabel(model.phaseText(runtime.phase))
                .accessibilityValue((runtime.record.mode == .tmux ? "tmux" : "SSH") + " " + runtime.transportName)
        }
        // The terminal colour runs under the status bar and home indicator, like Android's edge-to-edge pane.
        .background(Color(uiColor: SessionRuntime.background(scheme)).ignoresSafeArea())
        .foregroundStyle(Palette.foreground)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        return presentations(timers(events(content)))
    }

    private func layout(_ page: GeometryProxy) -> some View {
        // Keyboard avoidance shrinks page height on portrait iPads. Keep the
        // editor's layout stable so its UITextView retains keyboard focus.
        let windowSize = runtime.terminalView.window?.bounds.size ?? page.size
        let landscape = windowSize.width > windowSize.height
        let twoColumns = TerminalDockGeometry.twoColumns(landscape: landscape, keyboardVisible: keyboardVisible, height: page.size.height)
        let reserved = dockAvailable && toolbox.pinned
        let insets = safeAreaInsets(for: page)
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                terminalColumn(page, landscape: landscape)
                if reserved {
                    dock(in: CGSize(width: twoColumns ? 96 : 48, height: page.size.height), twoColumns: twoColumns, reserved: true)
                        .frame(width: twoColumns ? 96 : 48, height: page.size.height)
                }
            }
            // The dock and the pet step aside from the cursor row, so they follow it without the page.
            CursorRowReader(cursor: runtime.cursorRow) {
                if (dockAvailable || voiceControlsAvailable) && !reserved {
                    floatingControls(in: page.size, safeArea: insets, twoColumns: twoColumns)
                }
            }
            if connected && !editor && isAgentSession {
                let ringTrailing = reserved ? max(insets.trailing, twoColumns ? 96 : 48) + 4 : insets.trailing + 8
                TerminalContextRing(percent: runtime.agentUsage?.contextPercent) {
                    _ = runtime.terminalView.resignFirstResponder()
                    collapseIfFloating()
                    usageSheet = true
                }
                .padding(.top, insets.top + 6)
                .padding(.trailing, ringTrailing)
                .frame(width: page.size.width, height: page.size.height, alignment: .topTrailing)
            }
            if let desktop = pipDesktop { desktopWindow(desktop, page: page, landscape: landscape, reserved: reserved, twoColumns: twoColumns) }
            ImageInsertStatus(transfers: model.files, jobs: $imageJobs, topInset: page.safeAreaInsets.top).frame(width: page.size.width, height: page.size.height)
            voiceToast(topInset: insets.top)
                .frame(width: page.size.width, height: page.size.height, alignment: .top)
        }
    }

    /// The terminal's `GeometryReader` ignores `.container` safe area so it draws edge-to-edge under the status bar
    /// and camera housing, zeroing `page.safeAreaInsets`; read the hosting window's safe area instead (falling back
    /// to the active window before the terminal view attaches).
    func safeAreaInsets(for page: GeometryProxy) -> EdgeInsets {
        let window = (runtime.terminalView.window ?? Self.activeWindow)?.safeAreaInsets ?? .zero
        return EdgeInsets(
            top: max(window.top, page.safeAreaInsets.top),
            leading: max(window.left, page.safeAreaInsets.leading),
            bottom: max(window.bottom, page.safeAreaInsets.bottom),
            trailing: max(window.right, page.safeAreaInsets.trailing)
        )
    }

    private static var activeWindow: UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    /// The terminal with its notice over it, and the text editor's bar below while it is open.
    private func terminalColumn(_ page: GeometryProxy, landscape: Bool) -> some View {
        VStack(spacing: 0) {
            ZStack {
                let inset = Self.inset(landscape: landscape)
                NativeTerminal(runtime: runtime, settings: model.settings).clipped()
                    .overlay {
                        CursorRowReader(cursor: runtime.cursorRow) {
                            if connected && !editor {
                                CursorRowButtons(runtime: runtime, trailingInset: inset.trailing,
                                    bottomInset: keyboardVisible ? 0 : (runtime.terminalView.window?.safeAreaInsets.bottom ?? page.safeAreaInsets.bottom),
                                    avoid: petArrowsShown ? petArrowBounds(in: page.size).offsetBy(dx: -inset.leading, dy: -inset.top) : nil,
                                    keyboardVisible: keyboardVisible)
                            }
                        }
                    }
                    .padding(inset)
                notice.padding(.top, page.safeAreaInsets.top)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            // The bar's controls keep clear of the camera housing that the landscape grid runs under.
            if editor {
                editorBar(landscape: landscape).padding(.leading, page.safeAreaInsets.leading)
                    .padding(.trailing, page.safeAreaInsets.trailing).padding(.bottom, keyboardVisible ? 0 : page.safeAreaInsets.bottom)
            }
        }
    }

    /// The floating dock, or the pet with its shortcut ring, arrow keys, and active voice popover.
    @ViewBuilder
    private func floatingControls(in viewport: CGSize, safeArea: EdgeInsets, twoColumns: Bool) -> some View {
        if toolbox.dockVisible { dock(in: viewport, twoColumns: twoColumns, reserved: false) } else if toolbox.ghostVisible || petArrowsShown {
            let center = petCenter(in: viewport)
            ZStack(alignment: .topLeading) {
                voiceCallOverlay(in: viewport, safeArea: safeArea, center: center)
                GhostShortcuts(
                    runtime: runtime, toolbox: $toolbox, center: center, viewport: viewport,
                    voiceState: runtime.voice.ghostState,
                    voiceStatusTag: runtime.voice.petStatusTag(english: model.english),
                    voicePopoverOpen: runtime.voice.popoverOpen,
                    onHoldBegan: { runtime.voice.popoverOpen = false },
                    onTap: handleGhostTap
                )
                if petArrowsShown { petArrows(center: center).transition(.opacity) }
            }.transition(.opacity.combined(with: .offset(x: 24)))
        }
    }

    @ViewBuilder private var notice: some View {
        if runtime.phase != .connected {
            GoldenSectionLayout {
                // A dropped terminal reconnects by itself, so it shows that instead of the failure.
                if runtime.phase.active || SessionReconnect.onOpen(runtime.end) {
                    TerminalConnectionProgress(phase: runtime.phase, reconnecting: !runtime.phase.active) { runtime.close() }
                } else {
                    TerminalConnectionNotice(phase: runtime.phase, message: runtime.message,
                                             onReconnect: { model.reconnect(runtime.record) },
                                             onShell: { model.reconnect(runtime.record, shell: true) },
                                             onReverify: { reverifySheet = true },
                                             onLeave: { if !model.path.isEmpty { model.path.removeLast() } })
                }
            }
        } else if let message = runtime.message {
            GoldenSectionLayout { TerminalInputNotice(message: message) { runtime.message = nil } }
        }
    }

    // MARK: Events, timers and presentations

    private func events(_ content: some View) -> some View {
        content
            .onAppear { connectRuntime() }
        .onDisappear { toolbox.closeRing(); runtime.pendingPaste = nil; _ = runtime.terminalView.resignFirstResponder() }
        .onChange(of: runtime.workspaceTouches) { _ in
            if pipFocused { unfocusPip() }
            if dockAvailable { toolbox.workspaceTouch(at: now) }
        }
        .onChange(of: pipDesktop == nil) { gone in if gone { unfocusPip() } }
        .onChange(of: runtime.phase) { phase in
            if phase == .connected { toolbox.wake(at: now) } else { toolbox.closeRing(); runtime.pendingPaste = nil }
        }
        .onChange(of: model.settings.toolboxPinned) { pinned in if pinned != toolbox.pinned { toolbox.setPinned(pinned, at: now) } }
        .onChange(of: commandSheet) { _ in toolbox.closeRing() }
        .onChange(of: voiceSheet) { _ in toolbox.closeRing() }
        .onChange(of: runtime.voice.active) { active in toolbox.setVoiceActive(active, at: now) }
        .onChange(of: runtime.petArrowTouches) { _ in withAnimation(.easeOut(duration: 0.12)) { petArrowsUntil = now + 4 }; toolbox.wake(at: now) }
        // A terminal whose connection dropped, or that came back from the journal, reconnects as soon as it is shown.
        .task(id: runtime.end) { await model.reconnectOnOpen(runtime.record) }
        .onChange(of: editor) { _ in toolbox.closeRing() }
    }

    /// The terminal's callbacks into this screen: the font size it was pinched to, and the links and paths tapped in it.
    private func connectRuntime() {
        toolbox.setPinned(model.settings.toolboxPinned, at: now)
        toolbox.setVoiceActive(runtime.voice.active, at: now)
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if ProcessInfo.processInfo.arguments.contains("--voice-ui-fixture") {
            if env["ROAMTTY_VOICE_FIXTURE_DOCK"] == "1" { toolbox.openDock(at: now) }
            if env["ROAMTTY_VOICE_FIXTURE_SHEET"] == "1" { voiceSheet = true }
        }
        #endif
        runtime.onFontScaled = { size in model.settings.fontSize = size; model.saveSettings() }
        runtime.onOpenLoopback = { [weak runtime] url in
            guard let runtime else { return }
            _ = runtime.terminalView.resignFirstResponder()
            portPreview = PortPreviewRequest(url: url, hostName: runtime.host.name) { [weak runtime] in
                guard let ssh = await runtime?.sideConnection() else { throw PortTunnelError.unavailable }
                return ssh
            }
        }
        runtime.onOpenPath = { [weak runtime] path, line in
            _ = runtime?.terminalView.resignFirstResponder(); tappedFile = TappedTerminalFile(path: path, line: line)
        }
    }

    private func timers(_ content: some View) -> some View {
        content
        .task(id: petArrowsUntil) {
            let wait = petArrowsUntil - now
            guard wait > 0 else { return }
            do { try await Task.sleep(for: .seconds(wait)); withAnimation(.easeOut(duration: 0.2)) { petArrowsUntil = 0 } } catch { }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardVisible = frame.height > 0 && frame.minY < UIScreen.main.bounds.maxY
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
        .task(id: toolbox.deadline) {
            guard let deadline = toolbox.deadline else { return }
            do { try await Task.sleep(for: .seconds(max(0, deadline - now))); withAnimation(.easeOut(duration: 0.4)) { toolbox.expire(at: now) } } catch { }
        }
    }

    private func presentations(_ content: some View) -> some View {
        content
        .alert(model.text("重启当前会话？", "Restart this session?"), isPresented: $restartConfirm) {
            Button(model.text("取消", "Cancel"), role: .cancel) { }
            Button(model.text("重启", "Restart")) { model.restartSession(runtime.record) }.accessibilityIdentifier("restart-session-confirm")
        } message: {
            Text(runtime.record.mode == .tmux ? model.text("正在运行的程序会被结束，然后在同一目录重新启动。", "The running program is ended, then started again in the same folder.")
                 : model.text("当前 shell 会结束并重新连接。", "The current shell ends and reconnects."))
        }
        .modifier(TerminalPasteConfirmation(runtime: runtime, enabled: !commandSheet && !usageSheet && !voiceSheet))
        .sheet(isPresented: $commandSheet) { CommandSheet(runtime: runtime).environmentObject(model) }
        .sheet(isPresented: $usageSheet) { AgentUsageSheet(runtime: runtime).environmentObject(model) }
        .sheet(isPresented: $voiceSheet) { voiceConfirmationSheetContent }
        .alert(model.text("语音通话提示", "Voice Session"), isPresented: Binding(
            get: { runtime.voice.errorMessage != nil },
            set: { if !$0 { runtime.voice.errorMessage = nil } }
        )) {
            Button(model.text("知道了", "OK"), role: .cancel) { runtime.voice.errorMessage = nil }
        } message: {
            Text(runtime.voice.errorMessage ?? "")
        }
        .sheet(item: $fileAction, onDismiss: {
            // The root launch sheet must wait until its child picker has gone.
            if let launchAfterFiles { self.launchAfterFiles = nil; model.sheet = launchAfterFiles }
        }) { action in
            TerminalFileActions(runtime: runtime, action: action) { agent, directory in
                launchAfterFiles = .launch(runtime.host, agent, directory: directory)
                fileAction = nil
            }.environmentObject(model)
        }
        // Insert image opens the system picker straight from the dock; the photos upload in the background.
        .photosPicker(isPresented: $photoPicker, selection: $photos, maxSelectionCount: 9, matching: .images, preferredItemEncoding: .current)
        .onChange(of: photoPicker) { presented in model.childModalCount = max(0, model.childModalCount + (presented ? 1 : -1)) }
        .onChange(of: photos) { selected in
            guard !selected.isEmpty else { return }
            imageJobs += model.files.uploadImages(selected, runtime: runtime); photos = []
        }
        .sheet(item: $tappedFile) { file in
            FilePreviewScreen(host: runtime.host, entry: RemoteEntry(name: file.path.split(separator: "/").last.map(String.init) ?? file.path, path: file.path, isDirectory: false),
                              connectionTarget: .session(runtime), line: file.line).environmentObject(model)
        }
        .fullScreenCover(item: $portPreview) { PortPreviewScreen(request: $0).environmentObject(model) }
        .sheet(isPresented: $reverifySheet) { FingerprintReview(host: runtime.host) { model.reconnect(runtime.record) }.environmentObject(model) }
    }
}
