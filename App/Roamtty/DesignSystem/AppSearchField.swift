import SwiftUI

/// Android `AppSearchField`: a filled, rounded field with a leading search glyph.
struct AppSearchField: View {
    @Binding var text: String
    let placeholder: String
    var id = "search"
    var body: some View {
        HStack(spacing: 12) {
            AppIcon("ic_search").foregroundStyle(Palette.secondary)
            TextField(placeholder, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(id)
            if !text.isEmpty {
                Button { text = "" } label: { AppIcon("ic_clear", size: 18).foregroundStyle(Palette.secondary) }.accessibilityLabel("Clear")
            }
        }.padding(.horizontal, 16).frame(height: 56).background(Palette.raised, in: RoundedRectangle(cornerRadius: 12))
    }
}
