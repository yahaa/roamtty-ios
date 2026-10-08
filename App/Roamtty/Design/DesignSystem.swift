import SwiftUI
import UIKit
import RoamttyCore

enum Palette {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color { Color(uiColor: adaptiveUI(light, dark)) }
    static func adaptiveUI(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { trait in UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light) }
    }
    static let background = adaptive(0xF3F0EB, 0x252728)
    static let panel = adaptive(0xFFFDF9, 0x353632)
    static let raised = adaptive(0xEBE7E0, 0x3D3E39)
    static let foreground = adaptive(0x2B2A27, 0xF3F0EA)
    static let secondary = adaptive(0x5F5B54, 0xC7C4BD)
    static let accent = adaptive(0x9E462C, 0xEFA783)
    static let accentPanel = adaptive(0xF4DED3, 0x5B3C30)
    static let outline = adaptive(0xD8D1C8, 0x50514B)
    static let success = adaptive(0x2E7D4F, 0x7FD19B)
    static let warning = adaptive(0x9A6200, 0xF2C46D)
    static let danger = adaptive(0xB32631, 0xFFB4A8)
}
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
struct Panel<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.secondary).padding(.horizontal, 16) }
            VStack(alignment: .leading, spacing: 0) { content }.frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16))
            if let footer { Text(footer).font(.footnote).foregroundStyle(Palette.secondary).padding(.horizontal, 16) }
        }
    }
}
struct InfoRow: View {
    let title: String
    var value: String? = nil
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            if let icon { Image(systemName: icon).foregroundStyle(Palette.accent).frame(width: 24) }
            Text(title)
            Spacer(minLength: 12)
            if let value { Text(value).foregroundStyle(Palette.secondary).multilineTextAlignment(.trailing).textSelection(.enabled) }
        }.font(.subheadline).padding(16).frame(minHeight: 52)
    }
}
struct Badge: View {
    let text: String
    var body: some View { Text(text).font(.caption).foregroundStyle(Palette.secondary).padding(.horizontal, 6).padding(.vertical, 3).background(Palette.foreground.opacity(0.06), in: RoundedRectangle(cornerRadius: 6)) }
}
struct EmptyMessage: View {
    var icon = "terminal"
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44, weight: .light)).foregroundStyle(Palette.accent).padding(.bottom, 8)
            Text(title).font(.title3.weight(.semibold))
            Text(message).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
        }.padding(32).frame(maxWidth: .infinity)
    }
}
struct PhaseLabel: View {
    @EnvironmentObject var model: AppModel
    let phase: ConnectionPhase
    var tone: Color { phase == .connected ? Palette.success : phase == .disconnected ? Palette.secondary : phase.active ? Palette.warning : Palette.danger }
    var body: some View {
        HStack(spacing: 6) { Circle().fill(tone).frame(width: 8, height: 8); Text(model.phaseText(phase)).font(.caption) }.foregroundStyle(tone)
    }
}
struct RoamButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).frame(minHeight: 44)
            .foregroundStyle(primary ? Palette.accent : Palette.foreground)
            .background(primary ? Palette.accentPanel : Palette.raised, in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
extension View {
    func pageBackground() -> some View { background(Palette.background).foregroundStyle(Palette.foreground) }
    func panelDivider() -> some View { overlay(alignment: .bottom) { Divider().overlay(Palette.outline).padding(.leading, 16) } }
}
func formattedBytes(_ bytes: Int64?) -> String {
    guard let bytes else { return "—" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
}
func formattedPercent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }

/// Queue incoming shares until an existing preview, transfer, or command sheet closes.
struct ChildModalPresence: ViewModifier {
    @EnvironmentObject var model: AppModel
    @State private var registered = false
    func body(content: Content) -> some View {
        content.onAppear { if !registered { registered = true; model.childModalCount += 1 } }
            .onDisappear { if registered { registered = false; model.childModalCount = max(0, model.childModalCount - 1) } }
    }
}
