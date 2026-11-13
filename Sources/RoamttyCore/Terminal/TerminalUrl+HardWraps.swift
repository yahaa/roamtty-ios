import Foundation

/// Bare URLs a TUI broke across rows itself.
extension TerminalUrl.Reader {
    /// A row's first whitespace-free token (after its indent when `fromIndent`) and its character range.
    func rowToken(_ y: Int, fromIndent: Bool) -> (token: [Character], range: Range<Int>) {
        let text = self.row(y).text
        var start = 0
        if fromIndent { while start < text.count && text[start] == " " { start += 1 } }
        var end = start
        while end < text.count && text[end] != " " { end += 1 }
        return (Array(text[start..<end]), start..<end)
    }

    func cellWidth(_ y: Int, _ range: Range<Int>) -> Int { range.reduce(0) { $0 + row(y).widths[$1] } }

    func freeCells(_ y: Int) -> Int {
        let line = row(y)
        return columns - line.widths[0..<line.contentLength].reduce(0, +)
    }

    private func lastToken(_ y: Int) -> [Character]? {
        let line = row(y)
        let text = line.text[0..<line.contentLength]
        guard !text.isEmpty else { return nil }
        if let space = text.lastIndex(of: " ") { return Array(text[(space + 1)...]) }
        return Array(text)
    }

    /// The row ends in a token that the next row's first token would not have fitted behind.
    private func continues(_ y: Int) -> Bool {
        guard y + 1 < grid.endRow, lastToken(y) != nil else { return false }
        let soft = wraps(y)
        let (next, range) = rowToken(y + 1, fromIndent: !soft)
        if next.isEmpty || TerminalUrl.hasWebScheme(next) || TerminalUrl.hasBoxDrawing(next) { return false }
        return soft || freeCells(y) <= cellWidth(y + 1, range)
    }

    /// The URL inside a token, which a label can precede without a space, as in "PR：https://…".
    private func schemeTail(_ token: [Character]?) -> [Character]? {
        guard let token else { return nil }
        var index = 0
        while index + 7 <= token.count {
            if TerminalUrl.hasWebScheme(token[index...]) { return Array(token[index...]) }
            index += 1
        }
        return nil
    }

    /// TUIs hard-wrap long bare URLs with a newline plus indentation, so no soft-wrap flag marks the join. A URL
    /// token that fills its row continues with the next row's first token; without this only the first fragment
    /// (".../pull/1" of ".../pull/135") would open.
    func hardWrappedUrl(column: Int, row: Int) -> TerminalUrl.Match? {
        var top = row
        while top >= max(grid.firstRow, row - TerminalUrl.maxLinkRows) {
            if let token = schemeTail(lastToken(top)), continues(top), let match = join(from: top, first: token, column: column, row: row) {
                return match
            }
            if top < row && !continues(top) { break }
            top -= 1
        }
        return nil
    }

    private func join(from top: Int, first: [Character], column: Int, row: Int) -> TerminalUrl.Match? {
        let topLine = self.row(top)
        let topStart = topLine.contentLength - first.count
        var url = first
        var cells = (topStart..<topLine.contentLength).map { TerminalLinkSpan.Cell(row: top, column: topLine.startColumns[$0], width: topLine.widths[$0]) }
        // Index of the tapped character in the joined URL, or -1.
        var tapped = -1
        var hardWrapped = false
        if top == row {
            let offset = topLine.findStartOfColumn(column)
            if offset >= topStart && offset < topLine.contentLength { tapped = offset - topStart }
        }
        // A link broken inside itself fills each row up to the TUI's edge. A continuation row that stops short of
        // where the first row ended is the link's end, whatever long word follows it.
        let topFree = freeCells(top)
        var y = top
        while y + 1 < grid.endRow && y - top < TerminalUrl.maxLinkRows && continues(y) && (y == top || freeCells(y) <= topFree + 1) {
            var (next, range) = rowToken(y + 1, fromIndent: !wraps(y))
            // Text glued after the link on its last row, such as "（abc）", is not part of it.
            let cut = next.firstIndex { !TerminalUrl.isUrlCharacter($0) }
            if let cut { next = Array(next[..<cut]); range = range.lowerBound..<(range.lowerBound + cut) }
            if !wraps(y) { hardWrapped = true }
            if y + 1 == row {
                let offset = self.row(row).findStartOfColumn(column)
                if range.contains(offset) { tapped = url.count + offset - range.lowerBound }
            }
            url += next
            let nextLine = self.row(y + 1)
            cells += range.map { TerminalLinkSpan.Cell(row: y + 1, column: nextLine.startColumns[$0], width: nextLine.widths[$0]) }
            if url.count > TerminalUrl.maxLinkLength { return tapped >= 0 ? TerminalUrl.Match(url: nil) : nil }
            if cut != nil || range.upperBound < self.row(y + 1).contentLength { break }
            y += 1
        }
        // Plain terminal soft wraps are read by the ordinary matcher.
        guard hardWrapped, tapped >= 0 else { return nil }
        let end = TerminalUrl.trimEnd(url, start: 0, end: url.count)
        if tapped >= end { return nil } // Trailing punctuation such as a closing parenthesis.
        guard let valid = TerminalUrl.validatedUrl(String(url[0..<end])) else { return nil }
        return TerminalUrl.Match(url: valid, cells: Array(cells.prefix(end)))
    }
}
