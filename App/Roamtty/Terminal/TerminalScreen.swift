import SwiftUI
import RoamttyCore
import RoamttyTransport

struct TerminalScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runtime: SessionRuntime
    @State private var toolbox = TerminalToolboxState()
    @State private var keyboardVisible = false
    @State private var commandSheet = false
    @State private var fileAction: TerminalFileAction?
    @State private var launchAfterFiles: AppSheet?
    @State private var closeConfirm = false
    @State private var settingsSheet = false
    private var dockAvailable: Bool { runtime.phase == .connected && !commandSheet }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PhaseLabel(phase: runtime.phase)
                Badge(text: runtime.record.mode == .tmux ? "tmux" : "SSH")
                if runtime.transportName == "mosh" { Badge(text: "mosh") }
                Spacer()
                Menu {
                    ForEach(model.records.filter { $0.hostID == runtime.host.id }) { record in Button(record.displayTitle) { model.openSession(record) } }
                    Divider()
                    Button(model.text("新会话", "New session"), systemImage: "plus") { model.sheet = .launch(runtime.host, false) }
                } label: { Image(systemName: "rectangle.stack").frame(width: 44, height: 34) }.accessibilityLabel(model.text("切换会话", "Switch session"))
            }.padding(.horizontal, 12).background(Palette.panel)
            if runtime.phase == .connected, let message = runtime.message {
                HStack(alignment: .top, spacing: 8) {
                    Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("terminal-notice")
                    Button { runtime.message = nil } label: { Image(systemName: "xmark") }.accessibilityLabel(model.text("关闭提示", "Dismiss notice"))
                }.foregroundStyle(Palette.warning).padding(12).background(Palette.panel)
            }
            GeometryReader { geometry in
                let windowSize = runtime.terminalView.window?.bounds.size ?? UIScreen.main.bounds.size
                let twoColumns = TerminalDockGeometry.twoColumns(landscape: windowSize.width > windowSize.height, keyboardVisible: keyboardVisible, height: geometry.size.height)
                let reserved = dockAvailable && toolbox.pinned
                HStack(spacing: 0) {
                    ZStack {
                        NativeTerminal(runtime: runtime, settings: model.settings).clipped()
                            .overlay { if !commandSheet { CursorRowButtons(runtime: runtime) } }
                        if runtime.phase != .connected { connectionOverlay }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if reserved {
                        dock(in: CGSize(width: twoColumns ? 96 : 48, height: geometry.size.height), twoColumns: twoColumns, reserved: true)
                            .frame(width: twoColumns ? 96 : 48, height: geometry.size.height)
                    }
                }
                if dockAvailable && !reserved {
                    if toolbox.dockVisible { dock(in: geometry.size, twoColumns: twoColumns, reserved: false) }
                    else if toolbox.ghostVisible {
                        let frame = TerminalDockGeometry.frame(viewport: geometry.size, content: CGSize(width: 48, height: 48), avoiding: cursorFrame(in: geometry.size))
                        GhostShortcuts(runtime: runtime, toolbox: $toolbox, center: CGPoint(x: frame.midX, y: frame.midY), viewport: geometry.size) {
                            withAnimation(.easeOut(duration: 0.18)) { toolbox.openDock(at: now) }
                        }.transition(.opacity.combined(with: .offset(x: 20)))
                    }
                }
            }

        }.pageBackground().navigationTitle(runtime.record.displayTitle).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { Button { runtime.toggleKeyboard() } label: { Image(systemName: "keyboard.chevron.compact.down") }.accessibilityLabel(model.text("切换键盘", "Toggle keyboard")).accessibilityIdentifier("terminal-keyboard") }
            ToolbarItem(placement: .navigationBarTrailing) { Button { closeConfirm = true } label: { Image(systemName: "xmark") }.accessibilityLabel(model.text("关闭会话", "Close session")).accessibilityIdentifier("terminal-close") }
        }
        .onAppear { toolbox.setPinned(model.settings.toolboxPinned, at: now) }
        .onDisappear { toolbox.closeRing(); runtime.pendingPaste = nil; runtime.terminalView.resignFirstResponder() }
        .onChange(of: runtime.workspaceTouches) { _ in if dockAvailable { toolbox.workspaceTouch(at: now) } }
        .onChange(of: runtime.phase) { phase in if phase == .connected { toolbox.wake(at: now) } else { toolbox.closeRing(); runtime.pendingPaste = nil } }
        .onChange(of: model.settings.toolboxPinned) { pinned in if pinned != toolbox.pinned { toolbox.setPinned(pinned, at: now) } }
        .onChange(of: commandSheet) { _ in toolbox.closeRing() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardVisible = frame.height > 0 && frame.minY < UIScreen.main.bounds.maxY
        }
        .task(id: toolbox.deadline) {
            guard let deadline = toolbox.deadline else { return }
            do { try await Task.sleep(nanoseconds: UInt64(max(0, deadline - now) * 1_000_000_000)); withAnimation(.easeOut(duration: 0.4)) { toolbox.expire(at: now) } } catch { }
        }
        .confirmationDialog(model.text("关闭会话？", "Close session?"), isPresented: $closeConfirm, titleVisibility: .visible) {
            Button(model.text("关闭", "Close"), role: .destructive) { model.closeSession(runtime.record) }.accessibilityIdentifier("terminal-close-confirm")
        } message: { Text(runtime.record.mode == .tmux ? model.text("远程 tmux 会话会继续运行，可随时恢复。", "The remote tmux session keeps running and can be resumed.") : model.text("普通 SSH 进程将随连接关闭。", "The plain SSH session will end.")) }
        .modifier(TerminalPasteConfirmation(runtime: runtime, enabled: !commandSheet))
        .sheet(isPresented: $commandSheet) { CommandSheet(runtime: runtime).environmentObject(model).presentationDetents([.medium, .large]) }
        .sheet(item: $fileAction, onDismiss: {
            // The root launch sheet must wait until its child picker has gone.
            if let launchAfterFiles { self.launchAfterFiles = nil; model.sheet = launchAfterFiles }
        }) { action in
            TerminalFileActions(runtime: runtime, action: action) { agent, directory in
                launchAfterFiles = .launch(runtime.host, agent, directory: directory)
                fileAction = nil
            }.environmentObject(model)
        }
        .sheet(isPresented: $settingsSheet) { FingerprintReview(host: runtime.host).environmentObject(model) }
    }
    private var connectionOverlay: some View {
        VStack(spacing: 12) {
            if runtime.phase.active { ProgressView() }
            Text(model.phaseText(runtime.phase)).font(.headline)
            if let message = runtime.message { Text(message).font(.footnote).textSelection(.enabled).multilineTextAlignment(.center) }
            if !runtime.phase.active {
                Button(model.text("重新连接", "Reconnect")) { model.reconnect(runtime.record) }.buttonStyle(RoamButtonStyle(primary: true)).accessibilityIdentifier("terminal-reconnect")
                if runtime.phase == .tmuxMissing {
                    Button(model.text("使用普通 SSH", "Use plain SSH")) { model.reconnect(runtime.record, shell: true) }.buttonStyle(RoamButtonStyle())
                    Button(model.text("安装 tmux", "Install tmux")) { model.sheet = .plugins(runtime.host) }
                }
                if runtime.phase == .hostKeyChanged { Button(model.text("查看并重新验证", "Review and verify again")) { settingsSheet = true } }
            }
        }.padding(20).frame(maxWidth: 340).background(Palette.raised.opacity(0.97), in: RoundedRectangle(cornerRadius: 20)).padding(24).frame(maxWidth: .infinity)
    }
    private func cursorFrame(in size: CGSize) -> CGRect? {
        guard let row = runtime.cursorRowBounds else { return nil }
        let height: CGFloat = runtime.cursorRowKey == .arrows ? 64 : 32
        let y = min(max(row.midY, height / 2), max(height / 2, size.height - height / 2))
        return CGRect(x: max(0, size.width - 40), y: y - height / 2, width: 40, height: height)
    }
    private func dock(in viewport: CGSize, twoColumns: Bool, reserved: Bool) -> some View {
        let width: CGFloat = twoColumns ? 96 : 48, height: CGFloat = twoColumns ? 288 : 576
        let frame = TerminalDockGeometry.frame(viewport: viewport, content: CGSize(width: width, height: height), endInset: reserved ? 0 : 8, avoiding: reserved ? nil : cursorFrame(in: viewport))
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 0), count: twoColumns ? 2 : 1), spacing: 0) {
                tool("xmark", model.text("收起操作栏", "Collapse tools"), closeAfter: false) {
                    toolbox.collapseDock(at: now); model.settings.toolboxPinned = false; model.saveSettings()
                }.accessibilityIdentifier("collapse-dock")
                tool("keyboard", model.text("键盘", "Keyboard")) { runtime.toggleKeyboard() }
                tool("doc.on.clipboard", model.text("粘贴", "Paste")) { runtime.paste() }
                tool("selection.pin.in.out", model.text("选择", "Select")) { runtime.terminalView.selectAll() }
                tool("doc.on.doc", model.text("复制", "Copy")) { runtime.copySelection() }
                tool("folder", model.text("文件", "Files")) { model.path.append(.files(runtime.host.id, sessionID: runtime.record.id, directory: runtime.currentDirectory)) }
                tool("square.and.arrow.up", model.text("上传文件", "Upload file")) { fileAction = .upload }.accessibilityIdentifier("upload-file")
                tool("square.and.arrow.down", model.text("下载文件", "Download file")) { fileAction = .download }.accessibilityIdentifier("download-file")
                tool("photo", model.text("插入图片", "Insert image")) { fileAction = .image }.accessibilityIdentifier("select-image")
                tool("text.badge.plus", model.text("命令", "Commands")) { commandSheet = true }.accessibilityIdentifier("terminal-commands")
                tool(toolbox.pinned ? "pin.slash" : "pin", toolbox.pinned ? model.text("取消固定操作栏", "Unpin tools") : model.text("固定操作栏", "Pin tools"), closeAfter: false) {
                    let pinned = !toolbox.pinned; toolbox.setPinned(pinned, at: now); if !pinned { toolbox.openDock(at: now) }
                    model.settings.toolboxPinned = pinned; model.saveSettings()
                }.accessibilityIdentifier("terminal-pin-tools")
                tool("gearshape", model.text("设置", "Settings")) { model.sheet = .settings }
            }
        }.frame(width: frame.width, height: frame.height)
            .background(Palette.raised.opacity(reserved ? 1 : 0.78), in: RoundedRectangle(cornerRadius: twoColumns ? 24 : 48))
            .shadow(radius: reserved ? 0 : 4).position(x: frame.midX, y: frame.midY).accessibilityIdentifier("terminal-dock")
    }
    private func tool(_ icon: String, _ label: String, closeAfter: Bool = true, action: @escaping () -> Void) -> some View {
        Button { action(); if closeAfter && !toolbox.pinned { toolbox.collapseDock(at: now) } } label: { Image(systemName: icon).frame(width: 48, height: 48) }.accessibilityLabel(label)
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
struct CommandSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @ObservedObject var runtime: SessionRuntime
    @State private var connectionTarget: RemoteConnectionTarget
    @State private var command = ""
    @State private var query = ""
    @State private var historyCommands: [String] = []
    @State private var recentCommands: [String] = []
    @State private var historySource = ""
    @State private var historyFailure: String?
    @State private var historyLoading = false
    @State private var refreshID = 0
    @State private var selectedHistory: String?
    @State private var executionFailure: String?
    @State private var running = false
    @State private var executionCancellation: TransferCancellation?
    init(runtime: SessionRuntime) {
        self.runtime = runtime
        _connectionTarget = State(initialValue: .session(runtime))
    }
    private var filteredHistory: [String] { ShellHistoryCommands.fuzzyFilter(ShellHistoryCommands.mergeRecent(recentCommands, saved: historyCommands), query: query) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                CommandDraftEditor(text: $command).font(.system(.body, design: .monospaced)).frame(minHeight: 90, maxHeight: 160).padding(8).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12)).accessibilityLabel(model.text("命令草稿", "Command draft")).accessibilityIdentifier("command-draft")
                HStack {
                    Button(model.text("保存", "Save")) { model.saveCommand(command) }.buttonStyle(RoamButtonStyle())
                    Button(model.text("插入", "Insert")) { insertCommand() }.buttonStyle(RoamButtonStyle()).accessibilityIdentifier("command-insert")
                    Button(model.text("执行", "Run")) { Task { await runCommand() } }.buttonStyle(RoamButtonStyle(primary: true)).accessibilityIdentifier("command-run")
                }.disabled(command.isEmpty || runtime.phase != .connected || running)
                if let executionFailure { Text(executionFailure).font(.footnote).foregroundStyle(Palette.danger).accessibilityIdentifier("command-error") }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                    TextField(model.text("搜索命令", "Search commands"), text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("history-search")
                    Button { refreshID += 1 } label: { Image(systemName: "arrow.clockwise") }.disabled(historyLoading).accessibilityLabel(model.text("刷新 shell 历史", "Refresh shell history")).accessibilityIdentifier("history-refresh")
                }
                List {
                    if !model.commands.isEmpty {
                        Section(model.text("已保存", "Saved")) {
                            ForEach(ShellHistoryCommands.fuzzyFilter(model.commands, query: query), id: \.self) { value in
                                Button { command = value; selectedHistory = nil; executionFailure = nil } label: { commandLabel(value) }.swipeActions { Button(role: .destructive) { model.removeCommand(value) } label: { Label(model.text("删除", "Delete"), systemImage: "trash") } }
                            }
                        }
                    }
                    Section {
                        if historyLoading { ProgressView().accessibilityIdentifier("history-loading") }
                        if let historyFailure { Text(historyFailure).font(.footnote).foregroundStyle(Palette.secondary) }
                        ForEach(Array(filteredHistory.enumerated()), id: \.element) { index, value in
                            Button { command = value; selectedHistory = value; executionFailure = nil } label: { commandLabel(value) }.accessibilityIdentifier("history-command-\(index)")
                        }
                        if !historyLoading && historyFailure == nil && filteredHistory.isEmpty { Text(model.text("没有匹配的 shell 历史命令", "No matching shell history commands")).font(.footnote).foregroundStyle(Palette.secondary) }
                    } header: { Text(historySource.isEmpty ? model.text("Shell 历史", "Shell history") : historySource).accessibilityIdentifier("history-source") }
                }.scrollContentBackground(.hidden).accessibilityIdentifier("command-history-list")
            }.padding(16).pageBackground().navigationTitle(model.text("常用命令", "Commands")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(model.text("完成", "Done")) { dismiss() }.accessibilityIdentifier("command-done") } }
        }.modifier(ChildModalPresence()).overlay { AuthenticationOverlay() }.modifier(TerminalPasteConfirmation(runtime: runtime, onSent: { dismiss() }))
            .task(id: refreshID) { await refreshHistory() }
            .onDisappear { executionCancellation?.cancel() }
            .onChange(of: command) { value in if selectedHistory != value { selectedHistory = nil }; executionFailure = nil }
    }
    private func commandLabel(_ value: String) -> some View { Text(value).font(.system(.subheadline, design: .monospaced)).foregroundStyle(Palette.foreground).lineLimit(3) }
    private func refreshHistory() async {
        historyLoading = true; historyFailure = nil
        let cancellation = TransferCancellation()
        await withTaskCancellationHandler(operation: {
            do {
                let ssh = try await model.connection(for: connectionTarget)
                let result = try await ShellHistoryCommands.load { path in
                    try model.validate(connectionTarget)
                    // Keep history in memory and read a bounded tail, including a truncation marker.
                    let script = "f=\"$HOME/\(path)\"; [ -r \"$f\" ] || exit 1; n=$(wc -c < \"$f\") || exit 1; printf '%s\\n' \"$n\"; tail -c 262144 \"$f\""
                    let response = try await performInBackground { try ssh.exec("/bin/sh -c " + RemoteCommands.shellQuote(script), input: Data(), timeout: 8, cancellation: cancellation) }
                    guard response.status == 0, let newline = response.output.firstIndex(of: 10) else { return nil }
                    let sizeLine = String(decoding: response.output[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let size = Int64(sizeLine) else { return nil }
                    return (String(decoding: response.output[response.output.index(after: newline)...], as: UTF8.self), size > 262144)
                }
                try Task.checkCancellation()
                try model.validate(connectionTarget)
                historyCommands = result?.commands ?? []; historySource = result?.source ?? ""
                if result == nil { historyFailure = model.text("无法读取可用的 bash 或 zsh 历史。", "No usable bash or zsh history is available.") }
            } catch { if !Task.isCancelled { historyFailure = error.localizedDescription } }
        }, onCancel: { cancellation.cancel() })
        if !Task.isCancelled { historyLoading = false }
    }
    private func insertCommand() {
        do { try model.validate(connectionTarget) } catch { executionFailure = error.localizedDescription; return }
        if runtime.pasteText(command) { dismiss() }
        else if runtime.pendingPaste == nil { executionFailure = model.text("未发送：连接未就绪或输入队列已满。", "Not sent: connection unavailable or input queue full.") }
    }
    private func runCommand() async {
        guard !running else { return }
        running = true; executionFailure = nil
        let cancellation = TransferCancellation(); executionCancellation = cancellation
        defer { running = false; executionCancellation = nil }
        let value = command, fromHistory = selectedHistory == command
        do {
            try model.validate(connectionTarget)
            var fullScreen = runtime.terminalView.getTerminal().isCurrentBufferAlternate
            if runtime.record.mode == .tmux {
                let ssh = try await model.connection(for: connectionTarget)
                let script = RemoteCommands.tmuxAlternateScreen(runtime.record.remoteName)
                let result = try await performInBackground { try ssh.exec(script, input: Data(), timeout: 8, cancellation: cancellation) }
                fullScreen = result.status != 0 || String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) != "0"
            }
            guard !cancellation.isCancelled, !Task.isCancelled else { return }
            try model.validate(connectionTarget)
            guard !fullScreen else { executionFailure = model.text("请先退出全屏程序，再执行 shell 命令。", "Exit the full-screen program before running a shell command."); return }
            let bracketed = runtime.terminalView.getTerminal().bracketedPasteMode
            let input = fromHistory ? try ShellHistoryCommands.executionInput(value, bracketed: bracketed) : (bracketed ? "\u{1b}[200~" + value + "\u{1b}[201~" : value) + "\r"
            guard runtime.send(input) else { executionFailure = model.text("未发送：连接未就绪或输入队列已满。", "Not sent: connection unavailable or input queue full."); return }
            if fromHistory { recentCommands = ShellHistoryCommands.mergeRecent([value], saved: recentCommands) }
            dismiss()
        } catch { executionFailure = error.localizedDescription }
    }
}
