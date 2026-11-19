import Foundation

/// Markdown-style "label (url)" links, where only the URL is underlined.
extension TerminalUrl.Reader {
    func parenthesizedLink(column: Int, row: Int) -> TerminalUrl.Match? {
        // Markdown TUIs render "label (url)" with only the URL underlined. They can wrap with explicit
        // newlines/cursor moves and indentation, which carry no terminal soft-wrap flag. Use both the enclosing
        // punctuation and the link's style, never arbitrary adjacent text.
        let tapped = self.row(row)
        var styleColumn = column
        if column > 0 && tapped.findStartOfColumn(column) == tapped.findStartOfColumn(column - 1) { styleColumn -= 1 }
        guard tapped.underlined(styleColumn) else { return nil }
        let first = max(grid.firstRow, row - TerminalUrl.maxLinkRows + 1)
        var y = row
        while y >= first {
            let line = self.row(y)
            var lastOpening = line.spaceUsed - 1
            while lastOpening >= 0 && line.text[lastOpening] != "(" { lastOpening -= 1 }
            if lastOpening >= 0 {
                for index in 0...lastOpening {
                    let cell = line.startColumns[index]
                    if line.text[index] == "(" && cell + 1 < columns && !line.underlined(cell) && line.underlined(cell + 1),
                       let match = readParenthesizedLink(startColumn: cell + 1, startRow: y, tappedColumn: column, tappedRow: row) {
                        return match
                    }
                }
            }
            y -= 1
        }
        return nil
    }

    private func readParenthesizedLink(startColumn: Int, startRow: Int, tappedColumn: Int, tappedRow: Int) -> TerminalUrl.Match? {
        var url: [Character] = []
        var cells: [TerminalLinkSpan.Cell] = []
        var tapped = false
        var completeUrl: String?
        var y = startRow
        rows: while y < grid.endRow && y - startRow < TerminalUrl.maxLinkRows {
            let line = self.row(y)
            guard var offset = linkStart(in: line, y: y, startColumn: y == startRow ? startColumn : nil) else { break }
            while offset < line.spaceUsed {
                let character = line.text[offset], cell = line.startColumns[offset], width = line.widths[offset]
                let linkStyle = line.underlined(cell)
                if character == ")" && !linkStyle {
                    completeUrl = TerminalUrl.validatedUrl(String(url))
                    break rows
                }
                if character == " " {
                    if wraps(y) { break rows }
                    if line.text[offset...].contains(where: { $0 != " " }) { break rows }
                    break
                }
                if !linkStyle { break rows }
                url.append(character)
                cells.append(TerminalLinkSpan.Cell(row: y, column: cell, width: width))
                if url.count <= 8 && !TerminalUrl.webPrefix(url) { return nil }
                if y == tappedRow && tappedColumn >= cell && tappedColumn < cell + width { tapped = true }
                if url.count > TerminalUrl.maxLinkLength { break rows }
                offset += 1
            }
            y += 1
        }
        return tapped ? TerminalUrl.Match(url: completeUrl, cells: cells) : nil
    }

    /// Where the link's text starts on row `y`: at `startColumn` on its first row; on a later row after the
    /// layout's padding, nil when that row is blank or starts a URL of its own.
    private func linkStart(in line: TerminalUrl.Row, y: Int, startColumn: Int?) -> Int? {
        if let startColumn { return line.findStartOfColumn(startColumn) }
        var offset = line.findStartOfColumn(0)
        guard !wraps(y - 1) else { return offset }
        // Layout padding is allowed only at the row boundary, not inside a URL fragment.
        while offset < line.spaceUsed && line.text[offset] == " " { offset += 1 }
        if offset == line.spaceUsed || TerminalUrl.hasWebScheme(line.text[offset...]) { return nil }
        return offset
    }
}
