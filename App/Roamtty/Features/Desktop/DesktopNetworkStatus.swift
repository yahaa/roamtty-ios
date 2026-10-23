#if canImport(UIKit)
import SwiftUI
import RoamttyDesktopCore

/// Reserves its own space beside or below the video, including link warnings.
struct DesktopNetworkStatus: View {
    let lines: [DesktopStatsText.Line]
    let sidebar: Bool

    var body: some View {
        let layout = sidebar
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
            : AnyLayout(DesktopStatsFlowLayout())
        layout {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(color(line.tone))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop-network-status")
    }

    private func color(_ tone: DesktopStatsText.Tone) -> Color {
        switch tone {
        case .ink: return .white
        case .dim: return .white.opacity(0.65)
        case .warn: return Palette.warning
        case .bad: return Palette.danger
        }
    }
}

/// Keeps each measurement together when possible; wraps longer measurements on small screens.
private struct DesktopStatsFlowLayout: Layout {
    private let horizontalSpacing: CGFloat = 14
    private let verticalSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? 0, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (view, frame) in zip(subviews, result.frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let width = max(0, width)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(width, ideal.width), height: nil))
            if x > 0 && x + size.width > width {
                x = 0; y += rowHeight + verticalSpacing; rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), frames)
    }
}
#endif
