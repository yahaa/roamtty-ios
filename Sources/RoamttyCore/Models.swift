import Foundation

public enum AuthMethod: String, Codable, CaseIterable, Sendable { case password, key, interactive }
public enum SessionMode: String, Codable, CaseIterable, Sendable { case shell, tmux }
public enum ConnectionPhase: String, Codable, Sendable {
    case connecting, verifying, authenticating, connected, disconnected, authFailed, hostKeyChanged, failed, tmuxMissing
    public var active: Bool { [.connecting, .verifying, .authenticating, .connected].contains(self) }
}
public enum RoamError: Error, LocalizedError, Equatable {
    case invalid(String), transport(String), authentication, cancelled, timeout, hostKeyChanged(String, String), rejected, sessionLimit, tmuxMissing
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .transport(let s): return s
        case .authentication: return "认证失败 / Authentication failed"
        case .cancelled: return "已取消 / Cancelled"
        case .timeout: return "连接超时 / Connection timed out"
        case .hostKeyChanged: return "服务器指纹已变化 / Host key changed"
        case .rejected: return "未信任服务器 / Host not trusted"
        case .sessionLimit: return "每台主机最多 8 个会话 / Maximum 8 sessions per host"
        case .tmuxMissing: return "主机尚未安装 tmux / tmux is not installed"
        }
    }
}

public struct Host: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var address: String
    public var port: Int
    public var username: String
    public var auth: AuthMethod
    public var mode: SessionMode
    public var system: String
    public var plugins: [String]?
    public var keyLabel: String?
    public var savePassword: Bool
    public init(id: String = UUID().uuidString, name: String = "", address: String = "", port: Int = 22,
                username: String = "", auth: AuthMethod = .password, mode: SessionMode = .tmux,
                system: String = "UNKNOWN", plugins: [String]? = nil, keyLabel: String? = nil, savePassword: Bool = false) {
        self.id = id; self.name = name; self.address = address; self.port = port; self.username = username
        self.auth = auth; self.mode = mode; self.system = system; self.plugins = plugins
        self.keyLabel = keyLabel; self.savePassword = savePassword
    }
    public var hostname: String {
        address.hasPrefix("[") && address.hasSuffix("]") ? String(address.dropFirst().dropLast()) : address
    }
    public var endpoint: String {
        var name = hostname.lowercased(); if name.hasSuffix(".") { name.removeLast() }
        return "[\(name)]:\(port)"
    }
    public func validated() throws -> Host {
        var h = self
        h.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        h.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        h.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.name.isEmpty, h.name.utf16.count <= 80 else { throw RoamError.invalid("名称需为 1–80 个字符") }
        guard !h.address.isEmpty, h.address.utf16.count <= 253,
              !h.address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) || "/\\@".unicodeScalars.contains($0) }) else { throw RoamError.invalid("请输入主机地址，不含协议、路径或空格") }
        guard (1...65535).contains(port) else { throw RoamError.invalid("端口必须为 1–65535") }
        guard !h.username.isEmpty, h.username.utf16.count <= 128,
              !h.username.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { throw RoamError.invalid("请输入有效用户名") }
        return h
    }
}

public struct Credentials: Sendable {
    public var password: Data?
    public var privateKey: Data?
    public var passphrase: String?
    public init(password: Data? = nil, privateKey: Data? = nil, passphrase: String? = nil) {
        self.password = password; self.privateKey = privateKey; self.passphrase = passphrase
    }
    public mutating func clear() {
        if let count = password?.count { password?.resetBytes(in: 0..<count) }
        if let count = privateKey?.count { privateKey?.resetBytes(in: 0..<count) }
        password = nil; privateKey = nil; passphrase = nil
    }
}

public struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var hostID: String
    public var mode: SessionMode
    public var title: String
    public var remoteName: String
    public var number: Int
    public init(id: String = UUID().uuidString, hostID: String, mode: SessionMode, title: String = "", remoteName: String? = nil, number: Int = 1) {
        self.id = id; self.hostID = hostID; self.mode = mode; self.title = String(title.prefix(80)); self.number = number
        self.remoteName = remoteName ?? "roamtty-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    }
    public var displayTitle: String { title.isEmpty ? "\(mode == .tmux ? "tmux" : "SSH") · \(number)" : title }
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
    public mutating func create(hostID: String, mode: SessionMode, title: String = "") throws -> SessionRecord {
        let same = records.filter { $0.hostID == hostID }
        guard same.count < 8 else { throw RoamError.sessionLimit }
        let record = SessionRecord(hostID: hostID, mode: mode, title: title, number: (same.map(\.number).max() ?? 0) + 1)
        records.append(record); return record
    }
    public mutating func close(_ id: String) { records.removeAll { $0.id == id && $0.mode == .shell } }
    public mutating func forget(_ id: String) { records.removeAll { $0.id == id } }
    public mutating func removeHost(_ id: String) { records.removeAll { $0.hostID == id } }
    public mutating func rename(_ id: String, title: String) {
        if let i = records.firstIndex(where: { $0.id == id }) { records[i].title = String(title.prefix(80)) }
    }
}

public struct InputQueue {
    private var items: [Data] = []
    public private(set) var generation = 0
    public init() {}
    public mutating func enqueue(_ data: Data) -> Bool {
        guard data.count <= 256 * 1024, items.count < 64 else { return false }
        items.append(data); return true
    }
    public mutating func pop() -> Data? { items.isEmpty ? nil : items.removeFirst() }
    public mutating func reset() { items.removeAll(keepingCapacity: true); generation += 1 }
}

public enum AppTheme: String, Codable, CaseIterable { case system, dark, light }
public struct AppSettings: Codable, Equatable {
    public var theme: AppTheme = .dark
    public var language = "zh-Hans"
    public var font = "JetBrainsMono-Regular"
    public var fontSize = 13.0
    public var showHiddenFiles = false
    public var toolboxPinned = false
    public var downloadBookmark: Data?
    public var fileSort: RemoteFileSort = .name
    public var fileSortDescending = false
    public var codeWrap = false
    public var codeFontSize = 13.0
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case theme, language, font, fontSize, showHiddenFiles, toolboxPinned, downloadBookmark
        case fileSort, fileSortDescending, codeWrap, codeFontSize
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        theme = AppTheme(rawValue: try values.decodeIfPresent(String.self, forKey: .theme) ?? "") ?? .dark
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "zh-Hans"
        font = try values.decodeIfPresent(String.self, forKey: .font) ?? "JetBrainsMono-Regular"
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        showHiddenFiles = try values.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? false
        toolboxPinned = try values.decodeIfPresent(Bool.self, forKey: .toolboxPinned) ?? false
        downloadBookmark = try values.decodeIfPresent(Data.self, forKey: .downloadBookmark)
        fileSort = RemoteFileSort(rawValue: try values.decodeIfPresent(String.self, forKey: .fileSort) ?? "") ?? .name
        fileSortDescending = try values.decodeIfPresent(Bool.self, forKey: .fileSortDescending) ?? false
        codeWrap = try values.decodeIfPresent(Bool.self, forKey: .codeWrap) ?? false
        codeFontSize = min(22, max(9, try values.decodeIfPresent(Double.self, forKey: .codeFontSize) ?? 13))
    }
}
