// Port of Roamtty Android OutputHistory.kt and OutputHistoryLine.kt from 02bc6ba^
// (ab347f5 lineage), the last implementation before that UI was removed.
import Foundation

public struct HistoryRow: Equatable, Sendable {
    public let text: String
    public let columns: Int
    public let style: UInt64
    public let styles: [UInt64]?
    public let wrapped: Bool
    public init(text: String, columns: Int, style: UInt64 = 0, styles: [UInt64]? = nil, wrapped: Bool = false) {
        self.text = text
        self.columns = columns
        self.style = style
        self.styles = styles
        self.wrapped = wrapped
    }
    public func style(at column: Int) -> UInt64 {
        guard let styles, styles.indices.contains(column) else { return style }
        return styles[column]
    }
    public var cost: Int { text.utf16.count + 1 }
    public var blank: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty && style == 0 && styles == nil }
    public var key: String {
        var end = text.endIndex
        let glyphs = CharacterSet(charactersIn: "█▐▌▕▏┃║░▒▓").union(.whitespaces)
        while end > text.startIndex {
            let previous = text.index(before: end)
            if text[previous].unicodeScalars.allSatisfy({ glyphs.contains($0) }) { end = previous }
            else { break }
        }
        return String(text[..<end])
    }
}

public func similarRows(_ old: String, _ new: String) -> Bool {
    if old.hasPrefix(new) || new.hasPrefix(old) { return true }
    let oldChars = Array(old.utf16)
    let newChars = Array(new.utf16)
    let limit = min(oldChars.count, newChars.count)
    var prefix = 0
    while prefix < limit && oldChars[prefix] == newChars[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < limit - prefix && oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] { suffix += 1 }
    return 2 * (prefix + suffix) >= max(oldChars.count, newChars.count)
}

/// In-memory fullscreen output history. Rows are recorded once they scroll off or a block is replaced.
public typealias OutputHistoryLine = HistoryRow

