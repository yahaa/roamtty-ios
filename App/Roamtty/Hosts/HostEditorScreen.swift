import SwiftUI
import UniformTypeIdentifiers
import RoamttyCore

struct HostEditorScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let original: Host?
    @State private var host: Host
    @State private var port = "22"
    @State private var password = ""
    @State private var passphrase = ""
    @State private var privateKey: Data?
    @State private var importKey = false
    @State private var validation: String?
    init(original: Host?) { self.original = original; _host = State(initialValue: original ?? Host()); _port = State(initialValue: String(original?.port ?? 22)) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Panel(title: model.text("主机信息", "Host information")) {
                        field(model.text("名称", "Name"), text: $host.name, id: "host-name").panelDivider()
                        field(model.text("地址", "Address"), text: $host.address, id: "host-address").keyboardType(.URL).panelDivider()
                        field(model.text("端口", "Port"), text: $port, id: "host-port").keyboardType(.numberPad).panelDivider()
                        field(model.text("用户名", "Username"), text: $host.username, id: "host-username")
                    }
                    Panel(title: model.text("身份验证", "Authentication")) {
                        Picker(model.text("认证方式", "Method"), selection: $host.auth) {
                            Text(model.text("密码", "Password")).tag(AuthMethod.password)
                            Text(model.text("私钥", "Private key")).tag(AuthMethod.key)
                            Text(model.text("交互", "Interactive")).tag(AuthMethod.interactive)
                        }.pickerStyle(.segmented).padding(12).accessibilityIdentifier("host-auth-method")
                        if host.auth == .password {
                            SecureField(model.text("密码", "Password"), text: $password).textContentType(.password).padding(16).accessibilityIdentifier("host-password").panelDivider()
                            Toggle(model.text("保存密码", "Save password"), isOn: $host.savePassword).padding(16).accessibilityIdentifier("host-save-password")
                        } else if host.auth == .key {
                            Button { importKey = true } label: { InfoRow(title: model.text("导入私钥", "Import private key"), value: host.keyLabel ?? model.text("选择文件", "Choose file"), icon: "key") }.panelDivider().accessibilityIdentifier("host-import-key")
                            SecureField(model.text("私钥口令（可选）", "Key passphrase (optional)"), text: $passphrase).padding(16).accessibilityIdentifier("host-key-passphrase")
                        } else { Text(model.text("连接时回答服务器的认证提示，支持验证码。", "Answer the server’s prompts when connecting, including verification codes.")).font(.footnote).foregroundStyle(Palette.secondary).padding(16) }
                    }
                    Panel(title: model.text("默认会话", "Default session"), footer: model.text("tmux 可在连接中断后恢复；普通 SSH 会话随连接关闭。", "tmux can resume after disconnection; plain SSH ends with its connection.")) {
                        Picker(model.text("会话模式", "Session mode"), selection: $host.mode) { Text("tmux").tag(SessionMode.tmux); Text("SSH").tag(SessionMode.shell) }.pickerStyle(.segmented).padding(12).accessibilityIdentifier("host-session-mode")
                    }
                    if let validation { Text(validation).foregroundStyle(Palette.danger).font(.subheadline).accessibilityIdentifier("editor-error") }
                }.padding(16).frame(maxWidth: 720)
            }.accessibilityIdentifier("host-editor-scroll").frame(maxWidth: .infinity).pageBackground().navigationTitle(original == nil ? model.text("添加主机", "Add host") : model.text("编辑主机", "Edit host")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(model.text("取消", "Cancel")) { dismiss() }.accessibilityIdentifier("cancel-host-editor") }
                    ToolbarItem(placement: .confirmationAction) { Button(model.text("保存", "Save")) { save() }.fontWeight(.semibold).accessibilityIdentifier("save-host") }
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
    private func field(_ label: String, text: Binding<String>, id: String) -> some View {
        HStack { Text(label).frame(width: 78, alignment: .leading); TextField(label, text: text).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(id) }.padding(16)
    }
    private func save() {
        do {
            guard let value = Int(port) else { throw RoamError.invalid(model.text("端口必须为 1–65535", "Port must be between 1 and 65535")) }
            host.port = value
            try model.saveHost(host, password: password, key: privateKey, passphrase: passphrase)
            password = ""; passphrase = ""; privateKey = nil; dismiss()
        } catch { validation = error.localizedDescription }
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
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                EmptyMessage(icon: "exclamationmark.shield", title: model.text("服务器指纹已变化", "Host key changed"), message: model.text("这可能是服务器重装或连接被拦截。请通过可信渠道核对新的指纹，再移除之前的记录。", "This can mean the server was reinstalled or the connection was intercepted. Verify the new fingerprint through a trusted channel before removing the previous record."))
                Button(model.text("移除旧指纹", "Remove previous fingerprint"), role: .destructive) { model.forgetPin(host); dismiss() }.buttonStyle(RoamButtonStyle())
                Spacer()
            }.padding(16).pageBackground().navigationTitle(host.name).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(model.text("取消", "Cancel")) { dismiss() } } }
        }
    }
}
