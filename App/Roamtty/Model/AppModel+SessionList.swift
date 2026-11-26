import Foundation
import RoamttyCore
import RoamttyTransport

/// What the session lists show of each session, and the tmux sessions already on a host.
extension AppModel {
    // MARK: What the lists show

    /// Android `TerminalConnection.titleForDisplay`: "host · name" for a card the user named, else "host · title", or
    /// "host · 会话 N" without a title.
    func sessionDefaultTitle(_ record: SessionRecord) -> String { "\(host(record.hostID)?.name ?? "") · " + text("会话 \(record.number)", "Session \(record.number)") }
    func sessionTitle(_ record: SessionRecord) -> String {
        let shown = record.name.isEmpty ? record.title : record.name
        return shown.isEmpty ? sessionDefaultTitle(record) : "\(host(record.hostID)?.name ?? "") · \(shown)"
    }
    /// Sessions the app holds in fixed newest-created-first order so cards never jump as statuses or connections change.
    var sessionsNewestFirst: [SessionRecord] { Array(records.reversed()) }
    /// The agent a session runs: the one its hooks report, else the one it was launched for.
    func sessionAgent(_ record: SessionRecord) -> CodingAgent? {
        let runtime = runtimes[record.id]
        return CodingAgent.fromCommand(listedAgentStatus(record).status?.agent) ?? runtime?.launchedAgent ?? CodingAgent.fromTitle(record.title)
    }
    /// What the list shows of a session's agent: what it reports now (`live`), or, while the session comes back and
    /// before its host has answered, what it reported last, so opening the app or returning to it does not move every
    /// card to "其它" and back; and while its host is offline, so the card keeps its group and says what it was doing.
    /// A session that failed to connect shows nothing.
    func listedAgentStatus(_ record: SessionRecord) -> (status: AgentStatus?, live: Bool) {
        guard record.mode == .tmux else { return (nil, false) }
        let runtime = runtimes[record.id]
        if let runtime, runtime.phase == .connected, runtime.agentPolled { return (runtime.agentStatus, true) }
        guard sessionComingBack(record) || hostOffline(record) else { return (nil, false) }
        return (AgentStatusMemory.value(record.id), false)
    }
    /// A session on its way back: connecting, or dropped (the app was in the background) or restored, which the list
    /// reconnects by itself, on a host that is not offline.
    func sessionComingBack(_ record: SessionRecord) -> Bool {
        if let runtime = runtimes[record.id], runtime.phase.active { return true }
        return SessionReconnect.onOpen(sessionEnd(record)) && !hostOffline(record)
    }
    /// Why a session's terminal is down; one with no runtime came back from the journal.
    func sessionEnd(_ record: SessionRecord) -> SessionEnd? { runtimes[record.id].map { $0.phase.active ? nil : $0.end } ?? .restored }

    // MARK: Sessions already on the server

    /// The tmux sessions running on the host, most recently used first; nil when the host has no tmux.
    func tmuxSessions(on hostID: String) async throws -> [TmuxSessionInfo]? {
        let ssh = try await pool.connection(for: hostID)
        let result = try await ssh.run(RemoteCommands.tmuxSessions, timeout: 10)
        if result.status == 127 { return nil }
        guard result.status == 0 else { throw RoamError.invalid(text("无法读取 tmux 会话", "Cannot list tmux sessions")) }
        return TmuxSessionInfo.parse(result.text)
    }
}

// MARK: - Groups and search

/// A group of the session list: its records, most recently used first.
struct SessionGroupMembers {
    let group: SessionGroup
    let records: [SessionRecord]
    /// The last group is "终端" while it holds plain terminals only.
    let plainOnly: Bool
}

extension AppModel {
    /// The sessions whose title or host matches `search`.
    func searchedSessions(_ sessions: [SessionRecord], _ search: String) -> [SessionRecord] {
        guard !search.isEmpty else { return sessions }
        return sessions.filter { record in
            let host = host(record.hostID)
            return "\(sessionTitle(record)) \(host?.name ?? "") \(host?.address ?? "") \(host?.username ?? "")".localizedCaseInsensitiveContains(search)
        }
    }
    /// `sessions` grouped by what their agents are doing, empty groups left out; a session coming back stays in the
    /// group its agent was last seen in.
    func sessionGroups(_ sessions: [SessionRecord]) -> [SessionGroupMembers] {
        // Each session is placed once per update, not once per group.
        let placed = Dictionary(grouping: sessions) { sessionGroup(connected: true, status: listedAgentStatus($0).status) }
        return SessionGroup.allCases.compactMap { value in
            placed[value].map { members in
                SessionGroupMembers(group: value, records: members,
                                    plainOnly: !members.contains { listedAgentStatus($0).status != nil || sessionAgent($0) != nil })
            }
        }
    }
    /// The group `sessionFilter` names while `groups` still hold it: a filter whose group has emptied shows everything again.
    func filteredGroup(_ groups: [SessionGroupMembers]) -> SessionGroup? { groups.first { $0.group == sessionFilter }?.group }
    /// Filters `sessions` in-place for `filter` while preserving their fixed newest-created-first order.
    func visibleSessions(_ sessions: [SessionRecord], filter: SessionGroup?) -> [SessionRecord] {
        guard let filter else { return sessions }
        return sessions.filter { sessionGroup(connected: true, status: listedAgentStatus($0).status) == filter }
    }
}
