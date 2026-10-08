import SwiftUI
import RoamttyCore
import RoamttyTransport

struct LaunchScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let host: Host
    let forAgent: Bool
    var initialDirectory = "~"
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
    private var launchReady: Bool { !busy && error == nil && StartDirectory.isSupported(pathDraft) && StartDirectory.normalize(pathDraft) == directory }
    private var permissionHint: String {
        switch agentMode {
        case .yolo: return model.text("跳过所有确认，直接执行", "Skip all confirmations and execute directly")
        case .standard: return model.text("改文件或运行命令前先问你", "Ask before editing files or running commands")
        case .readOnly:
            switch agent {
            case .claude: return model.text("先分析并制定计划，批准后开始修改", "Analyze and plan first; make changes after approval")
            case .codex: return model.text("以只读沙箱启动，可在助手中调整权限", "Start in a read-only sandbox; permissions can be adjusted in the agent")
            case .grok: return model.text("只读沙箱；状态与临时目录仍可写", "Read-only sandbox; state and temporary directories remain writable")
            }
        }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if forAgent {
                    Panel(title: model.text("AI 助手", "AI agent")) {
                        Picker("Agent", selection: $agent) { Text("Claude Code").tag(CodingAgent.claude); Text("Codex").tag(CodingAgent.codex); Text("Grok").tag(CodingAgent.grok) }.pickerStyle(.segmented).padding(12).accessibilityIdentifier("launch-agent")
                        Picker(model.text("权限模式", "Permission mode"), selection: $agentMode) {
                            Text(agent == .claude ? model.text("计划", "Plan") : model.text("只读", "Read only")).tag(AgentMode.readOnly)
                            Text(model.text("标准", "Standard")).tag(AgentMode.standard)
                            Text("YOLO").tag(AgentMode.yolo)
                        }.pickerStyle(.segmented).padding([.horizontal, .bottom], 12).accessibilityIdentifier("launch-agent-mode")
                        if agentMode == .yolo { Label(permissionHint, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Palette.warning).padding([.horizontal, .bottom], 16).accessibilityIdentifier("launch-yolo-warning") }
                        else { Text(permissionHint).font(.footnote).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .bottom], 16).accessibilityIdentifier("launch-permission-hint") }
                        Text(AgentLaunch(agent: agent, directory: directory, mode: agentMode).agentCommand).font(.system(.caption, design: .monospaced)).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .bottom], 16).accessibilityIdentifier("launch-command-preview")
                    }
                } else {
                    Picker(model.text("会话模式", "Session mode"), selection: Binding(get: { sessionMode }, set: { sessionMode = $0; sessionModeExplicit = true })) { Text("tmux").tag(SessionMode.tmux); Text("SSH").tag(SessionMode.shell) }.pickerStyle(.segmented).accessibilityIdentifier("launch-mode")
                }
                HStack {
                    Button { navigate(parentRemotePath(directory == "~" ? homeDirectory ?? "/" : directory)) } label: { Image(systemName: "arrow.up").frame(width: 36, height: 36) }.disabled(directory == "/")
                    TextField(model.text("工作目录", "Working directory"), text: $pathDraft).font(.system(.subheadline, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit { navigate(pathDraft) }.accessibilityIdentifier("launch-directory")
                    Button { navigate(pathDraft) } label: { Image(systemName: "arrow.right.circle") }.accessibilityLabel(model.text("打开目录", "Open folder")).accessibilityIdentifier("launch-open-directory")
                }.padding(8).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                if !recent.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(recent, id: \.self) { path in Button(URL(fileURLWithPath: path).lastPathComponent) { navigate(path) }.buttonStyle(.bordered).contextMenu { Button(model.text("移除", "Remove"), role: .destructive) { recent.removeAll { $0 == path }; persistRecent() } } } } }
                }
                HStack { Image(systemName: "magnifyingglass"); TextField(model.text("筛选文件夹", "Filter folders"), text: $filter).textInputAutocapitalization(.never).autocorrectionDisabled() }.font(.subheadline).foregroundStyle(Palette.secondary)
                if busy { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error { VStack(spacing: 16) { Text(error).foregroundStyle(Palette.danger).accessibilityIdentifier("launch-error"); Button(model.text("重试", "Retry")) { navigate(pathDraft) }; Button(model.text("回到主目录", "Home folder")) { navigate("~") } }.frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries.filter { $0.isDirectory && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) }) { entry in
                                Button { navigate(entry.path) } label: { InfoRow(title: entry.name, icon: "folder").overlay(alignment: .trailing) { Image(systemName: "chevron.right").font(.caption).padding(16) } }.panelDivider()
                            }
                        }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                Toggle(model.text("优先使用 mosh", "Prefer mosh"), isOn: Binding(get: { mosh }, set: { mosh = $0; moshExplicit = true })).font(.subheadline).accessibilityIdentifier("launch-mosh")
                Button {
                    guard launchReady else { return }
                    let normalized = StartDirectory.normalize(directory)
                    recent = StartDirectory.remember(recent: recent, directory: normalized); persistRecent()
                    if forAgent { UserDefaults.standard.set(agent.rawValue, forKey: "launchAgent"); UserDefaults.standard.set(agentMode.rawValue, forKey: "launchAgentMode") }
                    let launch = forAgent ? AgentLaunch(agent: agent, directory: normalized, mode: agentMode) : nil
                    model.launch(host, mode: sessionMode, directory: normalized, agent: launch, mosh: moshExplicit ? mosh : nil)
                } label: { Label(forAgent ? model.text("启动助手", "Start agent") : model.text("打开终端", "Open terminal"), systemImage: forAgent ? "sparkles" : "terminal") }.buttonStyle(RoamButtonStyle(primary: true)).disabled(!launchReady).accessibilityIdentifier("launch-session")
            }.padding(16).pageBackground().navigationTitle(host.name).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(model.text("取消", "Cancel")) { dismiss() }.accessibilityIdentifier("launch-cancel") } }
        }.task {
            let currentHost = model.host(host.id) ?? host
            sessionMode = currentHost.newSessionMode; mosh = currentHost.plugins?.contains("mosh") == true
            recent = StartDirectory.sanitizeRecent(UserDefaults.standard.stringArray(forKey: "recentFolders-\(host.id)") ?? [])
            agent = CodingAgent.from(UserDefaults.standard.string(forKey: "launchAgent"))
            agentMode = UserDefaults.standard.string(forKey: "launchAgentMode").map(AgentMode.from) ?? .yolo
            navigate(initialDirectory)
        }.onChange(of: model.host(host.id)?.plugins) { plugins in
            if !moshExplicit { mosh = plugins?.contains("mosh") == true }
            if !sessionModeExplicit { sessionMode = (model.host(host.id) ?? host).newSessionMode }
        }
            .onDisappear { loadTask?.cancel(); loadCancellation?.cancel(); loadRevision += 1 }
    }
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
