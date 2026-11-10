import Foundation

public enum SessionMode: String, Codable, CaseIterable, Sendable { case shell, tmux }

public struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var hostID: String
    public var mode: SessionMode
    public var title: String
    public var remoteName: String
    public var number: Int
    /// A tmux session that was already on the server: the app attaches to it beside its other clients and never ends it.
    public var external: Bool
    public init(id: String = UUID().uuidString, hostID: String, mode: SessionMode, title: String = "", remoteName: String? = nil, number: Int = 1, external: Bool = false) {
        self.id = id; self.hostID = hostID; self.mode = mode; self.title = String(title.prefix(80)); self.number = number
        self.remoteName = remoteName ?? "roamtty-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        self.external = external
    }
    private enum CodingKeys: String, CodingKey { case id, hostID, mode, title, remoteName, number, external }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id); hostID = try container.decode(String.self, forKey: .hostID)
        mode = try container.decode(SessionMode.self, forKey: .mode); title = try container.decode(String.self, forKey: .title)
        remoteName = try container.decode(String.self, forKey: .remoteName); number = try container.decode(Int.self, forKey: .number)
        external = try container.decodeIfPresent(Bool.self, forKey: .external) ?? false
    }
}

public struct SessionJournal: Sendable {
    public private(set) var records: [SessionRecord]
    public init(records: [SessionRecord] = []) {
        var counts: [String: Int] = [:]; var ids = Set<String>()
        self.records = records.filter {
            guard ids.insert($0.id).inserted, counts[$0.hostID, default: 0] < 8 else { return false }
            counts[$0.hostID, default: 0] += 1; return true
        }
    }
    /// `external` names a tmux session already on the server to attach instead of a new one.
    public mutating func create(hostID: String, mode: SessionMode, title: String = "", external: String? = nil) throws -> SessionRecord {
        let same = records.filter { $0.hostID == hostID }
        guard same.count < 8 else { throw RoamError.sessionLimit }
        let record = SessionRecord(hostID: hostID, mode: external == nil ? mode : .tmux, title: title, remoteName: external,
                                   number: (same.map(\.number).max() ?? 0) + 1, external: external != nil)
        records.append(record); return record
    }
    public mutating func forget(_ id: String) { records.removeAll { $0.id == id } }
    public mutating func removeHost(_ id: String) { records.removeAll { $0.hostID == id } }
}
