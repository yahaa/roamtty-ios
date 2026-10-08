import SwiftUI

struct CursorRowButtons: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runtime: SessionRuntime
    var body: some View {
        GeometryReader { geometry in
            if runtime.phase == .connected, let row = runtime.cursorRowBounds {
                let height: CGFloat = runtime.cursorRowKey == .arrows ? 64 : 32
                VStack(spacing: 0) {
                    switch runtime.cursorRowKey {
                    case .arrows:
                        cursorButton(icon: "chevron.up", label: model.text("发送上方向键", "Send Up"), id: "cursor-up") { runtime.sendCursorKey(.arrows, up: true) }
                        cursorButton(icon: "chevron.down", label: model.text("发送下方向键", "Send Down"), id: "cursor-down") { runtime.sendCursorKey(.arrows) }
                    case .enter:
                        cursorButton(icon: "return", label: model.text("回车", "Enter"), id: "cursor-enter") { runtime.sendCursorKey(.enter) }
                    case .escape:
                        cursorButton(label: model.text("发送 Esc", "Send Esc"), id: "cursor-escape") { runtime.sendCursorKey(.escape) }
                    }
                }.frame(width: 40, height: height)
                    .position(x: max(20, geometry.size.width - 20), y: min(max(row.midY, height / 2), max(height / 2, geometry.size.height - height / 2)))
                    .animation(.easeInOut(duration: 0.12), value: runtime.cursorRowKey)
            }
        }
    }
    private func cursorButton(icon: String? = nil, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon { Image(systemName: icon).font(.system(size: 13, weight: .medium)) }
                else { Text("Esc").font(.system(size: 10, weight: .medium, design: .monospaced)) }
            }.foregroundStyle(Palette.accent).frame(width: 28, height: 20)
                .background(Palette.raised.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(Palette.outline.opacity(0.5), lineWidth: 1) }
                .frame(width: 40, height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
    }
}
