import SwiftUI
import RoamttyDesktopCore

/// The figures over the picture, top left until a long press moves them (Android NetworkStats). Only their
/// ✕ takes a touch: anything else on them reaches the picture under them (`DesktopGestureView`, `OverlayTouch`).
/// Portrait keeps its plain lines, landscape Android's compact translucent panel. With the figures hidden, a
/// poor or recovering link still says so.
struct DesktopStatsOverlay: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var controller: DesktopController
    @ObservedObject var statsBox: DesktopStatsBox
    let showStats: Bool
    let landscape: Bool
    /// The coordinate space of the picture, in which the figures' frame is reported to `statsBox`.
    let pictureSpace: String
    /// The figures' ✕.
    let onClose: () -> Void

    private var poor: Bool { if case .connected(let poor, _) = controller.phase { return poor }; return false }
    private var recovering: Bool { if case .recovering = controller.phase { return true }; return false }

    var body: some View {
        if controller.videoSize.0 > 0 {
            if showStats {
                DesktopStatsPlacement(fx: statsBox.fx, fy: statsBox.fy, margin: landscape ? 8 : 12, box: statsBox) { panel }
            } else if let warning = DesktopStatsText.warning(poor: poor, recovering: recovering, english: model.english) {
                badge(warning)
            }
        }
    }

    private func badge(_ warning: DesktopStatsText.Line) -> some View {
        Group {
            if landscape {
                HStack(spacing: 5) {
                    Circle().fill(DesktopTheme.tone(warning.tone, android: true)).frame(width: 6, height: 6)
                    Text(warning.text).font(.system(size: 11)).foregroundStyle(DesktopTheme.ink)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.black.opacity(0.6), in: Capsule())
            } else {
                Text(warning.text).font(.system(size: 12, weight: .medium)).foregroundStyle(DesktopTheme.tone(warning.tone))
                    .padding(6).background(Color.black.opacity(0.45), in: Capsule())
            }
        }
        .accessibilityIdentifier("desktop-network-warning")
        .padding(landscape ? 8 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        let dragging = statsBox.dragging
        return ZStack(alignment: .topTrailing) {
            lines
            closeButton
        }
        .background {
            if landscape || dragging {
                shape.fill(Color.black.opacity(dragging ? 0.7 : 140 / 255.0)).padding(landscape ? 0 : -4).allowsHitTesting(false)
            }
        }
        .overlay { if dragging { shape.stroke(Color.white.opacity(0.6), lineWidth: 1.5).padding(landscape ? 0 : -4).allowsHitTesting(false) } }
        .scaleEffect(dragging ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: dragging)
        .background(GeometryReader { g in
            Color.clear.preference(key: DesktopStatsFrameKey.self, value: g.frame(in: .named(pictureSpace))).allowsHitTesting(false)
        })
        .onPreferenceChange(DesktopStatsFrameKey.self) { statsBox.frame = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desktop-stats")
    }

    private var lines: some View {
        let lines = DesktopStatsText.lines(stats: controller.stats, poor: poor, recovering: recovering, transport: .unknown, english: model.english)
        return VStack(alignment: .leading, spacing: landscape ? 0 : 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if landscape {
                    Text(line.text).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DesktopTheme.tone(line.tone, android: true)).lineLimit(1)
                        .frame(height: 14, alignment: .leading)
                } else {
                    Text(line.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(DesktopTheme.tone(line.tone)).lineLimit(1)
                }
            }
        }
        .padding(.leading, landscape ? 7 : 0).padding(.trailing, landscape ? 26 : 22).padding(.vertical, landscape ? 4 : 0)
        .allowsHitTesting(false)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(DesktopTheme.inkDim)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: landscape ? 0 : 6, y: landscape ? 0 : -6)
        .accessibilityLabel(model.text("关闭", "Close"))
        .accessibilityIdentifier("desktop-stats-close")
    }
}
