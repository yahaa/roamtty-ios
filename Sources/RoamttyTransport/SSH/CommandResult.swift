import Foundation

public struct CommandResult {
    public let output: Data
    public let status: Int32
    public init(output: Data, status: Int32) { self.output = output; self.status = status }
    /// The output as UTF-8, with anything else replaced: commands print text, and a stray byte must not lose it.
    public var text: String { String(decoding: output, as: UTF8.self) }
    /// `text` without the whitespace and line breaks around it.
    public var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}
