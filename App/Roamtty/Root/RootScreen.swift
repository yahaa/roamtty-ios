import SwiftUI
import UIKit
import RoamttyCore

/// The navigation stack under the drawer, the sheets, the share-upload picker, alerts and notices.
struct RootScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedShareUpload: UUID?
    /// How far a horizontal swipe has pulled the open drawer back towards the left edge.
    @State private var drawerDrag: CGFloat = 0
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
                            else if let record = model.records.first(where: { $0.id == id }) {
                                // A session restored from the journal reconnects as soon as it is shown.
                                Color.clear.onAppear { model.openRestored(record) }
                            }
                            else { EmptyMessage(title: model.text("会话已关闭", "Session closed"), message: model.text("返回会话列表重新连接。", "Return to the session list to connect again.")) }
                        case .files(let id, let sessionID, let directory):
                            if let host = model.host(id) {
                                let target = model.connectionTarget(hostID: id, sessionID: sessionID)
                                FileBrowserScreen(host: target.runtime?.host ?? host, sessionID: sessionID, initialDirectory: directory, connectionTarget: target)
                            }
                        }
                    }
            }
            if model.drawer {
                let width = min(360, UIScreen.main.bounds.width * 0.82)
                Color.black.opacity(0.35 * (1 + drawerDrag / width)).ignoresSafeArea().onTapGesture { withAnimation { model.drawer = false } }
                    .gesture(drawerSwipe(width: width))
                DrawerScreen().frame(width: width).offset(x: drawerDrag).transition(.move(edge: .leading))
                    .simultaneousGesture(drawerSwipe(width: width))
            }
            AuthenticationOverlay()
        }
        .onChange(of: model.drawer) { open in if open { drawerDrag = 0 } }
        .sheet(item: $model.sheet) { sheet in
            ZStack {
                switch sheet {
                case .editor(let host): HostEditorScreen(original: host)
                case .newHost(let agent): HostEditorScreen(original: nil, forSession: .some(agent))
                case .newSession: NewSessionSheet()
                case .settings: SettingsScreen()
                case .launch(let host, let agent, let directory, let picked, let newSession):
                    LaunchScreen(host: host, forAgent: agent, initialDirectory: directory, initialAgent: picked,
                                 title: newSession ? model.text("选择工作目录", "Choose a working folder") : nil)
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
    /// The drawer follows a leftward swipe and closes once it has moved a third of its width or is flung.
    private func drawerSwipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) || drawerDrag != 0 else { return }
                drawerDrag = min(0, value.translation.width)
            }
            .onEnded { value in
                let close = drawerDrag != 0 && (drawerDrag < -width / 3 || value.predictedEndTranslation.width < -width / 2)
                // A closed drawer keeps its offset until it opens again, so it slides out from where the finger left it.
                withAnimation(.easeOut(duration: 0.2)) { if close { model.drawer = false } else { drawerDrag = 0 } }
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

/// SwiftUI turns the edge swipe back off on pages that hide the navigation bar, such as the terminal.
/// Keep it on for every pushed page, and let it win over the terminal's own pans that start near the edge.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === interactivePopGestureRecognizer else { return true }
        return viewControllers.count > 1 && transitionCoordinator == nil
    }
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === interactivePopGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer
            && !(otherGestureRecognizer is UIScreenEdgePanGestureRecognizer)
    }
}