/// Feed frozen rows on the caller's serial background queue. Returned snapshots are value copies.
/// The limits apply to recorded rows; snapshots additionally include the bounded live terminal frame.
public final class OutputHistory: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var head = 0
    public let maxChars: Int
    public let maxLines: Int
    private var lines: [HistoryRow] = []
    private var chars = 0
    private var dropped: Int64 = 0
    private var positions: [String: Int64] = [:]
    private var replay: Int64 = -1
    private var previous: [HistoryRow] = []
    private var paragraphBreak = false
    private var deferred = 0
    public init(maxChars: Int = 2 * 1024 * 1024, maxLines: Int = 50_000) {
        self.maxChars = max(0, maxChars)
        self.maxLines = max(0, maxLines)
    }

    public var recorded: [HistoryRow] { lock.lock(); defer { lock.unlock() }; return Array(lines.dropFirst(head)) }

    public func capture(_ rows: [HistoryRow]) { capture(rows, alternate: true) }

    public func captureBeforeChange(_ rows: [HistoryRow], synchronized: Bool, alternate: Bool = true) {
        if !synchronized { capture(rows, alternate: alternate) }
    }

    public func captureWhenIdle(_ rows: [HistoryRow], synchronized: Bool, alternate: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        if synchronized {
            deferred += 1
            if deferred < 16 { return }
        }
        deferred = 0
        capture(rows, alternate: alternate)
    }

    public func capture(_ rows: [HistoryRow], alternate: Bool) {
        lock.lock(); defer { lock.unlock() }
        var next = rows
        while next.last?.blank == true { next.removeLast() }
        if next.isEmpty || next == previous { return }
        if let firstOld = previous.first, let firstNew = next.first, firstOld.columns == firstNew.columns {
            recordDisappeared(next, deduplicate: alternate)
        }
        previous = next
    }

    public func snapshot() -> [HistoryRow] {
        lock.lock(); defer { lock.unlock() }
        var out = Array(lines.dropFirst(head))
        for line in previous {
            let distinct = line.key.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.reduce(0) { $0 + $1.utf16.count }
            if distinct >= 12, let position = positions[line.key], position >= dropped { continue }
            out.append(line)
        }
        return out
    }

    private func recordDisappeared(_ next: [HistoryRow], deduplicate: Bool) {
        let old = previous
        let match = matchRows(old, next)
        let visible = Set(next.map(\.key))
        var matchedNew = [Bool](repeating: false, count: next.count)
        for index in match where index >= 0 { matchedNew[index] = true }
        for index in old.indices {
            let line = old[index]
            if match[index] >= 0 { continue }
            let leaving = leaving(old, next, match, matchedNew, index)
            if leaving == 0 || (leaving == 1 && !line.key.isEmpty && visible.contains(line.key)) { continue }
            if line.key.isEmpty { paragraphBreak = true; continue }
            if paragraphBreak {
                let blank = (index > 0 && old[index - 1].key.isEmpty) ? old[index - 1] : HistoryRow(text: "", columns: 1)
                record(blank, deduplicate: false)
            }
            paragraphBreak = false
            record(line, deduplicate: deduplicate)
        }
    }

    private func leaving(_ old: [HistoryRow], _ next: [HistoryRow], _ match: [Int], _ matchedNew: [Bool], _ index: Int) -> Int {
        var above = index - 1
        while above >= 0 && match[above] < 0 { above -= 1 }
        var below = index + 1
        while below < old.count && (match[below] < 0 || old[below].key.isEmpty) { below += 1 }
        let belowShift = below < old.count ? below - match[below] : 0
        if below < old.count && belowShift > 0 {
            let expected = index - belowShift
            if expected < 0 { return 2 }
            if above >= 0 && expected <= match[above] { return 1 }
            let slot = next[expected]
            return (matchedNew[expected] || slot.key.isEmpty || !similarRows(old[index].key, slot.key)) ? 1 : 0
        }
        let counterpart: Int
        if above >= 0 { counterpart = match[above] + index - above }
        else if below < old.count { counterpart = match[below] - (below - index) }
        else { counterpart = index }
        if next.indices.contains(counterpart) && matchedNew[counterpart] && !next[counterpart].key.isEmpty { return 0 }
        if next.indices.contains(counterpart), !next[counterpart].key.isEmpty, similarRows(old[index].key, next[counterpart].key) { return 0 }
        var rows = 0
        let lower = above + 1
        if lower < below {
            for row in lower..<below where !old[row].key.isEmpty { rows += 1 }
        }
        return rows >= 3 ? 1 : 0
    }

    private func record(_ line: HistoryRow, deduplicate: Bool) {
        if line.cost > maxChars { return }
        if line.key.isEmpty && (lines.last?.key.isEmpty != false) { return }
        if deduplicate && repeatsRecorded(line.key) { return }
        replay = -1
        lines.append(line)
        chars += line.cost
        if distinctCharacters(line.key) >= 12 {
            positions[line.key] = dropped + Int64(lines.count - head - 1)
        }
        while lines.count - head > maxLines || chars > maxChars {
            let removed = lines[head]
            head += 1
            chars -= removed.cost
            if positions[removed.key] == dropped { positions.removeValue(forKey: removed.key) }
            dropped += 1
        }
        if head >= 1024 && head * 2 >= lines.count {
            lines.removeFirst(head); head = 0
        }
    }

    private func distinctCharacters(_ key: String) -> Int {
        key.unicodeScalars.reduce(0) { count, scalar in
            count + (CharacterSet.whitespacesAndNewlines.contains(scalar) ? 0 : scalar.utf16.count)
        }
    }

    private func repeatsRecorded(_ key: String) -> Bool {
        if replay >= dropped && replay < dropped + Int64(lines.count - head) {
            if lines[head + Int(replay - dropped)].key == key { replay += 1; return true }
            if distinctCharacters(key) < 12 { return true }
        }
        if distinctCharacters(key) < 12 { return false }
        guard let position = positions[key], position >= dropped else { return false }
        replay = position + 1
        return true
    }

    private func matchRows(_ old: [HistoryRow], _ next: [HistoryRow]) -> [Int] {
        var match = [Int](repeating: -1, count: old.count)
        if old.count >= 2 && old.count == next.count && (1..<old.count).allSatisfy({ old[$0].key == next[$0 - 1].key }) {
            for row in 1..<old.count { match[row] = row - 1 }
            return match
        }
        var start = 0
        while start < old.count && start < next.count && old[start].key == next[start].key {
            match[start] = start
            start += 1
        }
        var oldEnd = old.count
        var newEnd = next.count
        while oldEnd > start && newEnd > start && old[oldEnd - 1].key == next[newEnd - 1].key {
            oldEnd -= 1
            newEnd -= 1
            match[oldEnd] = newEnd
        }
        let rows = oldEnd - start
        let columns = newEnd - start
        if rows == 0 || columns == 0 { return match }
        let step = columns + 1
        var alignment = [Int](repeating: 0, count: (rows + 1) * step)
        if rows > 0 {
            var iRow = rows - 1
            while iRow >= 0 {
                var jCol = columns - 1
                while jCol >= 0 {
                    let skip = max(alignment[(iRow + 1) * step + jCol], alignment[iRow * step + jCol + 1])
                    let key = old[start + iRow].key
                    if key == next[start + jCol].key {
                        alignment[iRow * step + jCol] = max(skip, (key.isEmpty ? 1 : 2) + alignment[(iRow + 1) * step + jCol + 1])
                    } else {
                        alignment[iRow * step + jCol] = skip
                    }
                    jCol -= 1
                }
                iRow -= 1
            }
        }
        var i = 0
        var j = 0
        while i < rows && j < columns {
            let key = old[start + i].key
            let score = alignment[i * step + j]
            if key == next[start + j].key && score == (key.isEmpty ? 1 : 2) + alignment[(i + 1) * step + j + 1] {
                match[start + i] = start + j
                i += 1
                j += 1
            } else if alignment[(i + 1) * step + j] == score {
                i += 1
            } else {
                j += 1
            }
        }
        return match
    }
}
