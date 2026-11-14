import SwiftUI
import RoamttyCore
import RoamttyTransport

/// Reading the host's folders, and what the agent's permission modes are called.
extension LaunchScreen {
    func navigate(_ path: String) {
        loadTask?.cancel(); loadCancellation?.cancel(); loadRevision += 1
        let revision = loadRevision, cancellation = TransferCancellation()
        loadCancellation = cancellation
        pathDraft = path; busy = false; error = nil
        guard StartDirectory.isSupported(path) else { error = model.text("文件夹路径含有不支持的控制字符", "The folder path contains unsupported control characters"); return }
        let normalized = StartDirectory.normalize(path)
        directory = normalized; pathDraft = normalized; busy = true
        loadTask = Task { await load(normalized, revision: revision, cancellation: cancellation) }
    }
    func load(_ path: String, revision: Int, cancellation: TransferCancellation) async {
        defer { if revision == loadRevision { busy = false } }
        do {
            let ssh = try await model.pool.connection(for: host.id)
            try Task.checkCancellation()
            let script = try RemoteFolders.script(path)
            let result = try await ssh.runScript(script, cancellation: cancellation)
            try Task.checkCancellation()
            guard revision == loadRevision else { return }
            guard result.status == 0, let folders = RemoteFolders.parse(result.text) else {
                throw RoamError.invalid(model.text("无法读取文件夹，请检查路径与访问权限", "Cannot read this folder. Check its path and access permissions."))
            }
            homeDirectory = folders.home
            directory = StartDirectory.normalize(folders.display)
            pathDraft = directory; entries = folders.directory.entries; filter = ""
        } catch { if !Task.isCancelled, revision == loadRevision { self.error = error.localizedDescription } }
    }
    func persistRecent() { recent = LaunchPreferences.setRecentFolders(recent, for: host.id) }

    func modeLabel(_ mode: AgentMode) -> String {
        switch mode {
        case .readOnly: return agent == .claude ? model.text("计划", "Plan") : model.text("只读", "Read only")
        case .standard: return model.text("普通", "Standard")
        case .yolo: return "YOLO"
        }
    }
    func modeHint(_ mode: AgentMode) -> String {
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
}
