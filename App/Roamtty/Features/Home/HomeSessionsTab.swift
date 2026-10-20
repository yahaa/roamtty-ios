import SwiftUI
import RoamttyCore

/// Android `HomeSessions.kt`: every session the app holds, grouped by what its agent is doing.
struct HomeSessionsTab: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let search: String
    private func searched(_ sessions: [SessionRecord]) -> [SessionRecord] {
        guard !search.isEmpty else { return sessions }
        return sessions.filter { record in
            let host = model.host(record.hostID)
            return "\(model.sessionTitle(record)) \(host?.name ?? "") \(host?.address ?? "") \(host?.username ?? "")".localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        // Sorted and searched once per update; every line below reads these.
        let sessions = model.sessionsByActivity, matching = searched(sessions)
        VStack(spacing: 0) {
            HomeListHeader(label: model.text("会话 · \(sessions.count)", "Sessions · \(sessions.count)"), addLabel: model.text("新建会话", "New session"), id: "add-session") { model.sheet = .newSession }
            if model.hosts.isEmpty && sessions.isEmpty {
                // No host is needed first: the new-session sheet fills one in on the way.
                HomeEmptyState(logo: true, title: model.text("从第一个会话开始", "Start your first session"),
                               message: model.text("填写远端主机，运行 AI 编程工具。\n可直连，也可使用手机已有 VPN。", "Fill in a remote host to run AI coding tools.\nConnect directly or through your phone's VPN.")) {
                    AccentCapsuleButton(title: model.text("新建会话", "New session"), id: "empty-new-session") { model.sheet = .newSession }
                }.accessibilityIdentifier("home-sessions-empty")
            } else if sessions.isEmpty {
                HomeEmptyState(title: model.text("暂无会话", "No sessions"), message: model.text("选择主机，打开终端或 AI Agent。", "Pick a host, then open a terminal or an AI Agent.")) {
                    AccentCapsuleButton(title: model.text("新建会话", "New session"), id: "empty-new-session") { model.sheet = .newSession }
                }.accessibilityIdentifier("home-sessions-empty")
            } else if matching.isEmpty {
                HomeEmptyState(title: model.text("没有匹配的会话", "No matching sessions"), message: model.text("试试其他标题或主机信息", "Try another title or host")) { EmptyView() }
            } else {
                HomeSessionsList(sessions: matching)
            }
        }
        // While the list is on screen, dropped and restored sessions reconnect by themselves.
        .onAppear { model.beginSessionListVisit() }
        .task(id: model.homeTab == .sessions && scenePhase == .active) {
            guard model.homeTab == .sessions, scenePhase == .active else { return }
            model.beginSessionListVisit()
            while !Task.isCancelled {
                if model.path.isEmpty { model.reconnectFromList() }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }
}

struct HomeSessionsList: View {
    @EnvironmentObject var model: AppModel
    let sessions: [SessionRecord]
    @State private var filter: SessionGroup?
    /// A group that holds sessions, in the list's order.
    private struct Members {
        let group: SessionGroup
        let records: [SessionRecord]
        /// The last group is "终端" while it holds plain terminals only.
        let plainOnly: Bool
    }
    /// A session coming back stays in the group its agent was last seen in.
    private func group(_ record: SessionRecord) -> SessionGroup {
        sessionGroup(connected: true, status: model.listedAgentStatus(record).status)
    }
    private func plainOnly(_ members: [SessionRecord]) -> Bool {
        !members.contains { model.listedAgentStatus($0).status != nil || model.sessionAgent($0) != nil }
    }
    var body: some View {
        // Each session is placed once per update, not once per group.
        let placed = Dictionary(grouping: sessions, by: group)
        let groups = SessionGroup.allCases.compactMap { value in placed[value].map { Members(group: value, records: $0, plainOnly: plainOnly($0)) } }
        // A filter whose group has emptied shows everything again.
        let only = groups.first { $0.group == filter }?.group
        GeometryReader { geometry in
            let columns = max(1, Int((geometry.size.width - 32 + 12) / (320 + 12)))
            let joined = columns == 1
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if groups.count > 1 { filters(groups, selected: only) }
                    ForEach(groups.filter { only == nil || $0.group == only }, id: \.group) { members in
                        header(members.group, count: members.records.count, plainOnly: members.plainOnly)
                        if joined {
                            VStack(spacing: 0) {
                                ForEach(Array(members.records.enumerated()), id: \.element.id) { index, record in
                                    SessionRow(record: record, divider: index > 0)
                                }
                            }.background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 18))
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                                ForEach(members.records) { record in SessionRow(record: record).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 18)) }
                            }
                        }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }.accessibilityIdentifier("home-sessions-list")
        }
    }
    /// The chips above the groups: all sessions, then each group with how many it holds.
    private func filters(_ groups: [Members], selected: SessionGroup?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                pill(model.text("全部", "All"), count: sessions.count, dot: nil, selected: selected == nil, id: "home-session-filter-all") { filter = nil }
                ForEach(groups, id: \.group) { members in
                    let value = members.group
                    pill(value.label(model, plainOnly: members.plainOnly), count: members.records.count, dot: value.color, selected: selected == value,
                         id: "home-session-filter-\(value.rawValue)") { filter = selected == value ? nil : value }
                }
            }
        }.padding(.bottom, 2)
    }
    private func pill(_ label: String, count: Int, dot: Color?, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7).padding(.trailing, 6) }
                Text(label).font(.system(size: 14)).foregroundStyle(selected ? Palette.foreground : Palette.secondary)
                Text("\(count)").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.foreground).padding(.leading, 5)
            }.lineLimit(1).padding(.horizontal, 12).frame(height: 32)
                .background(Palette.foreground.opacity(selected ? 0.12 : 0.06), in: Capsule())
                .overlay { Capsule().stroke(selected ? Palette.foreground.opacity(0.3) : Color.clear, lineWidth: 1) }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier(id)
    }
    /// A group's line: a ring in its colour (filled for the one waiting on the user), its name and how many it holds.
    private func header(_ value: SessionGroup, count: Int, plainOnly: Bool) -> some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(value.color, lineWidth: 2).background(Circle().fill(value == .waiting ? value.color : Color.clear)).frame(width: 12, height: 12)
            Text(value.label(model, plainOnly: plainOnly)).font(.system(size: 14, weight: .medium)).foregroundStyle(value.color).padding(.leading, 8)
            Text("\(count)").font(.system(size: 14, weight: .medium)).foregroundStyle(value.color.opacity(0.8)).padding(.leading, 6)
        }.padding(.leading, 6).padding(.top, 14).padding(.bottom, 8).accessibilityIdentifier("home-session-group-\(value.rawValue)")
    }
}
