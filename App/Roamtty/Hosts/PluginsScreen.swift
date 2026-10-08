import SwiftUI
import RoamttyCore
import RoamttyTransport

@MainActor struct PluginsScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let host: Host
    @State private var installed: Set<HostPlugin>?
    @State private var system: HostSystem = .UNKNOWN
    @State private var probed = false
    @State private var busy = false
    @State private var installing: HostPlugin?
    @State private var confirmInstall: HostPlugin?
    @State private var outcome: (plugin: HostPlugin, result: HostPluginInstaller.Result)?
    @State private var sudoPassword = ""
    @State private var log = PluginInstallLog()
    @State private var errorMessage: String?
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var cancellation = TransferCancellation()
    @State private var streaming = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Panel(title: host.name, footer: installHint) {
                        row("tmux", model.text("断开连接后远端任务继续运行，重连即可恢复。", "Keep remote tasks running and restore them after reconnecting."), .tmux).panelDivider()
                        row("mosh", model.text("切换网络后自动恢复。需放行 UDP 60000–61000。", "Recover across network changes. Requires UDP ports 60000–61000."), .mosh)
                    }
                    if busy {
                        ProgressView(installing.map { model.text("正在安装 \($0.rawValue)…", "Installing \($0.rawValue)…") } ?? model.text("正在检测插件…", "Checking plugins…"))
                            .accessibilityIdentifier("plugin-progress")
                    }
                    if probed && installed == nil && !busy {
                        Text(system == .WINDOWS
                             ? model.text("Windows 的 cmd 和 PowerShell 无法运行 tmux 与 mosh。请将 OpenSSH 默认 shell 改为 MSYS2 或 Cygwin 的 bash，或单独添加 WSL 的 SSH 主机。", "Windows cmd and PowerShell cannot run tmux or mosh. Use MSYS2 or Cygwin bash as the OpenSSH default shell, or add a separate WSL SSH host.")
                             : model.text("无法检测插件。目前支持 Linux、macOS、BSD，以及使用 MSYS2 或 Cygwin shell 的 Windows 主机。", "Plugins could not be detected. Supported hosts include Linux, macOS, BSD, and Windows using an MSYS2 or Cygwin shell."))
                            .font(.footnote).foregroundStyle(Palette.secondary)
                    }
                    if let outcome {
                        Text(resultMessage(outcome.plugin, outcome.result))
                            .foregroundStyle(outcome.result == .installed ? Palette.success : Palette.danger)
                            .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("plugin-result")
                        if outcome.result == .sudoPassword {
                            Panel(title: model.text("sudo 密码", "sudo password"), footer: model.text("仅用于本次安装，不会保存。", "Used only for this installation and never saved.")) {
                                HStack(spacing: 12) {
                                    SecureField(model.text("输入 sudo 密码", "Enter sudo password"), text: $sudoPassword)
                                        .textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
                                        .accessibilityIdentifier("plugin-sudo-password")
                                    Button(model.text("重试", "Retry")) { startInstall(outcome.plugin) }
                                        .disabled(busy || !validSudoPassword).accessibilityIdentifier("plugin-sudo-retry")
                                }.padding(16)
                            }
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(Palette.danger).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("plugin-error")
                    }
                    if !log.text.isEmpty {
                        Panel(title: model.text("安装输出", "Installation output")) {
                            Text(log.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(16).accessibilityIdentifier("plugin-log")
                        }
                    }
                    Button(model.text("重新检测", "Check again")) { startProbe() }
                        .buttonStyle(RoamButtonStyle()).disabled(busy).accessibilityIdentifier("host-plugins-retry")
                }.padding(16)
            }.pageBackground().navigationTitle(model.text("管理插件", "Manage plugins")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(model.text("完成", "Done")) { dismiss() }.accessibilityIdentifier("plugins-done") } }
        }
        .task { system = HostSystem.fromStored(host.system); startProbe() }
        .onDisappear { cancelOperation(); sudoPassword = "" }
        .overlay { AuthenticationOverlay() }
        .confirmationDialog(model.text("安装 \(confirmInstall?.rawValue ?? "")？", "Install \(confirmInstall?.rawValue ?? "")?"), isPresented: Binding(get: { confirmInstall != nil }, set: { if !$0 { confirmInstall = nil } }), titleVisibility: .visible) {
            Button(model.text("安装", "Install")) {
                if let plugin = confirmInstall { confirmInstall = nil; startInstall(plugin) }
            }
        }
    }

    private var validSudoPassword: Bool { !sudoPassword.isEmpty && !sudoPassword.contains("\n") && !sudoPassword.contains("\r") && !sudoPassword.contains("\0") }
    private var installHint: String {
        let hint: String
        switch system {
        case .MACOS: hint = model.text("通过 Homebrew 安装，无需 sudo；也支持 MacPorts。", "Install through Homebrew without sudo, or use MacPorts.")
        case .WINDOWS: hint = model.text("通过 MSYS2 的 pacman 或 Cygwin 的 apt-cyg 安装，无需管理员权限。", "Install through MSYS2 pacman or Cygwin apt-cyg without administrator access.")
        default: hint = model.text("使用主机的包管理器安装，需要 root 或 sudo 权限；也支持 Homebrew。", "Use the host's package manager with root or sudo access, or Homebrew.")
        }
        return hint + " " + model.text("新会话优先使用 mosh；装有 tmux 时在 tmux 中运行。", "New sessions prefer mosh and run inside tmux when it is installed.")
    }

    private func row(_ name: String, _ description: String, _ plugin: HostPlugin) -> some View {
        HStack(spacing: 12) {
            Image(systemName: plugin == .tmux ? "rectangle.on.rectangle" : "network").foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 4) { Text(name).font(.headline); Text(description).font(.footnote).foregroundStyle(Palette.secondary) }
            Spacer()
            if installed?.contains(plugin) == true {
                Label(model.text("已安装", "Installed"), systemImage: "checkmark").font(.caption).foregroundStyle(Palette.success)
                    .accessibilityIdentifier("plugin-installed-\(name)")
            } else {
                Button(model.text("安装", "Install")) { confirmInstall = plugin }
                    .disabled(busy || installed == nil).accessibilityIdentifier("plugin-install-\(name)")
            }
        }.padding(16)
    }

    private func resultMessage(_ plugin: HostPlugin, _ result: HostPluginInstaller.Result) -> String {
        switch result {
        case .installed: return model.text("\(plugin.rawValue) 安装完成。", "\(plugin.rawValue) was installed.")
        case .sudoPassword: return model.text("需要 sudo 密码，或密码不正确。", "A sudo password is required, or the password was incorrect.")
        case .noPrivilege: return model.text("当前用户没有 root 或 sudo 权限，请联系管理员安装。", "This account has no root or sudo access. Ask an administrator to install the plugin.")
        case .noPackageManager:
            if system == .MACOS { return model.text("未找到 Homebrew 或 MacPorts。请先在 Mac 上安装 Homebrew（brew.sh），再重试。", "Homebrew and MacPorts were not found. Install Homebrew on the Mac (brew.sh), then retry.") }
            if system == .WINDOWS { return model.text("未找到 pacman 或 apt-cyg。Git Bash 无法安装软件，请改用 MSYS2，或为 Cygwin 安装 apt-cyg。", "Neither pacman nor apt-cyg was found. Use MSYS2, or install apt-cyg in Cygwin; Git Bash cannot install these packages.") }
            return model.text("未找到支持的包管理器，请手动安装。", "No supported package manager was found. Install the plugin manually.")
        case .failed: return model.text("\(plugin.rawValue) 安装失败，请查看下方输出。", "\(plugin.rawValue) installation failed. See the output below.")
        }
    }

    private func cancelOperation() {
        operationID = UUID(); cancellation.cancel(); operation?.cancel(); operation = nil; streaming = false; busy = false; installing = nil
    }

    private func startProbe() {
        guard !busy else { return }
        cancelOperation()
        let id = operationID, token = TransferCancellation()
        cancellation = token; busy = true; errorMessage = nil
        operation = Task {
            defer { finishOperation(id) }
            do { try await probe(id, token) }
            catch { if operationID == id && !token.isCancelled { errorMessage = error.localizedDescription } }
        }
    }

    private func startInstall(_ plugin: HostPlugin) {
        guard !busy else { return }
        cancelOperation()
        let id = operationID, token = TransferCancellation(), enteredPassword = sudoPassword
        cancellation = token; busy = true; installing = plugin; outcome = nil; errorMessage = nil; log = PluginInstallLog(); sudoPassword = ""
        operation = Task {
            defer { finishOperation(id) }
            do {
                let ssh = try await model.connection(for: host.id)
                try checkOperation(id, token)
                let password = enteredPassword.isEmpty ? model.loginPassword(for: host.id) : enteredPassword
                streaming = true
                let result = try await performInBackground {
                    var input = Data(HostPluginInstaller.script(plugin: plugin, sudoPassword: password).utf8)
                    defer { input.resetBytes(in: 0..<input.count) }
                    return try ssh.exec("/bin/sh -s", input: input, timeout: 15 * 60, cancellation: token) { data in
                        DispatchQueue.main.async {
                            guard operationID == id && streaming && !token.isCancelled else { return }
                            log.append(data)
                        }
                    }
                }
                try checkOperation(id, token)
                streaming = false
                var completeLog = PluginInstallLog(); completeLog.append(result.output); completeLog.finish(); log = completeLog
                outcome = (plugin, HostPluginInstaller.classify(exitStatus: Int(result.status), output: String(decoding: result.output, as: UTF8.self)))
                try await probe(id, token)
            } catch {
                if operationID == id && !token.isCancelled {
                    streaming = false; log.finish(); errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func checkOperation(_ id: UUID, _ token: TransferCancellation) throws {
        try Task.checkCancellation()
        guard operationID == id && !token.isCancelled else { throw RoamError.cancelled }
    }

    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        busy = false; installing = nil; streaming = false; operation = nil
    }

    private func probe(_ id: UUID, _ token: TransferCancellation) async throws {
        let ssh = try await model.connection(for: host.id)
        try checkOperation(id, token)
        let result = try await performInBackground { try ssh.exec(HostPluginProbe.command, input: Data(HostPluginProbe.script.utf8), cancellation: token) }
        try checkOperation(id, token)
        installed = HostPluginProbe.parse(String(decoding: result.output, as: UTF8.self)); probed = true
        let unix = try await performInBackground { try ssh.exec(HostSystemProbe.command, input: Data(HostSystemProbe.script.utf8), cancellation: token) }
        try checkOperation(id, token)
        var detected = HostSystemProbe.parse(unix: String(decoding: unix.output, as: UTF8.self))
        if detected == .UNKNOWN {
            let windows = try await performInBackground { try ssh.exec(HostSystemProbe.windowsCommand, input: Data(), cancellation: token) }
            try checkOperation(id, token)
            detected = HostSystemProbe.parse(unix: nil, windows: String(decoding: windows.output, as: UTF8.self))
        }
        system = detected == .UNKNOWN ? HostSystem.fromStored(host.system) : detected
        model.updateMetadata(host: host, plugins: installed?.map(\.rawValue), system: system.rawValue)
    }
}
