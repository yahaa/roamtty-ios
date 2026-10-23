import SwiftUI
import RoamttyCore
import RoamttyDesktopCore

struct HomeHostsTab: View {
    @EnvironmentObject var model: AppModel
    let search: String
    var filtered: [Host] { model.hosts.filter { search.isEmpty || "\($0.name) \($0.address) \($0.username)".localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 0) {
            HomeListHeader(label: model.text("主机 · \(model.hosts.count)", "Hosts · \(model.hosts.count)"), addLabel: model.text("添加主机", "Add host"), id: "add-host") { model.sheet = .editor(nil) }
            if model.hosts.isEmpty {
                HomeEmptyState(logo: true, title: model.text("从第一台主机开始", "Start with your first host"),
                               message: model.text("保存远端主机，运行 AI 编程工具。\n可直连，也可使用手机已有 VPN。", "Save remote hosts and run AI coding tools.\nConnect directly or use your phone’s VPN.")) {
                    AccentCapsuleButton(title: model.text("添加主机", "Add host"), id: "empty-add-host") { model.sheet = .editor(nil) }
                }
            } else if filtered.isEmpty {
                HomeEmptyState(title: model.text("没有匹配的主机", "No matching hosts"), message: model.text("试试其他名称或地址", "Try another name or address")) { EmptyView() }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(filtered) { host in
                            HostCard(host: host)
                                .accessibilityIdentifier("host-\(host.name)")
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 16)
                }.accessibilityIdentifier("host-grid")
            }
        }
    }
}

/// Android `HostCard`: system tile, name and endpoint, a ··· menu, then reachability and the host's tags;
/// its desktop is the icon tag at the end of the status line (Android `DesktopCardButton`, sessionConnected: true).
struct HostCard: View {
    @EnvironmentObject var model: AppModel
    let host: Host
    @State private var deleteConfirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                // Tap the identity opens host detail; the ··· menu and desktop stay outside the link
                // so they do not navigate (Android HostCard: openDetail on the card, desktop as its own tag).
                NavigationLink(value: AppRoute.host(host.id)) {
                    HStack(spacing: 0) {
                        HostSystemMark(system: host.system).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                            Text("\(host.username)@\(host.address):" + String(host.port)).font(.system(size: 13)).foregroundStyle(Palette.secondary).lineLimit(1)
                        }.padding(.leading, 12).padding(.trailing, 8)
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Menu {
                    Button { model.sheet = .launch(host, false) } label: { Label { Text(model.text("打开终端", "Open terminal")) } icon: { Image("ic_sessions") } }
                    Button { model.sheet = .launch(host, true) } label: { Label { Text("AI Agent") } icon: { Image("ic_agent") } }
                    Divider()
                    Button { model.sheet = .editor(host) } label: { Label { Text(model.text("编辑主机", "Edit host")) } icon: { Image("ic_edit") } }
                    Button { model.path = [.host(host.id), .files(host.id)] } label: { Label { Text(model.text("查看文件", "Browse files")) } icon: { Image("ic_folder") } }
                    Button { model.sheet = .plugins(host) } label: { Label { Text(model.text("安装插件", "Install plugins")) } icon: { Image("ic_plugin") } }
                    Divider()
                    Button(role: .destructive) { deleteConfirm = true } label: { Label { Text(model.text("删除主机", "Delete host")) } icon: { Image("ic_delete") } }
                } label: { AppIcon("ic_more_vert").foregroundStyle(Palette.secondary).frame(width: 48, height: 48).contentShape(Rectangle()) }
                    .accessibilityLabel(model.text("主机选项：", "Host options: ") + host.name).accessibilityIdentifier("host-menu-\(host.id)")
            }
            HStack(spacing: 6) {
                ReachabilityLabel(state: model.reachability[host.id] ?? .checking).padding(.trailing, 2)
                Spacer(minLength: 8)
                // Once probed, the card lists only the plugins the host actually has.
                if let plugins = host.plugins { ForEach(["tmux", "mosh"].filter(plugins.contains), id: \.self) { Badge(text: $0) } }
                else { Badge(text: host.mode == .tmux ? "tmux" : model.text("普通 SSH", "Plain SSH")) }
                Badge(text: host.auth == .key ? model.text("私钥", "Key") : host.auth == .interactive ? model.text("交互式认证", "Interactive") : model.text("密码", "Password"))
                if host.system.uppercased() == "UNKNOWN" { Badge(text: model.text("待检测系统", "System pending")) }
                // A host needs no open session for its desktop: the desktop logs in on its own.
                desktopEntry
            }.padding(.top, 12).padding(.trailing, 12)
        }.padding(.leading, 16).padding(.top, 14).padding(.trailing, 4).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(Palette.foreground)
            .confirmationDialog(model.text("删除 \(host.name)？", "Delete \(host.name)?"), isPresented: $deleteConfirm, titleVisibility: .visible) {
                Button(model.text("删除主机", "Delete host"), role: .destructive) { model.deleteHost(host) }
            }
    }

    @ViewBuilder private var desktopEntry: some View {
        if model.settings.desktopEnabled {
            let button = model.desktopButton(for: host, sessionConnected: true)
            DesktopCardButton(state: button, accessibilityID: "host-desktop-\(host.id)") {
                model.openDesktop(host)
            }
            .accessibilityLabel(model.text("打开桌面", "Open desktop"))
        }
    }
}
