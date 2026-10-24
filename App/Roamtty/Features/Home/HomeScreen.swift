import SwiftUI
import RoamttyCore

/// Android's home page: 会话 and 主机 tabs in the toolbar, each with a count and a + above its list. Swiping moves
/// between them; search filters the tab in view.
struct HomeScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            header
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
        }.pageBackground().toolbar(.hidden, for: .navigationBar)
            .task(id: model.hosts) {
                while !Task.isCancelled { await model.probeHosts(model.hosts); do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { break } }
            }

    }
    // A flat header matches the host cards instead of acquiring iOS 26 toolbar glass.
    private var header: some View {
        HStack {
            Button { withAnimation(.easeOut(duration: 0.2)) { model.drawer = true } } label: {
                AppIcon("ic_sidebar", size: 26).foregroundStyle(Palette.foreground)
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }.accessibilityLabel(model.text("打开菜单", "Open menu")).accessibilityIdentifier("open-drawer")
            Spacer(minLength: 0)
            HomeTabs()
            Spacer(minLength: 0)
            Button { withAnimation { searching.toggle() }; searchFocused = searching; if !searching { search = "" } } label: {
                AppIcon("ic_search", size: 26).foregroundStyle(Palette.foreground)
                    .frame(width: 48, height: 48).contentShape(Rectangle())
            }.accessibilityLabel(model.homeTab == .sessions ? model.text("搜索会话", "Search sessions") : model.text("搜索主机", "Search hosts"))
                .accessibilityIdentifier("search-hosts")
        }.buttonStyle(.plain).padding(.horizontal, 6).frame(height: 64)
    }

}

/// The home page's tabs in the toolbar: the names side by side, the selected one in full colour with a short bar beneath it.
struct HomeTabs: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            tab(model.text("会话", "Sessions"), .sessions, id: "home-tab-sessions")
            tab(model.text("主机", "Hosts"), .hosts, id: "home-tab-hosts")
        }
    }
    private func tab(_ title: String, _ value: HomeTab, id: String) -> some View {
        let active = model.homeTab == value
        return Button { withAnimation(.easeInOut(duration: 0.25)) { model.homeTab = value } } label: {
            VStack(spacing: 6) {
                Text(title).font(.system(size: 22, weight: .regular)).lineLimit(1)
                    .foregroundStyle(active ? Palette.foreground : Palette.secondary.opacity(0.7))
                Capsule().fill(active ? Palette.foreground : Color.clear).frame(width: 22, height: 3)
            }.padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? [.isSelected, .isHeader] : []).accessibilityIdentifier(id)
    }
}
