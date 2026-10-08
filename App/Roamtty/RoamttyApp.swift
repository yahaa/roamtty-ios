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
                DrawerScreen().frame(width: 300).transition(.move(edge: .leading))
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
struct DrawerScreen: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) { GhostMark().frame(width: 48, height: 48); Text("Roamtty").font(.title2.weight(.semibold)) }.padding(.vertical, 24)
            Button { model.path = []; model.drawer = false } label: { Label(model.text("主机", "Hosts"), systemImage: "server.rack").frame(maxWidth: .infinity, alignment: .leading).padding(16) }.background(Palette.accentPanel, in: RoundedRectangle(cornerRadius: 12)).accessibilityIdentifier("drawer-hosts")
            drawerItem(model.text("设置", "Settings"), "gearshape", .settings).accessibilityIdentifier("open-settings")
            drawerItem(model.text("使用指南", "Guide"), "questionmark.circle", .guide).accessibilityIdentifier("open-guide")
            drawerItem(model.text("关于", "About"), "info.circle", .about).accessibilityIdentifier("open-about")
            Spacer()
            Text("Roamtty · SSH + tmux + mosh").font(.caption).foregroundStyle(Palette.secondary).padding(.bottom, 24)
        }.padding(.horizontal, 16).frame(maxHeight: .infinity).background(Palette.background).foregroundStyle(Palette.foreground)
    }
    private func drawerItem(_ title: String, _ icon: String, _ sheet: AppSheet) -> some View {
        Button { model.drawer = false; model.sheet = sheet } label: { Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
    }
}
