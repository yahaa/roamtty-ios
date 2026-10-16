import SwiftUI
import UniformTypeIdentifiers
import RoamttyCore

struct SettingsScreen: View {
    private enum ImportKind { case font, downloadFolder }
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var fonts = FontCatalog.shared
    @State private var importKind = ImportKind.font
    @State private var showImporter = false
    @State private var fontError: String?
    @State private var downloadFolderError: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Panel(title: model.text("外观", "Appearance")) {
                        themeRow(.system, model.text("跟随系统", "System")).panelDivider()
                        themeRow(.dark, model.text("深色", "Dark")).panelDivider()
                        themeRow(.light, model.text("浅色", "Light"))
                    }
                    Panel(title: model.text("语言", "Language")) {
                        checkRow("简体中文", selected: !model.english, id: "language-zh") { model.settings.language = "zh-Hans"; model.saveSettings() }.panelDivider()
                        checkRow("English", selected: model.english, id: "language-en") { model.settings.language = "en"; model.saveSettings() }
                    }
                    Panel(title: model.text("终端", "Terminal")) {
                        Picker(model.text("字体", "Font"), selection: $model.settings.font) {
                            Text(model.text("系统等宽", "System monospace")).tag(TerminalFontSelection.system).accessibilityIdentifier("settings-font-system")
                            ForEach(TerminalFontSelection.bundled, id: \.self) { name in Text(name.replacingOccurrences(of: "-Regular", with: "")).tag(name) }
                            if let custom = fonts.custom { Text(custom.displayName).tag(TerminalFontSelection.custom).accessibilityIdentifier("settings-font-custom") }
                        }.padding(16).panelDivider().accessibilityIdentifier("settings-font").accessibilityValue(fonts.valueLabel(model.settings.font, english: model.english))
                        Button { fontError = nil; importKind = .font; showImporter = true } label: { InfoRow(title: model.text("导入字体", "Import font"), value: "TTF / OTF · ≤16 MiB", icon: "textformat") }.panelDivider().accessibilityIdentifier("settings-font-import")
                        if fonts.custom != nil {
                            Button(model.text("清除自定义字体", "Clear custom font"), role: .destructive) {
                                do { model.settings.font = try fonts.clear(selection: model.settings.font); fontError = nil; model.saveSettings() }
                                catch { fontError = error.localizedDescription }
                            }.padding(16).panelDivider().accessibilityIdentifier("settings-font-clear-custom")
                        }
                        if let fontError { Text(fontError).font(.footnote).foregroundStyle(Palette.danger).padding(16).accessibilityIdentifier("settings-font-error") }
                        VStack(spacing: 10) {
                            HStack { Text(model.text("字号", "Font size")); Spacer(); Text("\(Int(model.settings.fontSize)) pt").foregroundStyle(Palette.secondary).accessibilityIdentifier("settings-font-size-value") }
                            Slider(value: $model.settings.fontSize, in: 8...28, step: 1).accessibilityLabel(model.text("字号", "Font size")).accessibilityIdentifier("settings-font-size")
                            Text("❯ ssh developer@roamtty\n你好，世界  echo 'Hello, world'\nλ → 0123456789 {} []").font(Font(fonts.font(selection: model.settings.font, size: model.settings.fontSize))).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Palette.background, in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("settings-font-preview").accessibilityValue(fonts.font(selection: model.settings.font, size: model.settings.fontSize).fontName)
                        }.padding(16).panelDivider()
                        Toggle(model.text("固定工具箱", "Keep toolbox open"), isOn: $model.settings.toolboxPinned).padding(16).accessibilityIdentifier("settings-toolbox-pinned")
                    }
                    Panel(title: model.text("文件", "Files")) {
                        Toggle(model.text("显示隐藏文件", "Show hidden files"), isOn: $model.settings.showHiddenFiles).padding(16).panelDivider().accessibilityIdentifier("settings-hidden-files")
                        Button { downloadFolderError = nil; importKind = .downloadFolder; showImporter = true } label: { InfoRow(title: model.text("下载目录", "Download folder"), value: model.settings.downloadBookmark == nil ? "Roamtty/Downloads" : model.text("自定义目录", "Custom folder"), icon: "folder") }.panelDivider().accessibilityIdentifier("settings-download-folder")
                        if let downloadFolderError { Text(downloadFolderError).font(.footnote).foregroundStyle(Palette.danger).padding(16).accessibilityIdentifier("settings-download-folder-error") }
                        if model.settings.downloadBookmark != nil { Button(model.text("恢复默认下载目录", "Use default download folder")) { model.settings.downloadBookmark = nil; downloadFolderError = nil; model.saveSettings() }.padding(16) }
                    }
                }.padding(16).frame(maxWidth: 720)
            }.accessibilityIdentifier("settings-scroll").frame(maxWidth: .infinity).pageBackground().navigationTitle(model.text("设置", "Settings"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(model.text("完成", "Done")) { dismiss() }.accessibilityIdentifier("settings-done") } }
        }
        .onChange(of: model.settings) { _ in model.saveSettings() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importKind == .downloadFolder ? [.folder] : [UTType(filenameExtension: "ttf") ?? .data, UTType(filenameExtension: "otf") ?? .data]) { result in
            // Keep the purpose separate from isPresented: SwiftUI clears that
            // binding before delivering the selected document's completion.
            do {
                let url = try result.get()
                switch importKind {
                case .font:
                    model.settings.font = try fonts.install(url); fontError = nil
                case .downloadFolder:
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    model.settings.downloadBookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                    downloadFolderError = nil
                }
                model.saveSettings()
            } catch let error as CocoaError where error.code == .userCancelled {
                // Dismissing the native picker leaves the existing selection intact.
            } catch {
                if importKind == .font { fontError = error.localizedDescription }
                else { downloadFolderError = error.localizedDescription }
            }
        }
    }
    private func themeRow(_ theme: AppTheme, _ title: String) -> some View {
        checkRow(title, selected: model.settings.theme == theme, id: "theme-\(theme.rawValue)") { model.settings.theme = theme; model.saveSettings() }
    }
    /// Android `CheckRow`: a single-choice row with a trailing check on the selection.
    private func checkRow(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(Palette.foreground)
                Spacer()
                AppIcon("ic_check", size: 20).foregroundStyle(Palette.accent).opacity(selected ? 1 : 0)
            }.font(.body).padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
