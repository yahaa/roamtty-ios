import SwiftUI
import RoamttyCore

typealias Host = RoamttyCore.Host

@main struct RoamttyApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootScreen().environmentObject(model).preferredColorScheme(model.colorScheme).tint(Palette.accent)
                .task {
                    #if DEBUG
                    await DeviceValidation.runIfRequested(model: model)
                    #endif
                }
                .onChange(of: scenePhase) { phase in if phase == .active { model.resume() } else if phase == .background { model.suspend() } }
                .onOpenURL { url in
                    if url.isFileURL {
                        do {
                            let imported = try SharedInbox.copyIncoming(url)
                            if !model.incomingFiles.contains(imported) { model.incomingFiles.append(imported) }
                        } catch { model.error = error.localizedDescription }
                    } else if url.scheme == "roamtty" { model.resume() }
                }
        }
    }
}
struct RootScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedShareUpload: UUID?
    var body: some View {
        ZStack(alignment: .leading) {
            NavigationStack(path: $model.path) {
                HostsScreen()
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .host(let id):
                            if let host = model.host(id) { HostDetailScreen(hostID: host.id) }
                        case .terminal(let id):
                            if let runtime = model.runtimes[id] {
                                // Reconnect retains the journal ID but owns a new renderer.
                                // Recreate UIKit and sheet state with that runtime instance.
                                TerminalScreen(runtime: runtime).id(ObjectIdentifier(runtime))
                            }
                            else { EmptyMessage(title: model.text("会话已关闭", "Session closed"), message: model.text("返回主机详情重新连接。", "Return to this host to connect again.")) }
                        case .files(let id, let sessionID, let directory):
                            if let host = model.host(id) {
                                let target = model.connectionTarget(hostID: id, sessionID: sessionID)
                                FileBrowserScreen(host: target.runtime?.host ?? host, sessionID: sessionID, initialDirectory: directory, connectionTarget: target)
                            }
                        }
                    }
            }
            if model.drawer {
                Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { withAnimation { model.drawer = false } }
                DrawerScreen().frame(width: min(360, UIScreen.main.bounds.width * 0.82)).transition(.move(edge: .leading))
            }
            AuthenticationOverlay()
        }
        .sheet(item: $model.sheet) { sheet in
            ZStack {
                switch sheet {
                case .editor(let host): HostEditorScreen(original: host)
                case .settings: SettingsScreen()
                case .launch(let host, let agent, let directory): LaunchScreen(host: host, forAgent: agent, initialDirectory: directory)
                case .plugins(let host): PluginsScreen(host: host)
                case .guide: HelpScreen()
                case .about: AboutScreen()
                }
                AuthenticationOverlay()
            }.environmentObject(model).preferredColorScheme(model.colorScheme).tint(Palette.accent)
        }
        .sheet(isPresented: Binding(get: { !model.incomingFiles.isEmpty && model.sheet == nil && model.childModalCount == 0 && model.authentication == nil }, set: { if !$0 { model.incomingFiles = [] } }), onDismiss: completeShareHandoff) {
            NavigationStack {
                List {
                    Section(model.text("选择上传主机", "Choose an upload host")) {
                        ForEach(model.hosts) { host in
                            Button(host.name) {
                                selectedShareUpload = model.files.prepareSharedUpload(model.incomingFiles, hostID: host.id)
                                model.incomingFiles = []
                            }.accessibilityIdentifier("share-host-\(host.id)")
                        }
                    }
                }.navigationTitle(model.text("共享文件", "Shared files"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(model.text("取消", "Cancel")) { model.incomingFiles = [] } } }
            }.preferredColorScheme(model.colorScheme)
        }
        .alert(model.text("无法完成操作", "Unable to complete"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(model.text("好", "OK"), role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Text(notice).font(.subheadline).padding(16).frame(maxWidth: 500).background(Palette.raised, in: RoundedRectangle(cornerRadius: 20)).shadow(radius: 6).padding(16)
                    .onTapGesture { model.notice = nil }
                    .task(id: notice) { try? await Task.sleep(nanoseconds: 4_000_000_000); if model.notice == notice { model.notice = nil } }
            }
        }
    }
    private func completeShareHandoff() {
        guard let requestID = selectedShareUpload else { return }
        selectedShareUpload = nil
        guard let hostID = model.files.releaseSharedUpload(requestID) else { return }
        guard model.host(hostID) != nil else {
            let urls = model.files.finishSharedUpload(requestID)
            model.incomingFiles.append(contentsOf: urls.filter { !model.incomingFiles.contains($0) })
            return
        }
        model.path = [.host(hostID), .files(hostID)]
    }
}
/// Android `ItermuxDrawer`: brand header, Hosts with its count, the open sessions, then Settings and Help.
struct DrawerScreen: View {
    @EnvironmentObject var model: AppModel
    private var sessions: [SessionRecord] { model.records.filter { model.runtimes[$0.id] != nil } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Image("RoamttyLogo").resizable().scaledToFit().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Roamtty").font(.system(size: 20, weight: .semibold))
                    Text(model.text("远程终端", "Remote terminal")).font(.footnote).foregroundStyle(Palette.secondary)
                }.padding(.leading, 14)
                Spacer()
                Button { close() } label: { AppIcon("ic_close").foregroundStyle(Palette.secondary).frame(width: 48, height: 48) }
                    .accessibilityLabel(model.text("关闭", "Close"))
            }.padding(.leading, 24).padding(.trailing, 12).padding(.top, 24).padding(.bottom, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    item(model.text("主机", "Hosts"), icon: "ic_hosts", selected: model.path.isEmpty, badge: "\(model.hosts.count)") { model.path = []; close() }
                        .accessibilityIdentifier("drawer-hosts")
                    Divider().overlay(Palette.outline).padding(.horizontal, 24).padding(.vertical, 16)
                    Text(model.text("当前会话", "Open sessions")).font(.subheadline.weight(.medium)).foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 28).padding(.vertical, 8)
                    if sessions.isEmpty {
                        Text(model.text("暂无会话", "No sessions")).font(.subheadline).foregroundStyle(Palette.secondary).padding(.horizontal, 28).padding(.vertical, 12)
                    }
                    ForEach(sessions) { record in sessionItem(record) }
                }
            }
            Divider().overlay(Palette.outline)
            VStack(spacing: 0) {
                item(model.text("设置", "Settings"), icon: "ic_settings") { open(.settings) }.accessibilityIdentifier("open-settings")
                item(model.text("帮助", "Help"), icon: "ic_help") { open(.guide) }.accessibilityIdentifier("open-guide")
                item(model.text("关于", "About"), icon: "ic_preview") { open(.about) }.accessibilityIdentifier("open-about")
            }.padding(.vertical, 8)
        }.frame(maxHeight: .infinity).background(Palette.sheet.ignoresSafeArea()).foregroundStyle(Palette.foreground)
    }
    private func close() { withAnimation(.easeOut(duration: 0.2)) { model.drawer = false } }
    private func open(_ sheet: AppSheet) { model.drawer = false; model.sheet = sheet }
    private func item(_ title: String, icon: String, selected: Bool = false, badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AppIcon(icon, size: 24)
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                if let badge { Text(badge).font(.subheadline.weight(.medium)) }
            }.padding(.leading, 16).padding(.trailing, 24).frame(height: 56)
                .foregroundStyle(selected ? Palette.adaptive(0x3D332D, 0xECE2D8) : Palette.secondary)
                .background(selected ? Palette.adaptive(0xECE4DB, 0x47413B) : Color.clear, in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).padding(.horizontal, 12)
    }
    private func sessionItem(_ record: SessionRecord) -> some View {
        let host = model.host(record.hostID)
        let phase = model.runtimes[record.id]?.phase ?? .disconnected
        return Button { model.drawer = false; model.openSession(record) } label: {
            HStack(spacing: 12) {
                HostSystemMark(system: host?.system ?? "UNKNOWN").frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.sessionTitle(record)).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.foreground).lineLimit(1)
                    Text("\(host?.username ?? "")@\(host?.address ?? "")").font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                PhaseLabel(phase: phase)
            }.padding(.leading, 16).padding(.trailing, 24).frame(minHeight: 56).contentShape(Capsule())
        }.buttonStyle(.plain).padding(.horizontal, 12).accessibilityIdentifier("drawer-session-\(record.id)")
    }
}
