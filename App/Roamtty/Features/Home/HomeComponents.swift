import SwiftUI

/// The line above a home list: how many it holds on the left, the + that adds one on the right.
struct HomeListHeader: View {
    let label: String
    let addLabel: String
    let id: String
    let onAdd: () -> Void
    var body: some View {
        HStack {
            Text(label).font(.system(size: 15, weight: .regular)).foregroundStyle(Palette.secondary).lineLimit(1)
            Spacer()
            Button(action: onAdd) { AppIcon("ic_add", size: 24).foregroundStyle(Palette.foreground).frame(width: 48, height: 48).contentShape(Rectangle()) }
                .accessibilityLabel(addLabel).accessibilityIdentifier(id)
        }.padding(.leading, 18).padding(.trailing, 6).frame(height: 56)
    }
}

struct HomeEmptyState<Action: View>: View {
    var logo = false
    let title: String
    let message: String
    @ViewBuilder var action: Action
    var body: some View {
        VStack(spacing: 16) {
            if logo { Image("RoamttyLogo").resizable().scaledToFit().frame(width: 56, height: 56).padding(.bottom, 8).accessibilityIdentifier("empty-logo") }
            Text(title).font(.system(size: 20, weight: .semibold)).multilineTextAlignment(.center)
            Text(message).font(.system(size: 14)).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
            action
        }.padding(.horizontal, 24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
