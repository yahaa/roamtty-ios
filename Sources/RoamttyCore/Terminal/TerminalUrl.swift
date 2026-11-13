// Behavioral port of Roamtty Android's TerminalUrl.java and TerminalTextLine.java: the web URL under a tapped
// terminal cell, across soft wraps, TUI hard wraps and Markdown-style "label (url)" links.
import Foundation

/// One terminal cell as the URL finder reads it. A wide character's first cell has width 2 and its stub width 0.
public struct TerminalTextCell: Equatable, Sendable {
    public var text: String
    public var width: Int
    public var underlined: Bool
    public init(_ text: String, width: Int = 1, underlined: Bool = false) { self.text = text; self.width = width; self.underlined = underlined }
    public static let blank = TerminalTextCell(" ")
}

/// The rows the URL finder may read. Rows are numbered from `firstRow` up to (not including) `endRow`; history rows
/// may be negative. `wraps(row)` says the row soft-wraps into the next.
public protocol TerminalTextGrid {
    var columns: Int { get }
    var firstRow: Int { get }
    var endRow: Int { get }
    func cells(_ row: Int) -> [TerminalTextCell]
    func wraps(_ row: Int) -> Bool
}

/// The cells of one grid row a link covers: `start` up to `end` (exclusive), as columns.
public struct TerminalLinkSpan: Equatable, Sendable {
    public let row: Int
    public let start: Int
    public let end: Int
    public init(row: Int, start: Int, end: Int) { self.row = row; self.start = start; self.end = end }

    /// One character's cells, in reading order, merged into a span per run on a row.
    struct Cell { let row: Int; let column: Int; let width: Int }
    static func merge(_ cells: [Cell]) -> [TerminalLinkSpan] {
        var spans: [TerminalLinkSpan] = []
        for cell in cells {
            if let last = spans.last, last.row == cell.row, last.end == cell.column {
                spans[spans.count - 1] = TerminalLinkSpan(row: last.row, start: last.start, end: cell.column + cell.width)
            } else {
                spans.append(TerminalLinkSpan(row: cell.row, start: cell.column, end: cell.column + cell.width))
            }
        }
        return spans
    }
}

/// A tapped web link and the cells it covers, so a press can mark exactly those.
public struct TerminalWebLink: Equatable, Sendable {
    public let url: String
    public let spans: [TerminalLinkSpan]
}

/// Finds web URLs at terminal cell positions.
public enum TerminalUrl {
    static let maxLinkRows = 128
    static let maxLinkLength = 8192

    public static func at(_ grid: TerminalTextGrid, column: Int, row: Int) -> String? { link(grid, column: column, row: row)?.url }

    /// The URL under a cell with the cells it covers.
    public static func link(_ grid: TerminalTextGrid, column: Int, row: Int) -> TerminalWebLink? {
        guard column >= 0, column < grid.columns, row >= grid.firstRow, row < grid.endRow else { return nil }
        let reader = Reader(grid)
        if let rendered = reader.parenthesizedLink(column: column, row: row) { return rendered.link }
        if let hardWrapped = reader.hardWrappedUrl(column: column, row: row) { return hardWrapped.link }
        let line = reader.logicalLine(row)
        let offset = line.offset(atCell: line.cell(column: column, row: row))
        var next = 0
        while let (start, matchEnd) = findUrl(line.text, from: next) {
            if offset < start { return nil }
            let candidateEnd = quotedItemEnd(line.text, start: start, end: matchEnd)
            next = candidateEnd // Resume after this item, including separately quoted URLs.
            if offset >= candidateEnd { continue }
            // The logical-line reader is bounded. Never open a URL cut off by its scan limit.
            if candidateEnd == line.text.count && grid.wraps(line.lastRow) { return nil }
            let end = trimEnd(line.text, start: start, end: candidateEnd)
            if offset >= end || reader.endsAtAmbiguousWrap(line, end: candidateEnd) { return nil }
            return validatedUrl(String(line.text[start..<end])).map { TerminalWebLink(url: $0, spans: TerminalLinkSpan.merge(line.cells(start..<end))) }
        }
        return nil
    }

    // MARK: Matching

