import SwiftUI
import RoamttyCore

struct HostsScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    var filtered: [Host] { model.hosts.filter { search.isEmpty || "\($0.name) \($0.address) \($0.username)".localizedCaseInsensitiveContains(search) } }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack").font(.system(size: 28, weight: .medium))
                    Text(model.text("主机", "Hosts")).font(.system(size: 30, weight: .semibold)).accessibilityAddTraits(.isHeader).accessibilityIdentifier("hosts-title")
                    Spacer()
                    Button { model.sheet = .editor(nil) } label: { Image(systemName: "plus").font(.system(size: 25, weight: .regular)).frame(width: 48, height: 48) }.accessibilityLabel(model.text("添加主机", "Add host")).accessibilityIdentifier("add-host")
                }.foregroundStyle(Palette.foreground).padding(.leading, 16).padding(.trailing, 8).padding(.bottom, 12)
                if searching {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
                        TextField(model.text("搜索主机", "Search hosts"), text: $search).focused($searchFocused).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("host-search")
                        Button { search = ""; searching = false; searchFocused = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.secondary) }.accessibilityLabel(model.text("关闭搜索", "Close search")).accessibilityIdentifier("host-search-close")
                    }.padding(12).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 16).padding(.bottom, 12)
                }
                ScrollView {
                    if model.hosts.isEmpty {
                        VStack(spacing: 16) {
                            Image("RoamttyLogo").resizable().scaledToFit().frame(width: 56, height: 56).padding(.bottom, 8)
                            Text(model.text("从第一台主机开始", "Start with your first host")).font(.system(size: 20, weight: .semibold))
                            Text(model.text("保存远端主机，运行 AI 编程工具。\n可直连，也可使用手机已有 VPN。", "Save remote hosts and run AI coding tools.\nConnect directly or use your phone’s VPN.")).font(.system(size: 14)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                            Button(model.text("添加主机", "Add host")) { model.sheet = .editor(nil) }
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.adaptive(0xFFFFFF, 0x442315)).padding(.horizontal, 24).frame(height: 44).background(Palette.accent, in: Capsule()).padding(.top, 8)
                        }.padding(.horizontal, 24).frame(maxWidth: .infinity).frame(minHeight: max(300, geometry.size.height - (searching ? 132 : 76)))
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                            ForEach(filtered) { host in
                                NavigationLink(value: AppRoute.host(host.id)) { HostCard(host: host) }.buttonStyle(.plain).accessibilityIdentifier("host-\(host.name)")
                                    .contextMenu {
                                        Button(model.text("编辑主机", "Edit host"), systemImage: "pencil") { model.sheet = .editor(host) }
                                        Button(model.text("主机详情", "Host details"), systemImage: "server.rack") { model.path.append(.host(host.id)) }
                                    }
                            }
                        }.padding(16)
                    }
                }
            }
        }.pageBackground().navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.background, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .task(id: model.hosts) {
                while !Task.isCancelled { await model.probeHosts(model.hosts); do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { break } }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button { withAnimation(.easeOut(duration: 0.2)) { model.drawer = true } } label: { Image(systemName: "line.3.horizontal").foregroundStyle(Palette.foreground) }.accessibilityLabel(model.text("打开菜单", "Open menu")).accessibilityIdentifier("open-drawer") }
                ToolbarItem(placement: .navigationBarTrailing) { Button { withAnimation { searching.toggle() }; searchFocused = searching; if !searching { search = "" } } label: { Image(systemName: "magnifyingglass").foregroundStyle(Palette.foreground) }.accessibilityLabel(model.text("搜索主机", "Search hosts")).accessibilityIdentifier("search-hosts") }
            }
    }
}
struct HostCard: View {
    @EnvironmentObject var model: AppModel
    let host: Host
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                HostSystemMark(system: host.system).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.name).font(.headline).lineLimit(1)
                    Text("\(host.username)@\(host.address)").font(.subheadline).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
            }
            HStack(spacing: 8) {
                Badge(text: host.mode == .tmux ? "tmux" : "SSH")
                Badge(text: host.auth == .key ? model.text("私钥", "Key") : host.auth == .interactive ? model.text("交互认证", "Interactive") : model.text("密码", "Password"))
                Spacer()
                let sessions = model.records.filter { $0.hostID == host.id }
                Text(model.text("\(sessions.count) 个会话", "\(sessions.count) sessions")).font(.caption).foregroundStyle(Palette.secondary)
            }
            ReachabilityLabel(state: model.reachability[host.id] ?? .checking)
        }.padding(16).background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(Palette.foreground)
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
                    Image(systemName: "server.rack").font(.system(size: side * 0.5)).foregroundStyle(Palette.accent)
                }
            }.clipShape(RoundedRectangle(cornerRadius: side * 0.28)).accessibilityLabel(system)
        }
    }
}
