import SwiftUI
import UIKit

/// Commands must preserve literal quotes, hyphens, indentation and IME-composed text.
struct CommandDraftEditor: UIViewRepresentable {
    @Binding var text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        view.backgroundColor = .clear
        view.textColor = .label
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        view.accessibilityIdentifier = "command-draft"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.binding = $text
        if view.text != text, view.markedTextRange == nil { view.text = text }
    }
    func makeCoordinator() -> Coordinator { Coordinator(binding: $text) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var binding: Binding<String>
        init(binding: Binding<String>) { self.binding = binding }
        func textViewDidChange(_ textView: UITextView) { binding.wrappedValue = textView.text }
    }
}
