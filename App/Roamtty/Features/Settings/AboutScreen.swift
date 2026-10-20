import SwiftUI

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
                    Panel(title: model.text("本机数据与支持", "Local data and support")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(model.text(
                                "为在重新打开应用后显示会话卡片，最近的 Agent 状态、提示词和回复摘要、工具及工作目录会保存在本机；移除会话时清除。应用还在本机保留有限的运行日志和 iOS 诊断报告，仅在你主动分享时发送给你选择的接收方。",
                                "To restore session cards after relaunch, the latest agent state, prompt and reply previews, tool and working directory are saved on this device and removed when you remove the session. The app also keeps limited local event logs and iOS diagnostic reports, shared only when you choose a recipient."))
                            Link(model.text("完整隐私政策", "Full privacy policy"), destination: URL(string: "https://roamtty.com/privacy/")!)
                                .accessibilityIdentifier("about-privacy-policy")
                            Link(model.text("联系支持", "Contact support"), destination: URL(string: "https://roamtty.com/support/")!)
                                .accessibilityIdentifier("about-support")
                        }.padding(16)
                    }
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
