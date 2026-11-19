import SwiftUI

/// Read the search environment inside `.searchable`; clearing its text alone leaves
/// native search active and can hide both the folder tools and the picker's Done button.
struct FileBrowserSearchDismissal: ViewModifier {
    @Environment(\.dismissSearch) private var dismissSearch
    let request: Int
    func body(content: Content) -> some View {
        content.onChange(of: request) { _ in dismissSearch() }
    }
}

/// The system search, in portrait only; landscape has a field in its bar.
struct FileBrowserSearchField: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    let prompt: String
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.searchable(text: $text, prompt: prompt) } else { content }
    }
}

struct FileBrowserSearchToolbarBehavior: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17.1, *) {
            content.searchPresentationToolbarBehavior(.avoidHidingContent)
        } else {
            content
        }
    }
}
