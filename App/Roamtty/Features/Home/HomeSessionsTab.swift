import SwiftUI
import RoamttyCore

/// Android `HomeSessions.kt`: every session the app holds in fixed newest-created-first order, with in-place status filter pills.
struct HomeSessionsTab: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let search: String
    /// Landscape: the header line and the filters live on `HomeCompactBar`.
    var compact = false
    var body: some View {
        // Ordered newest-created first and searched once per update; every line below reads these.
        let sessions = model.sessionsNewestFirst, matching = model.searchedSessions(sessions, search)
        VStack(spacing: 0) {
            if !compact {
                HomeListHeader(label: model.text("会话 · \(sessions.count)", "Sessions · \(sessions.count)"), addLabel: model.text("新建会话", "New session"), id: "add-session") {
                    model.sheet = .newSession
                }
            }
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
                HomeSessionsList(sessions: matching, groups: model.sessionGroups(matching), compact: compact)
            }
        }
        // While the list is on screen, dropped and restored sessions reconnect by themselves.
        .onAppear { model.beginSessionListVisit() }
        .task(id: model.homeTab == .sessions && scenePhase == .active) {
            guard model.homeTab == .sessions, scenePhase == .active else { return }
            model.beginSessionListVisit()
            while !Task.isCancelled {
                if model.path.isEmpty { model.reconnectFromList() }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}

struct HomeSessionsList: View {
    @EnvironmentObject var model: AppModel
    let sessions: [SessionRecord]
    let groups: [SessionGroupMembers]
    /// Landscape: the filters live on `HomeCompactBar`.
    var compact = false
    var body: some View {
        let only = model.filteredGroup(groups)
        let visible = model.visibleSessions(sessions, filter: only)
        GeometryReader { geometry in
            let columns = max(1, Int((geometry.size.width - 32 + 12) / (320 + 12)))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if groups.count > 1 && !compact {
                        SessionFilters(groups: groups, total: sessions.count).padding(.bottom, 10)
                    }
                    if columns == 1 {
                        VStack(spacing: 12) {
                            ForEach(visible) { record in
                                SessionRow(record: record).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 18))
                            }
                        }
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
                            ForEach(visible) { record in
                                SessionRow(record: record).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 18))
                            }
                        }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 16).reportsHomeScroll(.sessions)
            }.homeScrollSpace(.sessions).accessibilityIdentifier("home-sessions-list")
        }
    }
}

/// The filter chips: all sessions, then each group with how many it holds; the one picked shows alone.
struct SessionFilters: View {
    @EnvironmentObject var model: AppModel
    let groups: [SessionGroupMembers]
    let total: Int
    var body: some View {
        let selected = model.filteredGroup(groups)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                pill(model.text("全部", "All"), count: total, dot: nil, selected: selected == nil, id: "home-session-filter-all") { model.sessionFilter = nil }
                ForEach(groups, id: \.group) { members in
                    let value = members.group
                    pill(value.label(model.language, plainOnly: members.plainOnly), count: members.records.count, dot: value.color, selected: selected == value,
                         id: "home-session-filter-\(value.rawValue)") { model.sessionFilter = selected == value ? nil : value }
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
}
