import SwiftUI
import UniformTypeIdentifiers
import RoamttyCore

/// Android `HostEditor`: 连接信息, 远端系统, 认证方式 and 会话模式 as grouped sections with explanatory footers.
struct HostEditorScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let original: Host?
    /// Set when the form fills in a new host on the way to a new session: the agent it starts, or nil for a terminal.
    var forSession: CodingAgent?? = nil
    @State private var host: Host
    @State private var port = "22"
    @State private var password = ""
    @State private var passphrase = ""
    @State private var privateKey: Data?
    @State private var importKey = false
    @State private var validation: String?
    init(original: Host?, forSession: CodingAgent?? = nil) {
        self.original = original; self.forSession = forSession
        // A session started from here would otherwise ask for the password again right after saving.
        _host = State(initialValue: original ?? Host(savePassword: forSession != nil))
        _port = State(initialValue: String(original?.port ?? 22))
    }
    private var authFooter: String {
        switch host.auth {
        case .password: return model.text("密码仅在勾选后才会在本机加密保存。留空可在连接时输入。", "The password is saved on this device, encrypted, only when enabled. Leave it empty to enter it when connecting.")
        case .key: return model.text("支持 OpenSSH、PEM 私钥。文件会加密保存；私钥口令仅用于本次连接，不会保存。", "OpenSSH and PEM keys are supported. The file is stored encrypted; the passphrase is used for this connection only and never saved.")
        case .interactive: return model.text("连接时显示服务器的认证问题，支持一次性验证码和多轮交互。", "The server’s questions appear when connecting, including one-time codes and multi-step prompts.")
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if let validation { Text(validation).foregroundStyle(Palette.danger).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).accessibilityIdentifier("editor-error") }
                    Panel(title: model.text("连接信息", "Connection")) {
                        FormField(label: model.text("名称", "Name"), placeholder: model.text("例如：开发工作站", "e.g. Dev workstation"), text: $host.name, id: "host-name").panelDivider()
                        FormField(label: model.text("地址 / IP", "Address / IP"), placeholder: model.text("例如：dev.example.com", "e.g. dev.example.com"), text: $host.address, id: "host-address").keyboardType(.URL).panelDivider()
                        HStack(spacing: 0) {
                            FormField(label: model.text("用户名", "Username"), text: $host.username, id: "host-username")
                            Rectangle().fill(Palette.outline).frame(width: 0.5).padding(.vertical, 10)
                            FormField(label: model.text("端口", "Port"), text: Binding(get: { port }, set: { port = String($0.filter(\.isNumber).prefix(5)) }), id: "host-port")
                                .keyboardType(.numberPad).frame(width: 96)
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                    Panel(title: model.text("远端系统", "Remote system"), footer: model.text("首次连接成功后自动检测系统，并在之后每次连接时更新。", "The system is detected after the first successful connection and kept up to date afterwards.")) {
                        HStack(spacing: 12) {
                            HostSystemMark(system: host.system).frame(width: 32, height: 32)
                            Text(host.system.uppercased() == "UNKNOWN" ? model.text("自动检测", "Detect automatically") : systemName(host.system))
                        }.font(.body).padding(.horizontal, 16).frame(minHeight: 56)
                    }
                    Panel(title: model.text("认证方式", "Authentication"), footer: authFooter) {
                        Picker(model.text("认证方式", "Method"), selection: $host.auth) {
                            Text(model.text("密码", "Password")).tag(AuthMethod.password)
                            Text(model.text("私钥", "Private key")).tag(AuthMethod.key)
                            Text(model.text("交互式认证", "Interactive")).tag(AuthMethod.interactive)
                        }.pickerStyle(.segmented).padding(8).accessibilityIdentifier("host-auth-method")
                        if host.auth == .password {
                            Divider().overlay(Palette.outline).padding(.leading, 16)
                            Toggle(model.text("在本机加密保存密码", "Save password on this device, encrypted"), isOn: $host.savePassword).tint(Palette.accent)
                                .padding(.horizontal, 16).frame(minHeight: 56).accessibilityIdentifier("host-save-password").panelDivider()
                            FormField(label: original?.savePassword == true ? model.text("新密码（留空保留原密码）", "New password (empty keeps the saved one)") : model.text("密码", "Password"), text: $password, id: "host-password", secure: true)
                        } else if host.auth == .key {
                            Divider().overlay(Palette.outline).padding(.leading, 16)
                            // The trailing action stays one short word, so the title keeps its width in any language; the whole row opens the picker.
                            HStack(spacing: 12) {
                                AppIcon("ic_keys").foregroundStyle(Palette.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.keyLabel ?? model.text("尚未导入私钥", "No private key imported")).lineLimit(1)
                                    Text(host.keyLabel == nil ? model.text("支持 Ed25519 / RSA 私钥", "Ed25519 or RSA key") : model.text("已导入私钥", "Private key imported")).font(.footnote).foregroundStyle(Palette.secondary)
                                }
                                Spacer(minLength: 8)
                                Button(host.keyLabel == nil ? model.text("导入", "Import") : model.text("更换", "Replace")) { importKey = true }
                                    .buttonStyle(TextActionStyle()).lineLimit(1).fixedSize().accessibilityIdentifier("host-import-key").accessibilityValue(host.keyLabel ?? "")
                            }.padding(.horizontal, 16).frame(minHeight: 56).contentShape(Rectangle()).onTapGesture { importKey = true }
                                .panelDivider()
                            FormField(label: model.text("私钥口令（仅用于本次连接，可留空）", "Key passphrase (this connection only, optional)"), text: $passphrase, id: "host-key-passphrase", secure: true)
                        }
                    }
                    Panel(title: model.text("会话模式", "Session mode"), footer: host.mode == .tmux
                          ? model.text("每次连接创建独立的远端 tmux 会话，可同时开多个；重连附着同一会话。服务器需要已安装 tmux。", "Each connection creates its own remote tmux session, several at once; reconnecting reattaches it. The server needs tmux installed.")
                          : model.text("直接打开远端 shell。断线后需重新连接，原 shell 不会被恢复。", "Opens the remote shell directly. After a disconnect, reconnect; the old shell is not restored.")) {
                        Picker(model.text("会话模式", "Session mode"), selection: $host.mode) {
                            Text(model.text("tmux · 推荐", "tmux · recommended")).tag(SessionMode.tmux)
                            Text(model.text("普通 SSH", "Plain SSH")).tag(SessionMode.shell)
                        }.pickerStyle(.segmented).padding(8).accessibilityIdentifier("host-session-mode")
                    }
                }.padding(16).frame(maxWidth: 720)
            }.accessibilityIdentifier("host-editor-scroll").frame(maxWidth: .infinity).pageBackground()
                .navigationTitle(forSession != nil ? model.text("新建会话", "New session") : original == nil ? model.text("添加主机", "Add host") : model.text("编辑主机", "Edit host")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(model.text("取消", "Cancel")) { dismiss() }.foregroundStyle(Palette.accent).accessibilityIdentifier("cancel-host-editor") }
                    ToolbarItem(placement: .confirmationAction) { Button(forSession != nil ? model.text("下一步", "Next") : model.text("保存", "Save")) { save() }.fontWeight(.semibold).foregroundStyle(Palette.accent).accessibilityIdentifier("save-host") }
                }
        }.fileImporter(isPresented: $importKey, allowedContentTypes: [.data, .plainText]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                let data = try file.read(upToCount: 1024 * 1024 + 1) ?? Data()
                guard data.count <= 1024 * 1024, !data.isEmpty else { throw RoamError.invalid(model.text("私钥为空或超过 1 MB", "Private key is empty or exceeds 1 MB")) }
                let header = String(decoding: data.prefix(128), as: UTF8.self)
                guard ["-----BEGIN OPENSSH PRIVATE KEY-----", "-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN EC PRIVATE KEY-----", "-----BEGIN PRIVATE KEY-----", "-----BEGIN ENCRYPTED PRIVATE KEY-----"].contains(where: header.contains) else { throw RoamError.invalid(model.text("请选择 PEM 或 OpenSSH 私钥，而不是公钥文件", "Choose a PEM or OpenSSH private key, not a public key file")) }
                privateKey = data; host.keyLabel = url.lastPathComponent
            } catch { validation = error.localizedDescription }
        }
    }
    private func systemName(_ system: String) -> String {
        switch system.uppercased() {
        case "UBUNTU": return "Ubuntu"
        case "DEBIAN": return "Debian"
        case "CENTOS": return "CentOS"
        case "FEDORA": return "Fedora"
        case "ARCH": return "Arch Linux"
        case "REDHAT": return "Red Hat"
        case "OPENSUSE": return "openSUSE"
        case "ROCKY": return "Rocky Linux"
        case "ALMALINUX": return "AlmaLinux"
        case "GENTOO": return "Gentoo"
        case "NIXOS": return "NixOS"
        case "LINUXMINT": return "Linux Mint"
        case "LINUX": return "Linux"
        case "WINDOWS": return "Windows"
        case "MACOS": return "macOS"
        default: return model.text("其他系统", "Other")
        }
    }
    private func save() {
        do {
            guard let value = Int(port) else { throw RoamError.invalid(model.text("端口必须为 1–65535", "Port must be between 1 and 65535")) }
            host.port = value
            // A blank name falls back to the address, so a host filled in for a new session needs no name.
            if host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { host.name = host.address.trimmingCharacters(in: .whitespacesAndNewlines) }
            try model.saveHost(host, password: password, key: privateKey, passphrase: passphrase)
            password = ""; passphrase = ""; privateKey = nil
            // 下一步 goes straight on to the launch sheet for the chosen kind of session.
            if let forSession, let saved = model.host(host.id) {
                model.replaceSheet(with: .launch(saved, forSession != nil, agent: forSession, newSession: true))
            } else { dismiss() }
        } catch { validation = error.localizedDescription }
    }
}
/// Android `FormField`: a borderless grouped-form field; the label floats above once there is a value.
struct FormField: View {
    let label: String
    var placeholder: String? = nil
    @Binding var text: String
    let id: String
    var secure = false
    @FocusState private var focused: Bool
    var body: some View {
        let floating = focused || !text.isEmpty
        VStack(alignment: .leading, spacing: 2) {
            if floating { Text(label).font(.caption).foregroundStyle(focused ? Palette.accent : Palette.secondary).lineLimit(1) }
            Group {
                if secure { SecureField(floating ? (placeholder ?? "") : label, text: $text) }
                else { TextField(floating ? (placeholder ?? "") : label, text: $text) }
            }.font(.body).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
                .accessibilityIdentifier(id)
        }.padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle()).onTapGesture { focused = true }
            .animation(.easeOut(duration: 0.15), value: floating)
    }
}
struct AuthenticationOverlay: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let request = model.authentication {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                AuthenticationCard(request: request).id(request.id).frame(maxWidth: 430).padding(20)
            }.zIndex(100).accessibilityAddTraits(.isModal)
        }
    }
}
private struct AuthenticationCard: View {
    @EnvironmentObject var model: AppModel
    let request: AuthenticationRequest
    @State private var values: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(request.title, systemImage: request.fingerprint == nil ? "lock" : "checkmark.shield").font(.title3.weight(.semibold)).accessibilityIdentifier("auth-title")
            if !request.message.isEmpty { Text(request.message).font(.subheadline).textSelection(.enabled).accessibilityIdentifier("auth-message") }
            if let fingerprint = request.fingerprint {
                Text(fingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("auth-fingerprint")
                Text(model.text("请与服务器管理员确认指纹。信任后会保存在此设备。", "Verify this fingerprint with your server administrator. Trust is saved on this device.")).font(.footnote).foregroundStyle(Palette.secondary)
            }
            ForEach(Array(request.labels.enumerated()), id: \.offset) { index, label in
                if index < values.count {
                    Group {
                        if request.echo.indices.contains(index) && request.echo[index] { TextField(label, text: $values[index]).textInputAutocapitalization(.never).autocorrectionDisabled() }
                        else { SecureField(label, text: $values[index]) }
                    }.padding(12).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10)).accessibilityLabel(label).accessibilityIdentifier("auth-field-\(index)")
                }
            }
            HStack {
                Button(model.text("取消", "Cancel")) { model.answerPrompt(nil) }.buttonStyle(RoamButtonStyle()).accessibilityIdentifier("auth-cancel")
                Button(request.fingerprint == nil ? model.text("继续", "Continue") : model.text("信任并连接", "Trust and connect")) { model.answerPrompt(request.fingerprint == nil ? values : ["trust"]) }.buttonStyle(RoamButtonStyle(primary: true)).accessibilityIdentifier("auth-confirm")
            }
        }.padding(24).background(Palette.raised, in: RoundedRectangle(cornerRadius: 28)).foregroundStyle(Palette.foreground)
            .onAppear { values = Array(repeating: "", count: request.labels.count) }
    }
}
struct FingerprintReview: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let host: Host
    /// Android removes the old record and reconnects at once, so the new fingerprint is shown for approval.
    var onRemoved: (() -> Void)? = nil
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                EmptyMessage(icon: "exclamationmark.shield", title: model.text("服务器指纹已变化", "Host key changed"), message: model.text("这可能是服务器重装或连接被拦截。请通过可信渠道核对新的指纹，再移除之前的记录。", "This can mean the server was reinstalled or the connection was intercepted. Verify the new fingerprint through a trusted channel before removing the previous record."))
                Button(onRemoved == nil ? model.text("移除旧指纹", "Remove previous fingerprint") : model.text("移除旧记录并重连", "Remove and reconnect"), role: .destructive) {
                    model.forgetPin(host); dismiss(); onRemoved?()
                }.buttonStyle(RoamButtonStyle()).accessibilityIdentifier("fingerprint-remove")
                Spacer()
            }.padding(16).pageBackground().navigationTitle(host.name).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(model.text("取消", "Cancel")) { dismiss() } } }
        }
    }
}
