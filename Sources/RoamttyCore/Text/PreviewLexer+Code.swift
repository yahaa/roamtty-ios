import Foundation

/// Where a scan over one stretch of code is, and what its language makes of it.
private struct CodeScan {
    let language: CodeLanguage
    let id: String
    /// Identifiers may contain a dash.
    let dash: Bool
    let blockComments: [(open: String, close: String)]
    let words: [String: TokenType]
    let caseInsensitive: Bool
    let from: Int, to: Int

    var i: Int
    var lineStart: Int
    /// Brace depth: CSS selectors are outside, properties inside.
    var depth = 0
    /// What the word after a declarator (`class`, `func`) names.
    var previous: TokenType?
    /// The last significant unit: 46 after a dot, 97 after a word, 48 after a number, 34 after a string.
    var last: UInt16 = 32

    static let declarators: [String: TokenType] = [
        "class": .type, "interface": .type, "struct": .type, "enum": .type, "trait": .type, "object": .type,
        "protocol": .type, "typealias": .type, "type": .type, "fun": .function, "function": .function, "func": .function, "fn": .function,
        "def": .function]
    private static let noBlockComments = ["python", "shell", "yaml", "toml", "ini", "makefile", "dockerfile", "bat", "log", "diff"]

    init(_ language: CodeLanguage, from: Int, to: Int) {
        self.language = language; self.from = from; self.to = to
        id = language.id
        dash = ["shell", "powershell", "css", "scss"].contains(id)
        switch id {
        case "powershell": blockComments = [("<#", "#>")]
        case "lua": blockComments = [("--[[", "]]")]
        case "ruby": blockComments = [("=begin", "=end")]
        default: blockComments = Self.noBlockComments.contains(id) ? [] : [("/*", "*/")]
        }
        words = (androidPreviewWords[id] ?? [:]).merging(language.words) { exact, _ in exact }
        caseInsensitive = ["sql", "powershell", "bat"].contains(id)
        i = from; lineStart = from
    }
}

/// Programming and configuration languages: one pass, token by token. Each `scan…` method takes the token
/// at the scan's position, if it is one of its kind, and says whether it did.
extension PreviewLexer {
    func code(_ language: CodeLanguage, from: Int, to: Int) {
        var s = CodeScan(language, from: from, to: to)
        while s.i < to {
            let c = units[s.i]
            if c == 10 { s.i += 1; s.lineStart = s.i; s.previous = nil; continue }
            if space(c) { s.i += 1; continue }
            if scanDiffLine(&s) || scanComment(&s) || scanPreprocessor(&s) || scanQuoted(&s) || scanLinkOrTimestamp(&s) { continue }
            if scanAnnotation(&s) || scanVariable(&s) || scanNumber(&s) || scanWord(&s) { continue }
            if c == 123 { s.depth += 1 }; if c == 125 { s.depth = max(0, s.depth - 1) }
            s.previous = nil; s.last = c; s.i += 1
        }
    }

