import Foundation
import RoamttyCore

/// Whether a session last chose mosh, so a reconnect uses the same transport.
enum MoshPreference {
    private static func key(_ recordID: String) -> String { "sessionMosh-" + recordID }
    static func value(_ recordID: String) -> Bool? { UserDefaults.standard.object(forKey: key(recordID)) as? Bool }
    static func set(_ value: Bool, for recordID: String) { UserDefaults.standard.set(value, forKey: key(recordID)) }
    static func forget(_ recordID: String) { UserDefaults.standard.removeObject(forKey: key(recordID)) }
}

/// What each session's agent reported last, kept across launches for the list to show until its host answers again.
@MainActor enum AgentStatusMemory {
    private static func key(_ recordID: String) -> String { "sessionAgentStatus-" + recordID }
    /// Read once per session; the list asks on every redraw.
    private static var cache: [String: AgentStatus?] = [:]
    static func value(_ recordID: String) -> AgentStatus? {
        if let cached = cache[recordID] { return cached }
        let status = UserDefaults.standard.data(forKey: key(recordID)).flatMap { try? JSONDecoder().decode(AgentStatus.self, from: $0) }
        cache[recordID] = .some(status)
        return status
    }
    static func set(_ status: AgentStatus?, for recordID: String) {
        guard cache[recordID] != .some(status) else { return }
        cache[recordID] = .some(status)
        if let status, let data = try? JSONEncoder().encode(status) { UserDefaults.standard.set(data, forKey: key(recordID)) }
        else { UserDefaults.standard.removeObject(forKey: key(recordID)) }
    }
}
