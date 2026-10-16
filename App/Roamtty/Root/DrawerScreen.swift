import SwiftUI
import RoamttyCore

/// Android `ItermuxDrawer`: brand header, Hosts with its count, the open sessions, then Settings and Help.
struct DrawerScreen: View {
    @EnvironmentObject var model: AppModel
    private var sessions: [SessionRecord] { model.sessionsByActivity }
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
                    // Hosts is a tab of the home page: a plain row like Settings, its count in a small muted chip.
                    item(model.text("主机", "Hosts"), icon: "ic_hosts", badge: "\(model.hosts.count)") { model.path = []; model.homeTab = .hosts; close() }
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
                if let badge {
                    Text(badge).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 2).background(Palette.containerHighest, in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(.leading, 16).padding(.trailing, 24).frame(height: 56)
                .foregroundStyle(selected ? Palette.adaptive(0x3D332D, 0xECE2D8) : Palette.secondary)
                .background(selected ? Palette.adaptive(0xECE4DB, 0x47413B) : Color.clear, in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).padding(.horizontal, 12)
    }
    private func sessionItem(_ record: SessionRecord) -> some View {
        let host = model.host(record.hostID)
        let phase = model.runtimes[record.id]?.phase ?? .disconnected
        return Button { model.drawer = false; model.path = []; model.openSession(record) } label: {
            HStack(spacing: 12) {
                SessionIcon(record: record, size: 32)
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