    /// `https?://` followed by characters a URL may hold: not spaces, separators, controls, `<>"\``, or the
    /// full-width punctuation that ends a URL in Chinese prose.
    static func isUrlCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if "\t\n\u{0B}\u{0C}\r ".unicodeScalars.contains(scalar) { return false }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator, .control: return false
        default: break
        }
        return !"<>\"`，。！？；：、（）【】《》“”‘’".contains(character)
    }

    static func hasWebScheme<C: Collection>(_ text: C) -> Bool where C.Element == Character {
        func starts(_ prefix: String) -> Bool {
            var index = text.startIndex
            for expected in prefix {
                guard index != text.endIndex, text[index].lowercased() == String(expected) else { return false }
                index = text.index(after: index)
            }
            return true
        }
        return starts("http://") || starts("https://")
    }

    /// The next `https?://…` match at or after `from`, as character offsets.
    static func findUrl(_ text: [Character], from: Int) -> (Int, Int)? {
        var index = max(0, from)
        while index < text.count {
            if text[index] == "h" || text[index] == "H" {
                for scheme in ["https://", "http://"] where scheme.count < text.count - index {
                    let candidate = text[index..<(index + scheme.count)]
                    guard candidate.map({ $0.lowercased() }).joined() == scheme else { continue }
                    var end = index + scheme.count
                    while end < text.count && isUrlCharacter(text[end]) { end += 1 }
                    if end > index + scheme.count { return (index, end) }
                }
            }
            index += 1
        }
        return nil
    }

    /// The whole of `url` is a web URL with an authority, as Java's `URI` parses it.
    static func validatedUrl(_ url: String) -> String? {
        let characters = Array(url)
        guard let (start, end) = findUrl(characters, from: 0), start == 0, end == characters.count else { return nil }
        let rest = url[url.range(of: "://")!.upperBound...]
        let authorityEnd = rest.firstIndex(where: { "/?#".contains($0) }) ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        guard !authority.isEmpty else { return nil }
        // Java's URI rejects these anywhere; brackets belong to an IPv6 host only.
        let illegal = Set("{}|\\^`".unicodeScalars)
        if url.unicodeScalars.contains(where: illegal.contains) { return nil }
        if rest[authorityEnd...].contains(where: { $0 == "[" || $0 == "]" }) { return nil }
        if authority.contains("[") || authority.contains("]") {
            guard authority.hasPrefix("["), let close = authority.firstIndex(of: "]"),
                  authority[authority.index(after: close)...].allSatisfy({ $0 == ":" || $0.isASCII && $0.isNumber }) else { return nil }
        }
        if rest.filter({ $0 == "#" }).count > 1 { return nil }
        let scalars = Array(url.unicodeScalars)
        for (index, scalar) in scalars.enumerated() where scalar == "%" {
            guard index + 2 < scalars.count, scalars[index + 1].properties.isASCIIHexDigit, scalars[index + 2].properties.isASCIIHexDigit else { return nil }
        }
        return url
    }

    static func quotedItemEnd(_ text: [Character], start: Int, end: Int) -> Int {
        guard start > 0, text[start - 1] == "'" else { return end }
        var index = start
        while index + 2 < end {
            // Separately quoted list items provide an explicit boundary; internal apostrophes such as Guns_N'_Roses
            // and a trailing apostrophe in rockin' remain URL characters.
            if text[index] == "'" && (text[index + 1] == "," || text[index + 1] == ";") && text[index + 2] == "'" { return index + 1 }
            index += 1
        }
        return end
    }

    static func trimEnd(_ text: [Character], start: Int, end initial: Int) -> Int {
        var end = initial
        guard end > start, ".,;:!?)]}'".contains(text[end - 1]) else { return end }
        let opening: [Character] = ["(", "[", "{"], closing: [Character] = [")", "]", "}"]
        var balance = [0, 0, 0]
        for index in start..<end {
            if let open = opening.firstIndex(of: text[index]) { balance[open] += 1 }
            if let close = closing.firstIndex(of: text[index]) { balance[close] -= 1 }
        }
        while end > start {
            let last = text[end - 1]
            if ".,;:!?".contains(last) { end -= 1 } else if let bracket = closing.firstIndex(of: last), balance[bracket] < 0 { end -= 1; balance[bracket] += 1 }
            // Apostrophes are legal URL characters. Strip only an enclosing quote paired with one immediately before
            // the scheme; punctuation inside that pair belongs to the URL.
            else if last == "'" && start > 0 && text[start - 1] == "'" { return end - 1 } else { break }
        }
        return end
    }

    static func webPrefix(_ text: [Character]) -> Bool {
        if hasWebScheme(text) { return true }
        let lower = text.map { $0.lowercased() }.joined()
        return "http://".hasPrefix(lower) || "https://".hasPrefix(lower)
    }

    static func hasBoxDrawing(_ text: [Character]) -> Bool {
        text.contains { $0.unicodeScalars.first.map { (0x2500...0x259F).contains($0.value) } ?? false }
    }

    /// A matched but incomplete rendered link must not fall back to opening its first fragment.
    struct Match {
        let url: String?
        var cells: [TerminalLinkSpan.Cell] = []
        var link: TerminalWebLink? { url.map { TerminalWebLink(url: $0, spans: TerminalLinkSpan.merge(cells)) } }
    }

    /// A row's characters with the cells each starts at, as Termux keeps them: a wide character takes one entry for
    /// its two cells, a blank cell reads as a space.
    struct Row {
        var text: [Character] = []
        var widths: [Int] = []
        var startColumns: [Int] = []
        var underlines: [Bool] = []
        init(_ cells: [TerminalTextCell], columns: Int) {
            for column in 0..<columns {
                let cell = column < cells.count ? cells[column] : .blank
                underlines.append(cell.underlined)
                if cell.width == 0 && widths.last == 2 && startColumns.last == column - 1 { continue }
                let character = cell.text.isEmpty || cell.text == "\0" ? " " : Character(cell.text)
                text.append(character); widths.append(max(1, cell.width)); startColumns.append(column)
            }
        }
        var spaceUsed: Int { text.count }
        var contentLength: Int {
            var end = text.count
            while end > 0 && text[end - 1] == " " { end -= 1 }
            return end
        }
        func findStartOfColumn(_ column: Int) -> Int {
            for index in startColumns.indices where column < startColumns[index] + widths[index] { return index }
            return text.count
        }
        func underlined(_ column: Int) -> Bool { column >= 0 && column < underlines.count && underlines[column] }
    }

    /// A bounded logical line, preserving terminal cells across soft wraps.
    struct LogicalLine {
        let text: [Character]
        let widths: [Int]
        let firstRow: Int
        let lastRow: Int
        let columns: Int
        func cell(column: Int, row: Int) -> Int { (row - firstRow) * columns + column }
        /// The grid cell of each character in `range`.
        func cells(_ range: Range<Int>) -> [TerminalLinkSpan.Cell] {
            var cell = widths[0..<range.lowerBound].reduce(0, +)
            return range.map { index in
                defer { cell += widths[index] }
                let row = min(cell / max(1, columns), lastRow - firstRow)
                return TerminalLinkSpan.Cell(row: firstRow + row, column: cell - row * columns, width: widths[index])
            }
        }
        func offset(atCell cell: Int) -> Int {
            var width = 0
            for index in text.indices {
                if width + widths[index] > cell { return index }
                width += widths[index]
            }
            return text.count
        }
    }

    final class Reader {
        let grid: TerminalTextGrid
        private var rows: [Int: Row] = [:]
        private var wrapFlags: [Int: Bool] = [:]
        init(_ grid: TerminalTextGrid) { self.grid = grid }
        var columns: Int { grid.columns }

        func row(_ y: Int) -> Row {
            if let row = rows[y] { return row }
            let row = Row(grid.cells(y), columns: columns)
            rows[y] = row
            return row
        }
        func wraps(_ y: Int) -> Bool {
            if let value = wrapFlags[y] { return value }
            let value = grid.wraps(y)
            wrapFlags[y] = value
            return value
        }

        func logicalLine(_ row: Int) -> LogicalLine {
            var first = row, last = row
            while first > grid.firstRow && row - first < 64 && wraps(first - 1) { first -= 1 }
            while last < grid.endRow - 1 && last - first < 128 && wraps(last) { last += 1 }
            var text: [Character] = [], widths: [Int] = []
            for y in first...last { let line = self.row(y); text += line.text; widths += line.widths }
            return LogicalLine(text: text, widths: widths, firstRow: first, lastRow: last, columns: columns)
        }

        func endsAtAmbiguousWrap(_ line: LogicalLine, end: Int) -> Bool {
            // A wide glyph can wrap early, leaving a blank final cell. The buffer cannot distinguish that padding
            // from a real space before prose, so neither join it nor open a partial URL.
            guard end + 1 < line.text.count, line.text[end] == " ", line.widths[end + 1] == 2 else { return false }
            let cells = line.widths[0..<end].reduce(0, +)
            return cells % line.columns == line.columns - 1
        }
    }
}

/// Where a tapped web URL opens: its percent-encoded form, so non-ASCII paths still make a valid `URL`.
public func terminalLinkTarget(_ link: String) -> URL? {
    // Existing escapes stay as they are; only characters outside ASCII are encoded.
    let encoded = link.unicodeScalars.map { scalar -> String in
        scalar.isASCII ? String(scalar) : String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
    }.joined()
    guard let url = URL(string: encoded), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
    return url
}
