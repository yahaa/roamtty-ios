import Foundation

/// UTF-16 units drawn two columns wide: Hangul Jamo, CJK, Hangul syllables, compatibility ideographs, CJK forms and
/// fullwidth forms.
private let wideUnits: [ClosedRange<UInt16>] = [0x1100...0x115f, 0x2e80...0xa4cf, 0xac00...0xd7a3, 0xf900...0xfaff, 0xfe30...0xfe4f,
                                                0xff00...0xff60, 0xffe0...0xffe6]

/// One pass over a text's UTF-16 units that marks its tokens. The scanners for code, markup and Markdown are
/// in `PreviewLexer+*.swift`.
final class PreviewLexer {
    struct Span { var start: Int; var end: Int; var type: TokenType }
    let units: [UInt16]
    let source: NSString
    var spans: [Span] = []
    init(_ units: [UInt16]) { self.units = units; source = String(decoding: units, as: UTF16.self) as NSString }
    func text(_ from: Int, _ to: Int) -> String { source.substring(with: NSRange(location: from, length: max(0, to - from))) }
    func add(_ start: Int, _ end: Int, _ type: TokenType) { if end > start { spans.append(Span(start: start, end: end, type: type)) } }
    func starts(_ value: String, at: Int, to: Int) -> Bool { let value = Array(value.utf16); return at + value.count <= to && units[at..<(at + value.count)].elementsEqual(value) }
    func find(_ value: String, from: Int, to: Int, insensitive: Bool = false) -> Int? {
        guard from < to else { return nil }
        let range = source.range(of: value, options: insensitive ? .caseInsensitive : [], range: NSRange(location: from, length: to - from))
        return range.location == NSNotFound ? nil : range.location
    }
    func lineEnd(_ from: Int, _ to: Int) -> Int { units[from..<to].firstIndex(of: 10) ?? to }
    func letter(_ c: UInt16) -> Bool { Unicode.Scalar(c).map { CharacterSet.letters.contains($0) } ?? false }
    func digit(_ c: UInt16) -> Bool { (48...57).contains(c) }
    func space(_ c: UInt16) -> Bool { Unicode.Scalar(c).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false }
    func identifier(_ c: UInt16, dash: Bool = false) -> Bool { letter(c) || digit(c) || c == 95 || (dash && c == 45) }
    func next(_ from: Int, _ to: Int) -> UInt16 { var at = from; while at < to && (units[at] == 32 || units[at] == 9) { at += 1 }; return at < to ? units[at] : 10 }
    func regex(_ pattern: String, at: Int, to: Int) -> NSTextCheckingResult? {
        RegexCache.expression(pattern)?.firstMatch(in: source as String, options: [.anchored, .withTransparentBounds], range: NSRange(location: at, length: to - at))
    }

    func scanString(_ at: Int, _ to: Int, language: String) -> Int? {
        let c = units[at]
        guard c == 34 || c == 39 || (c == 96 && ["javascript", "typescript", "go"].contains(language)) else { return nil }
        let triple = ["kotlin", "java", "python", "toml", "swift"].contains(language) && at + 2 < to && units[at + 1] == c && units[at + 2] == c
        let width = triple ? 3 : 1
        let multiline = triple || c == 96 || ["shell", "powershell", "ruby", "php"].contains(language)
        let bounded = c == 39 && ["rust", "c", "cpp", "go", "java", "kotlin", "swift"].contains(language)
        var atEnd = at + width
        while atEnd < to {
            if units[atEnd] == 92 && !(c == 39 && ["shell", "yaml", "toml"].contains(language)) { atEnd += min(2, to - atEnd); continue }
            if units[atEnd] == c && (!triple || atEnd + 2 < to && units[atEnd + 1] == c && units[atEnd + 2] == c) { return atEnd + width }
            if units[atEnd] == 10 && !multiline { return bounded ? nil : atEnd }
            if bounded && atEnd - at > (language == "rust" ? 10 : 12) { return nil }
            atEnd += 1
        }
        return bounded ? nil : to
    }

    func document(_ language: CodeLanguage) -> CodeDocument {
        var rows: [CodeLine] = [], line = 0, start = 0, spanIndex = 0, maxColumns = 0
        while start <= units.count {
            line += 1
            let end = lineEnd(start, units.count)
            var rowStart = start
            repeat {
                var rowEnd = min(end, rowStart + SyntaxHighlighter.maxRowLength)
                if rowEnd < end && rowEnd > rowStart && (0xd800...0xdbff).contains(units[rowEnd - 1]) && (0xdc00...0xdfff).contains(units[rowEnd]) { rowEnd -= 1 }
                while spanIndex < spans.count && spans[spanIndex].end <= rowStart { spanIndex += 1 }
                var at = spanIndex, rowSpans: [Int] = []
                while at < spans.count && spans[at].start < rowEnd {
                    let span = spans[at], from = max(span.start, rowStart) - rowStart, to = min(span.end, rowEnd) - rowStart
                    if to > from { rowSpans += [from, to, span.type.rawValue] }; at += 1
                }
                var columns = rowEnd - rowStart
                for unit in units[rowStart..<rowEnd] where wideUnits.contains(where: { $0.contains(unit) }) { columns += 1 }
                maxColumns = max(maxColumns, columns)
                rows.append(CodeLine(number: rowStart == start ? line : 0, text: text(rowStart, rowEnd), spans: rowSpans)); rowStart = rowEnd
            } while rowStart < end
            if end == units.count { break }; start = end + 1
        }
        return CodeDocument(language: language, lines: rows, lineCount: line, maxColumns: maxColumns)
    }
}
