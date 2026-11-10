// Behavioral port of Roamtty Android's ShellHistoryCommands helper.
import Foundation

public enum ShellHistoryCommands {
    public static let defaultLimit = 200
    public static let maxCommandLength = 500
    public struct CommonCommands: Equatable, Sendable {
        public var commands: [String]
        public var source: String
    }
    /// The reader supplies a bounded tail and whether its first line may be incomplete.
    /// Unreadable files return nil; cancellation and transport failures may propagate.
    public static func load(readText: (String) async throws -> (String, Bool)?) async throws -> CommonCommands? {
        for path in [".bash_history", ".zsh_history"] {
            try Task.checkCancellation()
            guard let (raw, truncated) = try await readText(path) else { continue }
            let commands = rankByRecency(extractCommands(raw, zshStyle: path == ".zsh_history", skipFirstLine: truncated))
            if !commands.isEmpty { return CommonCommands(commands: commands, source: "~/" + path) }
        }
        return nil
    }
    public static func extractCommands(_ raw: String, zshStyle: Bool, skipFirstLine: Bool = false) -> [String] {
        let lines = raw.components(separatedBy: CharacterSet(charactersIn: "\n\r"))
        return lines.dropFirst(skipFirstLine ? min(1, lines.count) : 0).compactMap { line in
            var command = line.trimmingCharacters(in: .whitespaces)
            if zshStyle, let prefix = command.range(of: #"^:\s*\d+:\d+;"#, options: .regularExpression) { command = String(command[prefix.upperBound...]).trimmingCharacters(in: .whitespaces) }
            guard valid(command), zshStyle || command.range(of: #"^#\d+$"#, options: .regularExpression) == nil else { return nil }
            return command
        }
    }
    public static func rankByRecency(_ commands: [String], limit: Int = defaultLimit) -> [String] {
        var seen = Set<String>(); return Array(commands.reversed().filter { seen.insert($0).inserted }.prefix(max(0, limit)))
    }
    public static func mergeRecent(_ recent: [String], saved: [String]) -> [String] {
        var seen = Set<String>(); return Array((recent + saved).filter { seen.insert($0).inserted }.prefix(defaultLimit))
    }
    public static func executionInput(_ command: String, bracketed: Bool) throws -> String {
        guard valid(command) else { throw RoamError.invalid("Invalid history command") }
        return (bracketed ? "\u{1b}[200~" + command + "\u{1b}[201~" : command) + "\r"
    }
    public static func fuzzyFilter(_ commands: [String], query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty { return commands }
        return commands.filter { command in
            let value = command.lowercased(); if value.contains(needle) { return true }
            var remaining = value[...]
            for character in needle {
                guard let at = remaining.firstIndex(of: character) else { return false }
                remaining = remaining[remaining.index(after: at)...]
            }
            return true
        }
    }
    private static func valid(_ command: String) -> Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && command.utf16.count <= maxCommandLength &&
            !command.unicodeScalars.contains { ($0.value < 32 && $0.value != 9) || (127...159).contains($0.value) }
    }
}
