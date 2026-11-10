import SwiftUI
import UIKit
import RoamttyCore

/// A highlighted document in a text view: selectable, searchable, wrapped or scrolled sideways.
struct CodeTextView: UIViewRepresentable {
    let document: CodeDocument
    let fontName: String
    let fontSize: Double
    let wrap: Bool
    let query: String
    let match: Int
    let matches: [CodeMatch]
    let identifier: String
    /// A source line to scroll to and mark, or 0.
    var markedLine: Int = 0
    @Environment(\.colorScheme) private var scheme
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.isEditable = false; view.isSelectable = true; view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        view.accessibilityIdentifier = identifier
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        // The highlighted text is built once per document and look; a search only repaints its matches.
        let key = "\(document.lineCount)-\(document.maxColumns)-\(fontName)-\(fontSize)-\(wrap)-\(scheme)"
        if coordinator.key != key || coordinator.document != document.lines {
            coordinator.key = key
            coordinator.document = document.lines
            coordinator.sourceMatches = []; coordinator.matches = []
            let font = FontCatalog.shared.font(selection: fontName, size: fontSize)
            let output = NSMutableAttributedString()
            let digits = String(document.lineCount).count
            var rowOffsets: [Int] = []
            var marked: NSRange?
            for line in document.lines {
                let number = String(repeating: " ", count: max(0, digits - String(line.number).count)) + "\(line.number)  "
                let lineStart = output.length
                output.append(NSAttributedString(string: number, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
                let offset = output.length
                rowOffsets.append(offset)
                output.append(NSAttributedString(string: line.text + "\n", attributes: [.font: font, .foregroundColor: UIColor.label]))
                if markedLine > 0 && line.number == markedLine && marked == nil { marked = NSRange(location: lineStart, length: output.length - lineStart) }
                for index in stride(from: 0, to: line.spans.count - 2, by: 3) {
                    let start = line.spans[index], end = line.spans[index + 1]
                    guard start >= 0, end <= line.text.utf16.count, end > start else { continue }
                    output.addAttribute(.foregroundColor, value: tokenColor(TokenType(rawValue: line.spans[index + 2])), range: NSRange(location: offset + start, length: end - start))
                }
            }
            coordinator.rowOffsets = rowOffsets
            coordinator.marked = marked
            if let marked { output.addAttribute(.backgroundColor, value: Self.markColor, range: marked) }
            view.attributedText = output
            if let marked { Self.scroll(view, toMark: marked, lineHeight: font.lineHeight, attempts: 10) }
            view.textContainer.widthTracksTextView = wrap
            view.textContainer.size = CGSize(width: wrap ? max(1, view.bounds.width - 20) : max(1000, CGFloat(document.maxColumns + digits + 4) * font.pointSize * 0.65),
                height: .greatestFiniteMagnitude)
        }
        if coordinator.sourceMatches != matches {
            coordinator.sourceMatches = matches
            let storage = view.textStorage
            storage.beginEditing()
            for range in coordinator.matches where NSMaxRange(range) <= storage.length { storage.removeAttribute(.backgroundColor, range: range) }
            if let marked = coordinator.marked, NSMaxRange(marked) <= storage.length { storage.addAttribute(.backgroundColor, value: Self.markColor, range: marked) }
            coordinator.matches = []
            for found in matches where coordinator.rowOffsets.indices.contains(found.row) {
                let range = NSRange(location: coordinator.rowOffsets[found.row] + found.start, length: found.end - found.start)
                guard NSMaxRange(range) <= storage.length else { continue }
                coordinator.matches.append(range)
                storage.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.25), range: range)
            }
            storage.endEditing()
        }
        if coordinator.lastMatch != match || coordinator.lastQuery != query {
            coordinator.lastMatch = match; coordinator.lastQuery = query
            if !coordinator.matches.isEmpty { let range = coordinator.matches[match % coordinator.matches.count]; view.selectedRange = range; view.scrollRangeToVisible(range) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    private static let markColor = UIColor.tintColor.withAlphaComponent(0.16)
    /// Puts the marked line a few lines below the top, once the view has its size.
    private static func scroll(_ view: UITextView, toMark range: NSRange, lineHeight: CGFloat, attempts: Int) {
        DispatchQueue.main.async {
            guard view.bounds.height > 0 else {
                if attempts > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { scroll(view, toMark: range, lineHeight: lineHeight, attempts: attempts - 1) } }
                return
            }
            guard let start = view.position(from: view.beginningOfDocument, offset: range.location),
                  let end = view.position(from: start, offset: max(1, range.length - 1)),
                  let text = view.textRange(from: start, to: end) else { return }
            let rect = view.firstRect(for: text)
            guard rect.minY.isFinite else { return }
            let bottom = max(0, view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height)
            let y = min(bottom, max(-view.adjustedContentInset.top, rect.minY - 3 * lineHeight))
            view.setContentOffset(CGPoint(x: -view.adjustedContentInset.left, y: y), animated: false)
        }
    }
    final class Coordinator {
        var marked: NSRange?
        var key = ""; var document: [CodeLine] = []; var rowOffsets: [Int] = []
        var sourceMatches: [CodeMatch] = []; var matches: [NSRange] = []; var lastMatch = -1; var lastQuery = ""
    }
    private func tokenColor(_ token: TokenType?) -> UIColor {
        switch token {
        case .keyword, .constant: return UIColor.systemPurple
        case .string, .inserted: return UIColor.systemGreen
        case .comment: return UIColor.secondaryLabel
        case .number, .attribute: return UIColor.systemOrange
        case .function, .type, .heading: return UIColor.systemBlue
        case .error, .deleted: return UIColor.systemRed
        default: return UIColor.label
        }
    }
}
