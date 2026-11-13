import Foundation

/// HTML/XML and Markdown.
extension PreviewLexer {
    func markup(from: Int, to: Int) {
        var i = from
        while i < to {
            if units[i] == 60, let end = markupConstruct(at: i, to: to) { i = end; continue }
            if units[i] == 38, let result = regex(#"&[A-Za-z0-9#]{1,10};"#, at: i, to: to) { let end = NSMaxRange(result.range); add(i, end, .constant); i = end; continue }
            i += 1
        }
    }

    /// The comment, CDATA section, declaration or tag that starts with the `<` at `i`: where it ends.
    private func markupConstruct(at i: Int, to: Int) -> Int? {
        if starts("<!--", at: i, to: to) { let end = find("-->", from: i + 4, to: to).map { $0 + 3 } ?? to; add(i, end, .comment); return end }
        if starts("<![CDATA[", at: i, to: to) { let end = find("]]>", from: i + 9, to: to).map { $0 + 3 } ?? to; add(i, end, .string); return end }
        guard i + 1 < to else { return nil }
        if units[i + 1] == 33 || units[i + 1] == 63 { let end = find(">", from: i + 2, to: to).map { $0 + 1 } ?? to; add(i, end, .meta); return end }
        if units[i + 1] == 47 || letter(units[i + 1]) { return tag(at: i, to: to) }
        return nil
    }

    /// An opening or closing tag with its attributes; a script or style element's body is scanned as code.
    private func tag(at start: Int, to: Int) -> Int {
        var i = start
        let closing = units[i + 1] == 47
        i += closing ? 2 : 1; add(start, i, .punctuation)
        let nameStart = i
        while i < to && !" \t\n/>=\"'".utf16.contains(units[i]) { i += 1 }
        let name = text(nameStart, i).lowercased(); add(nameStart, i, .tag)
        let selfClosing = attributes(&i, to: to)
        if !closing && !selfClosing && ["script", "style"].contains(name) {
            let end = find("</" + name, from: i, to: to, insensitive: true) ?? to
            code(name == "script" ? Languages.javascript : Languages.css, from: i, to: end); i = end
        }
        return i
    }

    /// A tag's attributes up to and including its `>`; true when it closes itself with `/>`.
    private func attributes(_ i: inout Int, to: Int) -> Bool {
        while i < to {
            if units[i] == 62 { add(i, i + 1, .punctuation); i += 1; return false }
            if starts("/>", at: i, to: to) { add(i, i + 2, .punctuation); i += 2; return true }
            if units[i] == 34 || units[i] == 39 {
                let quote = String(decoding: [units[i]], as: UTF16.self)
                let end = find(quote, from: i + 1, to: to).map { $0 + 1 } ?? to
                add(i, end, .string)
                i = end
                continue
            }
            if space(units[i]) || units[i] == 61 { i += 1; continue }
            let start = i
            while i < to && !" \t\n/>=\"'".utf16.contains(units[i]) { i += 1 }
            if i == start { i += 1 } else { add(start, i, .attribute) }
        }
        return false
    }

    func markdown() {
        var start = 0
        while start < units.count {
            let end = lineEnd(start, units.count)
            if let fence = regex(#" {0,3}(`{3,}|~{3,})\s*([^`\s]*)"#, at: start, to: end) {
                start = fencedBlock(fence, lineStart: start, lineEnd: end)
                continue
            }
            if regex(#" {0,3}#{1,6}(?:\s|$)"#, at: start, to: end) != nil {
                add(start, end, .heading)
            } else if regex(#" {0,3}([-*_])(?:\s*\1){2,}\s*$"#, at: start, to: end) != nil {
                add(start, end, .punctuation)
            } else if text(start, end).trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                add(start, end, .comment)
            } else {
                var inlineStart = start
                if let marker = regex(#"\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s)?"#, at: start, to: end) { inlineStart = NSMaxRange(marker.range); add(start, inlineStart, .keyword) }
                inline(from: inlineStart, to: end)
            }
            start = end + 1
        }
    }

    /// A fenced code block from its opening line: its body in the fence's language. Returns where the next line starts.
    private func fencedBlock(_ fence: NSTextCheckingResult, lineStart start: Int, lineEnd end: Int) -> Int {
        let marker = source.substring(with: fence.range(at: 1)), info = source.substring(with: fence.range(at: 2))
        add(start, end, .meta)
        let bodyStart = min(end + 1, units.count)
        var bodyEnd = units.count, closingEnd = units.count, cursor = bodyStart
        while cursor < units.count {
            let nextEnd = lineEnd(cursor, units.count)
            if text(cursor, nextEnd).trimmingCharacters(in: .whitespaces).hasPrefix(marker) { bodyEnd = cursor; closingEnd = nextEnd; break }
            cursor = nextEnd + 1
        }
        if let language = Languages.forFence(info), language.mode == .code {
            code(language, from: bodyStart, to: bodyEnd)
        } else if let language = Languages.forFence(info), language.mode == .markup {
            markup(from: bodyStart, to: bodyEnd)
        } else {
            add(bodyStart, bodyEnd, .string)
        }
        if bodyEnd < units.count { add(bodyEnd, closingEnd, .meta) }
        return closingEnd + 1
    }

    func inline(from: Int, to: Int) {
        var i = from
        while i < to {
            let c = units[i]
            if c == 96, let end = find("`", from: i + 1, to: to) { add(i, end + 1, .string); i = end + 1; continue }
            if c == 42 || c == 95 {
                let doubled = i + 1 < to && units[i + 1] == c
                let width = doubled ? 2 : 1, marker = String(decoding: Array(repeating: c, count: doubled ? 2 : 1), as: UTF16.self)
                if let end = find(marker, from: i + width, to: to), end > i + width { add(i, end + width, doubled ? .strong : .emphasis); i = end + width; continue }
            }
            if c == 91 || c == 33 && i + 1 < to && units[i + 1] == 91 {
                if let close = find("](", from: i + 1, to: to), let end = find(")", from: close + 2, to: to) { add(i, close + 1, .link); add(close + 1, end + 1, .string); i = end + 1; continue }
            }
            if c == 104, let link = regex(#"https?://[^\s)>]+"#, at: i, to: to) { add(i, NSMaxRange(link.range), .link); i = NSMaxRange(link.range); continue }
            if c == 124 { add(i, i + 1, .punctuation) }
            i += 1
        }
    }
}