    private func scanDiffLine(_ s: inout CodeScan) -> Bool {
        guard s.id == "diff" else { return false }
        let end = lineEnd(s.i, s.to), line = text(s.i, end)
        if line.hasPrefix("+++") || line.hasPrefix("---") {
            add(s.i, end, .strong)
        } else if line.hasPrefix("+") {
            add(s.i, end, .inserted)
        } else if line.hasPrefix("-") {
            add(s.i, end, .deleted)
        } else if line.hasPrefix("@@") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
            add(s.i, end, .meta)
        }
        s.i = end
        return true
    }

    private func scanComment(_ s: inout CodeScan) -> Bool {
        for (open, close) in s.blockComments where starts(open, at: s.i, to: s.to) {
            let end = find(close, from: s.i + open.utf16.count, to: s.to).map { $0 + close.utf16.count } ?? s.to
            add(s.i, end, .comment); s.i = end
            return true
        }
        for prefix in s.language.lineComments where starts(prefix, at: s.i, to: s.to) {
            // In a shell or YAML a `#` inside a word is not a comment.
            if ["shell", "yaml"].contains(s.id) && s.i != s.lineStart && !space(units[s.i - 1]) { continue }
            let end = lineEnd(s.i, s.to)
            add(s.i, end, .comment); s.i = end
            return true
        }
        return false
    }

    /// C's `#include`, `#define` and the like, at the start of a line.
    private func scanPreprocessor(_ s: inout CodeScan) -> Bool {
        guard units[s.i] == 35 && ["c", "cpp"].contains(s.id) && units[s.lineStart..<s.i].allSatisfy(space) else { return false }
        var end = s.i + 1
        while end < s.to && (letter(units[end]) || units[end] == 32) { end += 1 }
        add(s.i, end, .meta); s.i = end
        return true
    }

    /// A string; in JSON one followed by a colon is a property name.
    private func scanQuoted(_ s: inout CodeScan) -> Bool {
        guard let end = scanString(s.i, s.to, language: s.id) else { return false }
        add(s.i, end, s.id == "json" && next(end, s.to) == 58 ? .property : .string)
        s.i = end; s.previous = nil; s.last = 34
        return true
    }

    private func scanLinkOrTimestamp(_ s: inout CodeScan) -> Bool {
        let c = units[s.i]
        if c == 104 && (starts("https://", at: s.i, to: s.to) || starts("http://", at: s.i, to: s.to)), let match = regex(#"https?://[^\s\"'<>()\[\]]+"#, at: s.i, to: s.to) {
            add(s.i, NSMaxRange(match.range), .link); s.i = NSMaxRange(match.range)
            return true
        }
        if s.id == "log", digit(c), let match = regex(#"\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:[.,]\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?|\d{2}:\d{2}:\d{2}(?:[.,]\d+)?"#, at: s.i, to: s.to) {
            add(s.i, NSMaxRange(match.range), .constant); s.i = NSMaxRange(match.range)
            return true
        }
        return false
    }

    /// `@Annotation`, `@decorator` or a CSS at-rule.
    private func scanAnnotation(_ s: inout CodeScan) -> Bool {
        guard units[s.i] == 64 && ["kotlin", "java", "python", "swift", "css", "scss"].contains(s.id), s.i + 1 < s.to, identifier(units[s.i + 1]) else { return false }
        var end = s.i + 2
        while end < s.to && (identifier(units[end], dash: s.dash) || units[end] == 46) { end += 1 }
        add(s.i, end, .meta); s.i = end
        return true
    }

    /// `$name`, `${name}`, Make's `$(name)` and the shell's `$?`, `$@`…
    private func scanVariable(_ s: inout CodeScan) -> Bool {
        guard units[s.i] == 36 && ["shell", "powershell", "php", "ruby", "makefile", "scss"].contains(s.id), s.i + 1 < s.to else { return false }
        var end = s.i + 1
        if units[end] == 123 || (units[end] == 40 && s.id == "makefile") {
            end = find(units[end] == 123 ? "}" : ")", from: end + 1, to: lineEnd(s.i, s.to)).map { $0 + 1 } ?? end
        } else {
            while end < s.to && identifier(units[end]) { end += 1 }
            if end == s.i + 1 && "@#?$!*-".utf16.contains(units[end]) { end += 1 }
        }
        guard end > s.i + 1 else { return false }
        add(s.i, end, .variable); s.i = end
        return true
    }

    private func scanNumber(_ s: inout CodeScan) -> Bool {
        guard digit(units[s.i]), s.i == s.from || !identifier(units[s.i - 1], dash: s.dash),
              let match = regex(#"(?:0[xXbBoO][A-Za-z0-9_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?)[A-Za-z%]*"#, at: s.i, to: s.to) else { return false }
        add(s.i, NSMaxRange(match.range), .number)
        s.i = NSMaxRange(match.range); s.previous = nil; s.last = 48
        return true
    }

    /// A word: a keyword of the language, the name a declarator introduced, or what its surroundings make it.
    private func scanWord(_ s: inout CodeScan) -> Bool {
        guard letter(units[s.i]) || units[s.i] == 95 else { return false }
        var end = s.i + 1
        while end < s.to && identifier(units[end], dash: s.dash) { end += 1 }
        let word = text(s.i, end)
        // Python's string prefixes: r"…", b'…', f"…".
        if s.id == "python", end - s.i <= 2, word.allSatisfy({ "rRbBfFuU".contains($0) }), end < s.to, let stringEnd = scanString(end, s.to, language: s.id) {
            add(s.i, stringEnd, .string)
            s.i = stringEnd
            return true
        }
        // The path after `package` or `import` is plain.
        if ["kotlin", "java", "go"].contains(s.id) && ["package", "import"].contains(word) {
            add(s.i, end, .keyword)
            var pathEnd = end
            let stop = lineEnd(end, s.to)
            while pathEnd < stop && !s.language.lineComments.contains(where: { starts($0, at: pathEnd, to: stop) }) { pathEnd += 1 }
            s.i = pathEnd; s.previous = nil
            return true
        }
        var kind = s.words[s.caseInsensitive ? word.lowercased() : word] ?? s.previous
        if kind == nil {
            kind = inferredKind(of: word, end: end, s)
            // A Rust macro's `!` belongs to its name.
            if s.id == "rust" && end < s.to && units[end] == 33 { end += 1 }
        }
        if let kind { add(s.i, end, kind) }
        s.previous = CodeScan.declarators[word]; s.i = end; s.last = 97
        return true
    }

    /// What a word that is no keyword is, from what follows and precedes it.
    private func inferredKind(of word: String, end: Int, _ s: CodeScan) -> TokenType? {
        let nextChar = next(end, s.to)
        if s.id == "rust" && end < s.to && units[end] == 33 { return .function }
        if s.id == "css" || s.id == "scss" {
            if s.depth == 0 { return .tag }
            return nextChar == 58 ? .property : nil
        }
        if ["yaml", "toml", "ini"].contains(s.id) && (nextChar == 58 || nextChar == 61) { return .property }
        if nextChar == 40 { return .function }
        if s.last == 46 { return .property }
        if ["kotlin", "java", "python", "rust", "swift", "csharp", "typescript"].contains(s.id), word.first?.isUppercase == true {
            return word.count > 1 && word.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" } ? .constant : .type
        }
        return nil
    }
}