struct HelpScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Panel(title: model.text("连接主机", "Connect a host")) { Text(model.text("在“主机”页点“+”添加主机，可用密码、交互式认证或 Ed25519/RSA 私钥（支持加密私钥）。主机卡片显示系统图标、在线状态与 DNS + TCP 建连延时（不含 SSH 启动等待）。首次连接先核对 SHA-256 指纹再信任。", "Tap + on the Hosts tab to add a host. Sign in with a password, keyboard-interactive login or an Ed25519/RSA private key (encrypted keys work). Host cards show the system icon, online status and DNS + TCP connection latency (excluding SSH startup). Check the SHA-256 fingerprint before trusting a host the first time.")).padding(16) }
                    Panel(title: model.text("会话与 AI Agent", "Sessions and AI agents")) { Text(model.text("“会话”页列出全部会话（每台主机最多 8 个），按 Agent 状态分组：待确认、运行中、已完成和终端，并显示 Agent 的任务、正在运行的命令和最后的回复。待确认时可直接“允许”，空闲时可“追问”。点“+”先选 AI Agent 或终端，再选主机（也可当场填写新主机），最后选择工作目录。断线的 tmux 会话保留卡片并自动重连；长按卡片可“关闭”（结束远端 tmux 会话及其中任务）或在主机离线时“强制删除”。iOS 会在应用进入后台后暂停网络活动。", "The Sessions tab lists every session (up to 8 per host), grouped by what the agent is doing: needs you, running, done and terminals, with the agent's task, the command it runs and its last reply. Allow a request or reply to an idle agent right from the row. + picks an AI agent or a terminal, then the host (or a new one filled in on the spot), then the working folder. A dropped tmux session keeps its card and reconnects by itself; long-press a card to Close it (ending the remote tmux session and its tasks), or Force delete it while its host is offline. iOS suspends network activity while the app is in the background.")).padding(16) }
                    Panel(title: model.text("终端手势", "Terminal gestures")) { Text(model.text("点击光标所在行及上下两行可打开键盘；双击发送 Tab，同时小精灵上方出现 ↑ 键、下方出现 ↓ 键、左边出现 ← 键用来选择补全项；三击粘贴。点击终端里的链接会在浏览器或对应 App 中打开。拖动查看回滚内容，长按选择文字，双指缩放调整字体。键盘弹出时，光标行末多出收起键盘键，点它或点光标附近以外的区域即可收起；按回车后 15 秒内没有输入，键盘也会自动收起。停止输入后，光标行末显示回车键，其余时间显示 Esc；输入以 / 开头的斜杠命令时，小精灵旁也会出现 ↑/↓/← 键。点小幽灵打开工具箱，长按并滑动选择快捷键；会话菜单可返回主机详情、关闭或重启当前会话、切换会话。", "Tap within two rows of the cursor to open the keyboard. Double-tap sends Tab and brings ↑ above the pet, ↓ below it and ← to its left for picking a completion; triple-tap pastes. Tap a link in the terminal to open it in the browser or its app. Drag to scroll back, hold to select text, and pinch to adjust font size. While the keyboard is up, a hide-keyboard key sits at the end of the cursor row; tap it, or tap away from the cursor, to put the keyboard away. After Enter it also hides by itself if you type nothing for 15 seconds. Enter appears at the cursor row after typing pauses; otherwise Esc is shown. On a line starting with / the ↑/↓/← keys also appear around the pet. Tap the ghost for tools, or hold and drag to a shortcut; the session menu goes back to the host, closes or restarts the session, or switches sessions.")).padding(16) }
                    Panel(title: model.text("传输文件", "Transfer files")) { Text(model.text("在文件页中选择上传或下载。上传文件或文件夹来自 iOS 文件；下载保存在 Roamtty/Downloads，或设置中选择的目录。传输可在传输面板查看进度和取消。", "Upload files or folders from iOS Files. Downloads go to Roamtty/Downloads or the folder chosen in Settings. View progress and cancel transfers in the transfer panel.")).padding(16) }
                }.padding(16)
            }.accessibilityIdentifier("guide-scroll").pageBackground().navigationTitle(model.text("使用指南", "Guide")).toolbar { ToolbarItem(placement: .confirmationAction) { Button(model.text("完成", "Done")) { dismiss() }.accessibilityIdentifier("guide-done") } }
        }
    }
}
struct AboutScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    GhostMark().frame(width: 88, height: 88).padding(.top, 24)
                    Text("Roamtty").font(.largeTitle.weight(.semibold)); Text("1.0.0 · SSH · tmux · mosh").foregroundStyle(Palette.secondary)
                    Panel(title: model.text("隐私", "Privacy")) { Text(model.text("主机信息和设置存储在设备上。保存的密码和私钥使用此设备的 Keychain。私钥口令仅保存在内存。连接直接发送至你选择的服务器；应用没有遥测或广告。启动 AI Agent 时，应用会在服务器的 ~/.roamtty 写入状态钩子脚本、Claude 设置和 Codex/Grok 启动器，在 Codex 的 config.toml 追加钩子信任记录、写入 Grok 的钩子文件；Agent 的状态（包括最近一条提示的前 200 个字符和回复开头）保存为 tmux 会话选项供应用读取。", "Host information and settings stay on your device. Saved passwords and private keys use device-only Keychain storage. Key passphrases remain in memory. Connections go directly to your chosen servers. The app contains no telemetry or advertising. Starting an AI agent writes a status hook script, Claude settings and Codex/Grok launchers to ~/.roamtty on the server, appends hook trust entries to Codex's config.toml and writes Grok's hooks file; the agent's state (including the first 200 characters of the latest prompt and the start of its reply) is kept as tmux session options that the app reads.")).padding(16) }
                    DiagnosticsPanel()
                    Panel(title: model.text("开源组件", "Open source")) { Text("SwiftTerm · MIT\nlibssh2 · BSD\nOpenSSL · Apache 2.0\nzlib · zlib license\nRoamtty · Apache 2.0").padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(16)
            }.accessibilityIdentifier("about-scroll").pageBackground().navigationTitle(model.text("关于", "About")).toolbar { ToolbarItem(placement: .confirmationAction) { Button(model.text("完成", "Done")) { dismiss() }.accessibilityIdentifier("about-done") } }
        }
    }
}

/// The crash, hang and exit reports iOS gave the app, and its event log, for the user to send when asked.
private struct DiagnosticsPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var files: [URL] = []
    var body: some View {
        Panel(title: model.text("诊断报告", "Diagnostics")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.text("iOS 报告的崩溃、卡顿和退出记录，以及应用的内存日志，仅保存在本机。应用异常退出后，可以分享给开发者帮助定位。",
                                "Crash, hang and exit reports from iOS, and the app's memory log, kept on this device only. After an unexpected exit, share them with the developer to help find the cause."))
                    .font(.footnote).foregroundStyle(Palette.secondary)
                if files.isEmpty {
                    Text(model.text("暂无记录", "Nothing recorded yet")).font(.subheadline)
                } else {
                    ShareLink(items: files) { Label(model.text("分享 \(files.count) 个文件", "Share \(files.count) files"), systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("about-share-diagnostics")
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear { files = Diagnostics.shared.files }
    }
}
