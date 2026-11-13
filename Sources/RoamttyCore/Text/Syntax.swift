// Roamtty Android code preview types and language identities, adapted from the earlier Swift port.
import Foundation

public enum TokenType: Int, CaseIterable, Sendable {
    case keyword, type, string, number, comment, function, property, variable, constant, meta
    case tag, attribute, punctuation, heading, strong, emphasis, link, inserted, deleted, error, warning, info
}

public enum LanguageMode: Sendable { case plain, code, markup, markdown }

public struct CodeLine: Equatable, Sendable {
    public var number: Int
    public var text: String
    /// Spans are UTF-16 (start, end, TokenType.rawValue) triples, suitable for NSRange.
    public var spans: [Int]
}

public struct CodeDocument: Sendable {
    public var language: CodeLanguage
    public var lines: [CodeLine]
    public var lineCount: Int
    public var maxColumns: Int
}

public struct CodeLanguage: Sendable {
    public var id: String
    public var displayName: String
    public var mode: LanguageMode
    public var lineComments: [String]
    public var words: [String: TokenType]
    public init(id: String, displayName: String, mode: LanguageMode = .code, lineComments: [String] = [], words: [String: TokenType] = [:]) {
        self.id = id
        self.displayName = displayName
        self.mode = mode
        self.lineComments = lineComments
        self.words = words
    }
}

public enum SyntaxHighlighter {
    public static let maxRowLength = 2000
    public static func highlight(_ rawText: String, _ language: CodeLanguage) -> CodeDocument {
        var expanded: [UInt16] = [], column = 0
        for unit in rawText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").utf16 {
            if unit == 9 {
                let count = 4 - column % 4
                expanded.append(contentsOf: repeatElement(32, count: count))
                column += count
            } else {
                expanded.append(unit)
                column = unit == 10 ? 0 : column + 1
            }
        }
        let lexer = PreviewLexer(expanded)
        switch language.mode {
        case .plain: break
        case .code: lexer.code(language, from: 0, to: expanded.count)
        case .markup: lexer.markup(from: 0, to: expanded.count)
        case .markdown: lexer.markdown()
        }
        return lexer.document(language)
    }
}
