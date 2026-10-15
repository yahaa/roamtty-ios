import SwiftUI
import RoamttyCore

/// Android's home page: 会话 and 主机 tabs in the toolbar, each with a count and a + above its list. Swiping moves
/// between them; search filters the tab in view.
struct HostsScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            if searching {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                    TextField(model.homeTab == .sessions ? model.text("标题、主机、地址或用户名", "Title, host, address or username") : model.text("名称、地址或用户名", "Name, address or username"), text: $search)
                        .focused($searchFocused).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("host-search")
                    Button { search = ""; searching = false; searchFocused = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.secondary) }.accessibilityLabel(model.text("关闭搜索", "Close search")).accessibilityIdentifier("host-search-close")
                }.padding(12).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 16).padding(.bottom, 8)
            }
            TabView(selection: $model.homeTab) {
                HomeSessionsTab(search: search).tag(HomeTab.sessions)
                HomeHostsTab(search: search).tag(HomeTab.hosts)
            }.tabViewStyle(.page(indexDisplayMode: .never)).accessibilityIdentifier("home-pager")
        }.pageBackground().navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .task(id: model.hosts) {
                while !Task.isCancelled { await model.probeHosts(model.hosts); do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { break } }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button { withAnimation(.easeOut(duration: 0.2)) { model.drawer = true } } label: { AppIcon("ic_sidebar", size: 24).foregroundStyle(Palette.foreground).frame(width: 40, height: 40) }.accessibilityLabel(model.text("打开菜单", "Open menu")).accessibilityIdentifier("open-drawer") }
                ToolbarItem(placement: .principal) { HomeTabs() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { withAnimation { searching.toggle() }; searchFocused = searching; if !searching { search = "" } } label: { AppIcon("ic_search", size: 24).foregroundStyle(Palette.foreground).frame(width: 40, height: 40) }
                        .accessibilityLabel(model.homeTab == .sessions ? model.text("搜索会话", "Search sessions") : model.text("搜索主机", "Search hosts")).accessibilityIdentifier("search-hosts")
                }
            }
    }
}

/// The home page's tabs in the toolbar: the names side by side, the selected one in full colour with a short bar beneath it.
struct HomeTabs: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            tab(model.text("会话", "Sessions"), .sessions, id: "home-tab-sessions")
            tab(model.text("主机", "Hosts"), .hosts, id: "home-tab-hosts")
        }
    }
    private func tab(_ title: String, _ value: HomeTab, id: String) -> some View {
        let active = model.homeTab == value
        return Button { withAnimation(.easeInOut(duration: 0.25)) { model.homeTab = value } } label: {
            VStack(spacing: 6) {
                Text(title).font(.system(size: 20, weight: active ? .semibold : .regular)).lineLimit(1)
                    .foregroundStyle(active ? Palette.foreground : Palette.secondary.opacity(0.7))
                Capsule().fill(active ? Palette.foreground : Color.clear).frame(width: 20, height: 3)
            }.padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? [.isSelected, .isHeader] : []).accessibilityIdentifier(id)
    }
}

/// The line above a home list: how many it holds on the left, the + that adds one on the right.
struct HomeListHeader: View {
    let label: String
    let addLabel: String
    let id: String
    let onAdd: () -> Void
    var body: some View {
        HStack {
            Text(label).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.secondary).lineLimit(1)
            Spacer()
            Button(action: onAdd) { AppIcon("ic_add", size: 24).foregroundStyle(Palette.foreground).frame(width: 48, height: 48).contentShape(Rectangle()) }
                .accessibilityLabel(addLabel).accessibilityIdentifier(id)
        }.padding(.leading, 16).padding(.trailing, 4)
    }
}

struct HomeEmptyState<Action: View>: View {
    var logo = false
    let title: String
    let message: String
    @ViewBuilder var action: Action
    var body: some View {
        VStack(spacing: 16) {
            if logo { Image("RoamttyLogo").resizable().scaledToFit().frame(width: 56, height: 56).padding(.bottom, 8).accessibilityIdentifier("empty-logo") }
            Text(title).font(.system(size: 20, weight: .semibold)).multilineTextAlignment(.center)
            Text(message).font(.system(size: 14)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
            action
        }.padding(.horizontal, 24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AccentCapsuleButton: View {
    let title: String
    var id: String? = nil
    let action: () -> Void
    var body: some View {
        Button(title, action: action).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 24).frame(height: 44).background(Palette.accent, in: Capsule()).padding(.top, 8)
            .accessibilityIdentifier(id ?? title)
    }
}

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
                            NavigationLink(value: AppRoute.host(host.id)) { HostCard(host: host) }.buttonStyle(.plain).accessibilityIdentifier("host-\(host.name)")
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 16)
                }.accessibilityIdentifier("host-grid")
            }
        }
    }
}

