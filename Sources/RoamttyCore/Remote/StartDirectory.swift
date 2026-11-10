// Behavioral port of Roamtty Android's StartDirectory helper.
import Foundation

public enum StartDirectory {
    public static let home = "~"
    public static func isSupported(_ value: String) -> Bool { !value.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) } }
    public static func normalize(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty || result == "~/" { return home }
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }
    public static func isHome(_ value: String) -> Bool { isSupported(value) && normalize(value) == home }
    public static func command(_ directory: String) -> String? {
        guard isSupported(directory) else { return nil }
        let directory = normalize(directory)
        if directory == home { return nil }
        return directory.hasPrefix("~/") ? "cd -- ~/" + RemoteCommands.shellQuote(String(directory.dropFirst(2))) : "cd -- " + RemoteCommands.shellQuote(directory)
    }
    public static func segments(_ directory: String) -> [(name: String, path: String)] {
        guard isSupported(directory) else { return [] }
        let directory = normalize(directory), root: String, rest: String
        if directory == home || directory.hasPrefix("~/") {
            root = home
            rest = String(directory.dropFirst())
        } else if directory.hasPrefix("/") {
            root = "/"
            rest = directory
        } else {
            return [(directory, directory)]
        }
        var path = root, result = [(root, root)]
        for name in rest.split(separator: "/") { path += (path.hasSuffix("/") ? "" : "/") + name; result.append((String(name), path)) }
        return result
    }
    public static func sanitizeRecent(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return Array(values.filter(isSupported).map(normalize).filter { $0 != home && seen.insert($0).inserted }.prefix(6))
    }
    public static func remember(recent: [String], directory: String) -> [String] {
        let safe = sanitizeRecent(recent)
        guard isSupported(directory) else { return safe }
        let directory = normalize(directory)
        return directory == home ? safe : Array(([directory] + safe.filter { $0 != directory }).prefix(6))
    }
}
