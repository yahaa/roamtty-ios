import SwiftUI
import RoamttyCore
import RoamttyTransport

struct LaunchScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let host: Host
    let forAgent: Bool
    var initialDirectory = "~"
    /// The agent already picked (the new-session sheet asks for it first); otherwise the last one used.
    var initialAgent: CodingAgent? = nil
    /// Replaces the heading when the sheet is a step of a longer flow.
    var title: String? = nil
    @State private var agent = CodingAgent.codex
    @State private var agentMode = AgentMode.yolo
    @State private var sessionMode = SessionMode.tmux
    @State private var sessionModeExplicit = false
    @State private var directory = "~"
    @State private var pathDraft = "~"
    @State private var entries: [RemoteEntry] = []
    @State private var busy = false
    @State private var error: String?
    @State private var filter = ""
    @State private var mosh = false
    @State private var moshExplicit = false
    @State private var recent: [String] = []
    @State private var homeDirectory: String?
    @State private var loadRevision = 0
    @State private var loadTask: Task<Void, Never>?
    @State private var loadCancellation: TransferCancellation?
    /// Opening a terminal can start in a folder or attach a tmux session already on the server.
    @State private var source = Source.folder
    @State private var tmuxSessions: [TmuxSessionInfo]?
    @State private var tmuxError: String?
    @State private var tmuxBusy = false
    @State private var tmuxSelection: String?
    private enum Source: Hashable { case folder, tmux }
    /// A plain terminal opened without a folder in mind may attach a tmux session instead.
    private var canAttach: Bool { !forAgent && StartDirectory.isHome(initialDirectory) }
    private var attachReady: Bool { tmuxSessions?.contains { $0.name == tmuxSelection && $0.attachable } == true }
    private var launchReady: Bool { !busy && error == nil && StartDirectory.isSupported(pathDraft) && StartDirectory.normalize(pathDraft) == directory }
    private var segments: [(name: String, path: String)] { StartDirectory.segments(directory) }
    private var parent: String? {
        if segments.count >= 2 { return segments[segments.count - 2].path }
        if directory == "~", let homeDirectory, homeDirectory != "/" { return parentRemotePath(homeDirectory) }
        return nil
    }
    private var folders: [RemoteEntry] { entries.filter { $0.isDirectory && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter.trimmingCharacters(in: .whitespaces))) } }
    private var folderName: String { StartDirectory.isHome(directory) ? model.text("主目录", "home") : (directory.split(separator: "/").last.map(String.init) ?? "/") }
    private var launchTitle: String {
        let home = StartDirectory.isHome(directory)
        if forAgent { return home ? model.text("在主目录启动 \(agent.shortLabel)", "Start \(agent.shortLabel) in home") : model.text("在 \(folderName) 启动 \(agent.shortLabel)", "Start \(agent.shortLabel) in \(folderName)") }
        return home ? model.text("在主目录打开终端", "Open terminal in home") : model.text("在 \(folderName) 打开终端", "Open terminal in \(folderName)")
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title ?? (forAgent ? model.text("用 AI Agent打开", "Open with AI Agent") : model.text("打开终端", "Open terminal"))).font(.system(size: 20, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { AppIcon("ic_close").frame(width: 48, height: 48) }.accessibilityLabel(model.text("关闭", "Close")).accessibilityIdentifier("launch-cancel")
            }.padding(.leading, 24).padding(.trailing, 12).padding(.top, 16).padding(.bottom, 12)
            if canAttach {
                Picker("", selection: $source) {
                    Text(model.text("工作目录", "Folder")).tag(Source.folder)
                    Text(model.text("tmux 会话", "tmux session")).tag(Source.tmux)
                }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 12).accessibilityIdentifier("launch-source")
            }
            if source == .tmux { tmuxPanel } else { folderPanel }
        }.foregroundStyle(Palette.foreground).background(Palette.sheet.ignoresSafeArea())
        .task {
            let currentHost = model.host(host.id) ?? host
            sessionMode = currentHost.newSessionMode; mosh = currentHost.plugins?.contains("mosh") == true
            recent = StartDirectory.sanitizeRecent(UserDefaults.standard.stringArray(forKey: "recentFolders-\(host.id)") ?? [])
            agent = initialAgent ?? CodingAgent.from(UserDefaults.standard.string(forKey: "launchAgent"))
            agentMode = UserDefaults.standard.string(forKey: "launchAgentMode").map(AgentMode.from) ?? .yolo
            navigate(initialDirectory)
        }.onChange(of: model.host(host.id)?.plugins) { plugins in
            if !moshExplicit { mosh = plugins?.contains("mosh") == true }
            if !sessionModeExplicit { sessionMode = (model.host(host.id) ?? host).newSessionMode }
        }
        .onChange(of: source) { value in if value == .tmux && tmuxSessions == nil && !tmuxBusy { loadTmux() } }
        .onDisappear { loadTask?.cancel(); loadCancellation?.cancel(); loadRevision += 1 }
    }
    @ViewBuilder private var folderPanel: some View {
        if !recent.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { ForEach(recent, id: \.self) { path in recentChip(path) } }.padding(.horizontal, 16)
            }.padding(.bottom, 8)
        }
        VStack(spacing: 0) {
            if filtering { filterBar } else { pathBar }
            Divider().overlay(Palette.outline)
            ZStack(alignment: .top) {
                if let error { centerNote(error, id: "launch-error", action: StartDirectory.isHome(directory) ? model.text("重试", "Retry") : model.text("回到主目录", "Back to home")) { navigate("~") } }
                else if entries.isEmpty && busy { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { folderList }
                if busy && !entries.isEmpty { ProgressView().progressViewStyle(.linear).tint(Palette.accent) }
            }.frame(maxHeight: .infinity)
        }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 16)
        if forAgent { agentChooser }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { testControls }
        #endif
        Button {
            guard launchReady else { return }
            let normalized = StartDirectory.normalize(directory)
            recent = StartDirectory.remember(recent: recent, directory: normalized); persistRecent()
            if forAgent { UserDefaults.standard.set(agent.rawValue, forKey: "launchAgent"); UserDefaults.standard.set(agentMode.rawValue, forKey: "launchAgentMode") }
            let launch = forAgent ? AgentLaunch(agent: agent, directory: normalized, mode: agentMode) : nil
            model.launch(host, mode: sessionMode, directory: normalized, agent: launch, mosh: moshExplicit ? mosh : nil)
        } label: {
            HStack(spacing: 8) {
                if forAgent { AppIcon("ic_agent", size: 18) }
                Text(launchTitle).lineLimit(1)
            }.font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).frame(minHeight: 48)
                .foregroundStyle(launchReady ? (yolo ? Palette.adaptive(0xFFFFFF, 0x5E1C17) : Palette.onAccent) : Palette.foreground.opacity(0.38))
                .background(launchReady ? (yolo ? Palette.danger : Palette.accent) : Palette.foreground.opacity(0.12), in: Capsule())
                .animation(.easeInOut(duration: 0.2), value: yolo)
        }.buttonStyle(.plain).disabled(!launchReady).padding(.horizontal, 16).padding(.vertical, 12).accessibilityIdentifier("launch-session")
    }
    /// The tmux sessions on the server, most recently used first; tapping one picks it, the button attaches it.
    @ViewBuilder private var tmuxPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.text("服务器上的 tmux 会话", "tmux sessions on the server")).font(.subheadline.weight(.semibold))
                Spacer()
                Button { loadTmux() } label: { AppIcon("ic_refresh", size: 20).frame(width: 40, height: 40) }.disabled(tmuxBusy)
                    .accessibilityLabel(model.text("刷新", "Refresh")).accessibilityIdentifier("launch-tmux-refresh")
            }.padding(.leading, 16).padding(.trailing, 4).frame(minHeight: 48)
            Divider().overlay(Palette.outline)
            ZStack(alignment: .top) {
                if let tmuxError { centerNote(tmuxError, id: "launch-tmux-error", action: model.text("重试", "Retry")) { loadTmux() } }
                else if let tmuxSessions {
                    if tmuxSessions.isEmpty { centerNote(model.text("服务器上没有正在运行的 tmux 会话", "No tmux sessions are running on the server"), id: "launch-tmux-empty", action: model.text("刷新", "Refresh")) { loadTmux() } }
                    else { tmuxList(tmuxSessions) }
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                if tmuxBusy && tmuxSessions != nil { ProgressView().progressViewStyle(.linear).tint(Palette.accent) }
            }.frame(maxHeight: .infinity)
        }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 16)
        Button {
            guard attachReady, let name = tmuxSelection else { return }
            model.attachExisting(host, name: name, mosh: moshExplicit ? mosh : nil)
        } label: {
            Text(tmuxSelection.map { model.text("打开 tmux 会话 \($0)", "Open tmux session \($0)") } ?? model.text("选择一个 tmux 会话", "Pick a tmux session")).lineLimit(1)
                .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).frame(minHeight: 48)
                .foregroundStyle(attachReady ? Palette.onAccent : Palette.foreground.opacity(0.38))
                .background(attachReady ? Palette.accent : Palette.foreground.opacity(0.12), in: Capsule())
        }.buttonStyle(.plain).disabled(!attachReady).padding(.horizontal, 16).padding(.vertical, 12).accessibilityIdentifier("launch-attach")
    }
    private func tmuxList(_ sessions: [TmuxSessionInfo]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sessions) { session in
                    let selected = session.name == tmuxSelection
                    let open = model.records.contains { $0.hostID == host.id && $0.mode == .tmux && $0.remoteName == session.name }
                    Button { tmuxSelection = session.name } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "rectangle.on.rectangle").font(.system(size: 18)).foregroundStyle(Palette.accent).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(session.name).font(.body.weight(.medium)).lineLimit(1)
                                    if open { Badge(text: model.text("已打开", "Open")) }
                                }
                                Text(tmuxDetail(session, open: open)).font(.caption).foregroundStyle(session.attachable ? Palette.secondary : Palette.danger).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if selected { Image(systemName: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accent) }
                        }.padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 52).contentShape(Rectangle())
                            .background(selected ? Palette.accent.opacity(0.1) : Color.clear)
                    }.buttonStyle(.plain).disabled(!session.attachable).opacity(session.attachable ? 1 : 0.5)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.outline).frame(height: 0.5).padding(.leading, 50) }
                        .accessibilityIdentifier("launch-tmux-\(session.name)")
                }
            }
        }.accessibilityIdentifier("launch-tmux-sessions")
    }
    /// "3 个窗口 · 2 个客户端已连接 · ~/work · 5分钟前"
    private func tmuxDetail(_ session: TmuxSessionInfo, open: Bool) -> String {
        guard session.attachable else { return model.text("名称含有特殊字符，暂不支持打开", "Its name has special characters, so it can't be opened") }
        var parts = [model.text("\(session.windows) 个窗口", session.windows == 1 ? "1 window" : "\(session.windows) windows")]
        if session.attached > 0 { parts.append(model.text("\(session.attached) 个客户端已连接", session.attached == 1 ? "1 client attached" : "\(session.attached) clients attached")) }
        if !session.directory.isEmpty {
            if let homeDirectory, homeDirectory != "/", session.directory == homeDirectory || session.directory.hasPrefix(homeDirectory + "/") { parts.append("~" + session.directory.dropFirst(homeDirectory.count)) }
            else { parts.append(session.directory) }
        }
        if let activity = session.activity { parts.append(ago(activity)) }
        return parts.joined(separator: " · ")
    }
    /// How long ago, as the session list says it on Android: "刚刚", "3分钟前".
    private func ago(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return model.text("刚刚", "now") }
        if seconds < 3600 { return model.text("\(seconds / 60)分钟前", "\(seconds / 60)m ago") }
        if seconds < 86400 { return model.text("\(seconds / 3600)小时前", "\(seconds / 3600)h ago") }
        return model.text("\(seconds / 86400)天前", "\(seconds / 86400)d ago")
    }
    private func loadTmux() {
        tmuxBusy = true; tmuxError = nil
        Task {
            defer { tmuxBusy = false }
            do {
                let ssh = try await model.connection(for: host.id)
                let result = try await performInBackground { try ssh.exec(RemoteCommands.tmuxSessions, timeout: 10) }
                if result.status == 127 { throw RoamError.invalid(model.text("服务器未安装 tmux", "tmux is not installed on the server")) }
                guard result.status == 0 else { throw RoamError.invalid(model.text("无法读取 tmux 会话", "Cannot list tmux sessions")) }
                let sessions = TmuxSessionInfo.parse(String(decoding: result.output, as: UTF8.self))
                tmuxSessions = sessions
                if let selection = tmuxSelection, !sessions.contains(where: { $0.name == selection && $0.attachable }) { tmuxSelection = nil }
                if tmuxSelection == nil { tmuxSelection = sessions.first(where: \.attachable)?.name }
            } catch { tmuxError = error.localizedDescription }
        }
    }
    private var yolo: Bool { forAgent && agentMode == .yolo }
    @State private var filtering = false
    /// Tappable crumbs (`~ › work › app`); the arrow steps up past home, the magnifier filters long lists.
    private var pathBar: some View {
        HStack(spacing: 0) {
            Button { if let parent { navigate(parent) } } label: { AppIcon("ic_arrow_up", size: 20).frame(width: 40, height: 40) }
                .disabled(parent == nil).foregroundStyle(Palette.foreground.opacity(parent == nil ? 0.38 : 1))
                .accessibilityLabel(model.text("上一级", "Up one level")).accessibilityIdentifier("launch-parent")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                            let last = index == segments.count - 1
                            if index > 0 { AppIcon("ic_chevron_right", size: 14).foregroundStyle(Palette.adaptive(0x827A70, 0x9A9890)) }
                            Button { if !last { navigate(segment.path) } } label: {
                                Text(segment.name).font(last ? .subheadline.weight(.semibold) : .subheadline).foregroundStyle(last ? Palette.foreground : Palette.accent)
                                    .lineLimit(1).fixedSize().padding(.horizontal, 6).padding(.vertical, 10)
                            }.buttonStyle(.plain).id(index).accessibilityIdentifier("launch-crumb-\(index)")
                        }
                    }
                }.onChange(of: directory) { _ in withAnimation { proxy.scrollTo(segments.count - 1, anchor: .trailing) } }
            }.accessibilityIdentifier("launch-path")
            if entries.filter(\.isDirectory).count > 8 {
                Button { filtering = true } label: { AppIcon("ic_search", size: 20).foregroundStyle(Palette.secondary).frame(width: 40, height: 40) }
                    .accessibilityLabel(model.text("筛选当前目录", "Filter this folder")).accessibilityIdentifier("launch-filter-toggle")
            }
        }.padding(.horizontal, 4).frame(minHeight: 48)
    }
    @FocusState private var filterFocused: Bool
    private var filterBar: some View {
        HStack(spacing: 0) {
            Button { filtering = false; filter = "" } label: { AppIcon("ic_chevron_left", size: 20).frame(width: 40, height: 40) }
                .accessibilityLabel(model.text("关闭筛选", "Close filter")).accessibilityIdentifier("launch-filter-close")
            TextField(model.text("筛选当前目录", "Filter this folder"), text: $filter).focused($filterFocused).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.go).onSubmit { if let first = folders.first { navigate(first.path) } }.padding(.horizontal, 6).accessibilityIdentifier("launch-filter")
            if !filter.isEmpty { Button { filter = "" } label: { AppIcon("ic_clear", size: 18).foregroundStyle(Palette.secondary).frame(width: 40, height: 40) } }
        }.padding(.horizontal, 4).frame(minHeight: 48).onAppear { filterFocused = true }
    }
    private var folderList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if folders.isEmpty {
                    Text(entries.contains(where: \.isDirectory) ? model.text("没有匹配的文件夹", "No matching folders") : model.text("这里没有子文件夹", "No subfolders here"))
                        .font(.subheadline).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
                ForEach(folders) { entry in
                    Button { navigate(entry.path) } label: {
                        HStack(spacing: 12) {
                            RemoteFileIcon(name: entry.name, directory: true, size: 22)
                            Text(entry.name).font(.body).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            AppIcon("ic_chevron_right", size: 18).foregroundStyle(Palette.secondary)
                        }.padding(.horizontal, 16).padding(.vertical, 6).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(busy)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.outline).frame(height: 0.5).padding(.leading, 50) }
                        .accessibilityIdentifier("launch-folder-\(entry.name)")
                }
            }.opacity(busy ? 0.5 : 1)
        }.accessibilityIdentifier("launch-folders")
    }
    private func centerNote(_ message: String, id: String = "launch-note", action: String, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(message).font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).accessibilityIdentifier(id)
            Button(action, action: perform).buttonStyle(TextActionStyle()).accessibilityIdentifier("launch-note-action")
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func recentChip(_ path: String) -> some View {
        let selected = StartDirectory.normalize(path) == directory
        let name = StartDirectory.isHome(path) ? model.text("主目录", "home") : (path.split(separator: "/").last.map(String.init) ?? "/")
        return HStack(spacing: 8) {
            AppIcon("ic_history", size: 16)
            Text(name).font(.subheadline.weight(.medium)).lineLimit(1)
            Button { recent.removeAll { $0 == path }; persistRecent() } label: { AppIcon("ic_clear", size: 16) }.buttonStyle(.plain)
                .accessibilityLabel(model.text("移除 \(path)", "Remove \(path)"))
        }.padding(.horizontal, 8).frame(height: 32).foregroundStyle(selected ? Palette.adaptive(0x3D332D, 0xECE2D8) : Palette.secondary)
            .background(selected ? Palette.adaptive(0xECE4DB, 0x47413B) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay { if !selected { RoundedRectangle(cornerRadius: 8).stroke(Palette.outline, lineWidth: 1) } }
            .contentShape(Rectangle()).onTapGesture { navigate(path) }
    }
    /// Agent and permission as two pickers on one line; YOLO is red, and its "!" says what it allows.
    private var agentChooser: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("", selection: $agent) {
                    ForEach(CodingAgent.allCases) { option in Text(option.shortLabel + "  ·  " + option.command).tag(option) }
                }
            } label: { pickerField { AgentBadge(agent: agent, size: 20); Text(agent.shortLabel).font(.subheadline.weight(.medium)).lineLimit(1) } }
                .accessibilityIdentifier("launch-agent")
            Menu {
                Picker("", selection: $agentMode) {
                    ForEach(AgentMode.allCases) { option in Text(modeLabel(option) + " — " + modeHint(option)).tag(option) }
                }
            } label: {
                pickerField(border: yolo ? Palette.danger : nil) {
                    Text(modeLabel(agentMode)).font(.subheadline.weight(.medium)).foregroundStyle(yolo ? Palette.danger : Palette.foreground).lineLimit(1)
                    if yolo { AppIcon("ic_alert", size: 18).foregroundStyle(Palette.danger).accessibilityLabel(modeHint(.yolo)).accessibilityIdentifier("launch-yolo-warning") }
                }
            }.accessibilityIdentifier("launch-agent-mode")
        }.padding(.horizontal, 16).padding(.top, 12)
    }
    private func pickerField<Content: View>(border: Color? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content(); Spacer(minLength: 0); AppIcon("ic_expand_down", size: 18).foregroundStyle(Palette.secondary) }
            .padding(.leading, 12).padding(.trailing, 6).frame(minHeight: 44).foregroundStyle(Palette.foreground)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(border ?? Palette.outline, lineWidth: border == nil ? 0.5 : 1) }
    }
    private func modeLabel(_ mode: AgentMode) -> String {
        switch mode {
        case .readOnly: return agent == .claude ? model.text("计划", "Plan") : model.text("只读", "Read only")
        case .standard: return model.text("普通", "Standard")
        case .yolo: return "YOLO"
        }
    }
    private func modeHint(_ mode: AgentMode) -> String {
        switch mode {
        case .yolo: return model.text("跳过所有确认，直接执行", "Skip all confirmations and execute directly")
        case .standard: return model.text("改文件或运行命令前先问你", "Ask before editing files or running commands")
        case .readOnly:
            switch agent {
            case .claude: return model.text("先分析并制定计划，批准后开始修改", "Analyze and plan first; make changes after approval")
            case .codex: return model.text("以只读沙箱启动，可在 Agent 中调整权限", "Start in a read-only sandbox; permissions can be adjusted in the agent")
            case .grok: return model.text("只读沙箱；状态与临时目录仍可写", "Read-only sandbox; state and temporary directories remain writable")
            }
        }
    }
    #if DEBUG
    /// UI tests only: Android has no per-launch mode, mosh or typed path, but the suite needs them deterministically.
    private var testControls: some View {
        VStack(spacing: 6) {
            Picker("", selection: Binding(get: { sessionMode }, set: { sessionMode = $0; sessionModeExplicit = true })) { Text("tmux").tag(SessionMode.tmux); Text("SSH").tag(SessionMode.shell) }.pickerStyle(.segmented).accessibilityIdentifier("launch-mode")
            HStack {
                TextField("", text: $pathDraft).font(.caption.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { navigate(pathDraft) }.accessibilityIdentifier("launch-directory")
                Toggle("mosh", isOn: Binding(get: { mosh }, set: { mosh = $0; moshExplicit = true })).font(.caption).fixedSize().accessibilityIdentifier("launch-mosh")
            }
            if forAgent {
                Text(AgentLaunch(agent: agent, directory: directory, mode: agentMode).agentCommand).font(.caption2.monospaced()).accessibilityIdentifier("launch-command-preview")
                Text(modeHint(agentMode)).font(.caption2).accessibilityIdentifier("launch-permission-hint")
            }
        }.padding(.horizontal, 16).padding(.top, 8).opacity(0.6)
    }
    #endif
    private func navigate(_ path: String) {
        loadTask?.cancel(); loadCancellation?.cancel(); loadRevision += 1
        let revision = loadRevision, cancellation = TransferCancellation()
        loadCancellation = cancellation
        pathDraft = path; busy = false; error = nil
        guard StartDirectory.isSupported(path) else { error = model.text("文件夹路径含有不支持的控制字符", "The folder path contains unsupported control characters"); return }
        let normalized = StartDirectory.normalize(path)
        directory = normalized; pathDraft = normalized; busy = true
        loadTask = Task { await load(normalized, revision: revision, cancellation: cancellation) }
    }
    private func load(_ path: String, revision: Int, cancellation: TransferCancellation) async {
        defer { if revision == loadRevision { busy = false } }
        do {
            let ssh = try await model.connection(for: host.id)
            try Task.checkCancellation()
            let script = try RemoteFolders.script(path)
            let result = try await performInBackground {
                try ssh.exec("/bin/sh -s", input: Data(script.utf8), cancellation: cancellation)
            }
            try Task.checkCancellation()
            guard revision == loadRevision else { return }
            guard result.status == 0, let folders = RemoteFolders.parse(String(decoding: result.output, as: UTF8.self)) else { throw RoamError.invalid(model.text("无法读取文件夹，请检查路径与访问权限", "Cannot read this folder. Check its path and access permissions.")) }
            homeDirectory = folders.home
            directory = StartDirectory.normalize(folders.display)
            pathDraft = directory; entries = folders.directory.entries; filter = ""
        } catch { if !Task.isCancelled, revision == loadRevision { self.error = error.localizedDescription } }
    }
    private func persistRecent() { recent = StartDirectory.sanitizeRecent(recent); UserDefaults.standard.set(recent, forKey: "recentFolders-\(host.id)") }
}