/// Android `HostCard`: system tile, name and endpoint, a ··· menu, then reachability and the host's tags.
struct HostCard: View {
    @EnvironmentObject var model: AppModel
    let host: Host
    @State private var deleteConfirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HostSystemMark(system: host.system).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text("\(host.username)@\(host.address):" + String(host.port)).font(.system(size: 13)).foregroundStyle(Palette.secondary).lineLimit(1)
                }.padding(.leading, 12).padding(.trailing, 8)
                Spacer(minLength: 0)
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
                // Once probed, the card lists only the plugins the host actually has.
                if let plugins = host.plugins { ForEach(["tmux", "mosh"].filter(plugins.contains), id: \.self) { Badge(text: $0) } }
                else { Badge(text: host.mode == .tmux ? "tmux" : model.text("普通 SSH", "Plain SSH")) }
                Badge(text: host.auth == .key ? model.text("私钥", "Key") : host.auth == .interactive ? model.text("交互式认证", "Interactive") : model.text("密码", "Password"))
                if host.system.uppercased() == "UNKNOWN" { Badge(text: model.text("待检测系统", "System pending")) }
            }.padding(.top, 12)
        }.padding(.leading, 16).padding(.top, 14).padding(.trailing, 4).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(Palette.foreground)
            .confirmationDialog(model.text("删除 \(host.name)？", "Delete \(host.name)?"), isPresented: $deleteConfirm, titleVisibility: .visible) {
                Button(model.text("删除主机", "Delete host"), role: .destructive) { model.deleteHost(host) }
            }
    }
}
struct HostSystemMark: View {
    @Environment(\.colorScheme) private var scheme
    let system: String
    private var info: (asset: String, brand: UInt32, scale: CGFloat)? {
        switch system.uppercased() {
        case "UBUNTU": return ("ubuntu", 0xE95420, 0.6)
        case "DEBIAN": return ("debian", 0xD70A53, 0.64)
        case "CENTOS": return ("centos", 0x9C4C99, 0.6)
        case "FEDORA": return ("fedora", 0x51A2DA, 0.6)
        case "ARCH": return ("archlinux", 0x1793D1, 0.6)
        case "REDHAT": return ("redhat", 0xEE0000, 0.6)
        case "OPENSUSE": return ("opensuse", 0x73BA25, 0.68)
        case "ROCKY": return ("rockylinux", 0x10B981, 0.6)
        case "ALMALINUX": return ("almalinux", 0x0F8BD6, 0.6)
        case "GENTOO": return ("gentoo", 0x8E7FC4, 0.6)
        case "NIXOS": return ("nixos", 0x7EBAE4, 0.6)
        case "LINUXMINT": return ("linuxmint", 0x87CF3E, 0.6)
        case "LINUX": return ("linux", 0xF2B705, 0.64)
        case "WINDOWS": return ("windows", 0x0078D4, 0.5)
        case "MACOS": return ("macos", 0x9A9A9F, 0.64)
        default: return nil
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                if let info {
                    let darkInk = ["DEBIAN", "LINUX", "REDHAT"].contains(system.uppercased())
                    if scheme == .dark && darkInk { Color(uiColor: UIColor(hex: 0xE6E1D8)) }
                    Color(uiColor: UIColor(hex: info.brand)).opacity(scheme == .dark ? darkInk ? 0.14 : 0.22 : 0.12)
                    Image("ic_os_" + info.asset).resizable().scaledToFit().frame(width: side * info.scale, height: side * info.scale)
                } else {
                    Palette.accentPanel
                    AppIcon("ic_os_server", size: side * 0.5).foregroundStyle(Palette.adaptive(0x682F20, 0xF9D9C9))
                }
            }.clipShape(RoundedRectangle(cornerRadius: side * 0.28)).accessibilityLabel(system)
        }
    }
}
