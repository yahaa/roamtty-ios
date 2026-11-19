import SwiftUI
import UIKit
import RoamttyDesktopCore

/// The desktop page's rail of four buttons: along the bottom in portrait, down the trailing edge in landscape.
/// It is as thick either way: one button deep, 4pt on the picture's side, and on the screen edge's side the
/// gap the portrait rail leaves above the home indicator.
struct DesktopControlRail: View {
    @EnvironmentObject var model: AppModel
    let controller: DesktopController
    let panel: DesktopPanel
    let landscape: Bool
    /// How far the rail reaches past the safe area to the screen's edge.
    var edgeInset: CGFloat = 0
    /// Landscape: what to keep free at the screen's edge, for an island on that side.
    var edgeClearance: CGFloat = 0
    let toggle: (DesktopPanel) -> Void

    /// How deep a rail button is across the rail, the same standing up or lying down.
    private let depth: CGFloat = 54

    private struct Item: Identifiable {
        let icon: String
        let title: String
        var selected = false
        let action: () -> Void
        var id: String { icon }
    }

    private var items: [Item] {
        let items = [
            Item(icon: "ic_operations", title: model.text("操作", "Ops"), selected: panel == .operations) { toggle(.operations) },
            Item(icon: "ic_keyboard", title: model.text("键盘", "Keys"), selected: panel == .keyboard) { toggle(.keyboard) },
            // A tap is felt at once: from a Mac's full-screen app the host takes a moment to slide over.
            Item(icon: "ic_show_desktop", title: model.text("显示桌面", "Desktop")) { hostAction(DesktopProtocol.ACTION_SHOW_DESKTOP) },
            Item(icon: "ic_windows_all", title: model.text("所有窗口", "Windows")) { hostAction(DesktopProtocol.ACTION_ALL_WINDOWS) }
        ]
        // 操作 stays in the bottom corner: leftmost in portrait, lowest in landscape.
        return landscape ? items.reversed() : items
    }

    var body: some View {
        let layout = landscape ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            ForEach(items) { item in button(item) }
        }
        .padding(landscape ? .leading : .top, 4)
        // The buttons sit just above the home indicator, or as close to a bare screen edge.
        .padding(landscape ? .trailing : .bottom, max(edgeClearance, max(4, min(edgeInset, 34) - 24)))
        .background(DesktopTheme.rail.ignoresSafeArea(edges: landscape ? .trailing : .bottom))
    }

    private func button(_ item: Item) -> some View {
        Button(action: item.action) {
            VStack(spacing: 3) {
                AppIcon(item.icon, size: 22).foregroundStyle(item.selected ? DesktopTheme.accent : DesktopTheme.ink)
                Text(item.title).font(.system(size: 11)).foregroundStyle(item.selected ? DesktopTheme.accent : DesktopTheme.inkDim).lineLimit(1).fixedSize()
            }
            .frame(width: landscape ? depth : nil, height: landscape ? nil : depth)
            .frame(maxWidth: landscape ? nil : .infinity, maxHeight: landscape ? .infinity : nil)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(item.title)
    }

    private func hostAction(_ action: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        controller.input(DesktopProtocol.action(action))
    }
}
