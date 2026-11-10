import Foundation

public enum AuthMethod: String, Codable, CaseIterable, Sendable { case password, key, interactive }

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
    /// Last explicit visit to this host's details, terminal, files or desktop; absent on older installs.
    public var lastUsedAt: Date?
    /// Read-only desktop probe: `yes` / `no` / `nologin` (Android `Host.desktop`).
    public var desktop: String?
    /// When the probe was stored, milliseconds since epoch; older than `DesktopProbe.cacheMs` is stale.
    public var desktopProbedAt: Int64?
    public init(id: String = UUID().uuidString, name: String = "", address: String = "", port: Int = 22,
                username: String = "", auth: AuthMethod = .password, mode: SessionMode = .tmux,
                system: String = "UNKNOWN", plugins: [String]? = nil, keyLabel: String? = nil, savePassword: Bool = false,
                desktop: String? = nil, desktopProbedAt: Int64? = nil, lastUsedAt: Date? = nil) {
        self.id = id; self.name = name; self.address = address; self.port = port; self.username = username
        self.auth = auth; self.mode = mode; self.system = system; self.plugins = plugins
        self.keyLabel = keyLabel; self.savePassword = savePassword
        self.lastUsedAt = lastUsedAt
        self.desktop = desktop; self.desktopProbedAt = desktopProbedAt
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
              !h.address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) || "/\\@".unicodeScalars.contains($0) }) else {
                  throw RoamError.invalid("请输入主机地址，不含协议、路径或空格")
              }
        guard (1...65535).contains(port) else { throw RoamError.invalid("端口必须为 1–65535") }
        guard !h.username.isEmpty, h.username.utf16.count <= 128,
              !h.username.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { throw RoamError.invalid("请输入有效用户名") }
        return h
    }
}

public extension Host {
    /// Credentials are compared separately by the credential store; display settings
    /// and the preferred mode do not change an already authenticated connection.
    func hasSameLoginIdentity(as other: Host) -> Bool {
        id == other.id && endpoint == other.endpoint && username == other.username && auth == other.auth
    }
}

extension Host {
    /// Before the probe finishes, retain the saved preference. Once known, use
    /// tmux only when this host actually provides it, matching Android.
    public var newSessionMode: SessionMode {
        guard let plugins else { return mode }
        return plugins.contains("tmux") ? .tmux : .shell
    }
}

/// Android's `requireValidHostAddress` (roamtty #277): an address typed into the host editor is a hostname, an IPv4
/// address or an IPv6 literal (bracketed or not, with an optional zone), by its syntax alone: saving a host never needs
/// DNS, a network or a server. Hosts saved before this check still load, so they can be repaired. Unlike Android it takes
/// underscores inside a name label (`build_box`).
public func isValidHostAddress(_ address: String) -> Bool {
    if address.isEmpty || address.utf16.count > 253 { return false }
    if address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) { return false }
    if address.contains(":") { return isValidIPv6Literal(address) }
    if address.contains("."), address.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) { return isValidIPv4(address) }
    let name = address.hasSuffix(".") ? String(address.dropLast()) : address
    guard !name.isEmpty else { return false }
    return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
        guard (1...63).contains(label.count), let first = label.first, let last = label.last, first.isLetter || first.isNumber, last.isLetter || last.isNumber else { return false }
        // Underscores are not in RFC 1123 hostnames, yet internal DNS, container and VM names use them.
        return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

private func isValidIPv4(_ address: String) -> Bool {
    let parts = address.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.allSatisfy { part in
        !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } && (Int(part).map { (0...255).contains($0) } ?? false)
    }
}

private func isValidIPv6Literal(_ address: String) -> Bool {
    let literal = address.hasPrefix("[") && address.hasSuffix("]") ? String(address.dropFirst().dropLast()) : address
    let scoped = literal.split(separator: "%", omittingEmptySubsequences: false)
    if scoped.count > 2 { return false }
    if scoped.count == 2 && (scoped[1].isEmpty || !scoped[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) })) { return false }
    let ip = String(scoped[0])
    let doubles = ip.components(separatedBy: "::").count - 1
    if ip.filter({ $0 == ":" }).count < 2 || ip.contains(":::") || doubles > 1 { return false }
    if (ip.hasPrefix(":") && !ip.hasPrefix("::")) || (ip.hasSuffix(":") && !ip.hasSuffix("::")) { return false }
    let groups = ip.split(separator: ":")
    var units = 0
    for (index, group) in groups.enumerated() {
        if group.contains(".") {
            guard index == groups.count - 1, ip.hasSuffix(group), isValidIPv4(String(group)) else { return false }
            units += 2
        } else {
            guard (1...4).contains(group.count), group.allSatisfy(\.isHexDigit) else { return false }
            units += 1
        }
    }
    return doubles == 1 ? units < 8 : units == 8
}
