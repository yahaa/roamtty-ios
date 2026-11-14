import SwiftUI
import RoamttyCore

/// Android `RemoteFileIcon`: a drawn folder, a coloured label badge, or a tinted glyph; links get an arrow mark.
struct RemoteFileIcon: View {
    let name: String
    var directory = false
    var permissions: UInt32 = 0
    var link = false
    var size: CGFloat = 24
    var body: some View {
        ZStack {
            switch FileIconTheme.spec(name: name, directory: directory, permissions: permissions) {
            case .folder(let color):
                Canvas { context, canvas in
                    let w = canvas.width, h = canvas.height, tint = Color(uiColor: UIColor(hex: color))
                    var tab = Path()
                    tab.move(to: CGPoint(x: w * 0.06, y: h * 0.27)); tab.addLine(to: CGPoint(x: w * 0.06, y: h * 0.24))
                    tab.addQuadCurve(to: CGPoint(x: w * 0.14, y: h * 0.16), control: CGPoint(x: w * 0.06, y: h * 0.16))
                    tab.addLine(to: CGPoint(x: w * 0.38, y: h * 0.16)); tab.addLine(to: CGPoint(x: w * 0.48, y: h * 0.27)); tab.closeSubpath()
                    context.fill(tab, with: .color(tint.opacity(0.75)))
                    context.fill(Path(roundedRect: CGRect(x: w * 0.06, y: h * 0.27, width: w * 0.88, height: h * 0.57), cornerRadius: w * 0.08), with: .color(tint))
                }
            case .badge(let label, let color, let labelColor):
                let inset = size * 0.08
                RoundedRectangle(cornerRadius: size * 0.18).fill(Color(uiColor: UIColor(hex: color))).padding(inset)
                Text(label).font(.system(size: size * (label.count == 1 ? 0.5 : label.count == 2 ? 0.4 : 0.31), weight: .bold))
                    .tracking(-size * 0.012).foregroundStyle(Color(uiColor: UIColor(hex: labelColor))).lineLimit(1).fixedSize()
            case .glyph(let kind, let color):
                AppIcon(FileIconTheme.glyphIcon(kind), size: size).foregroundStyle(Color(uiColor: UIColor(hex: color)))
            case .android(let color):
                AppIcon("ic_file_android", size: size).foregroundStyle(Color(uiColor: UIColor(hex: color)))
            }
            if link {
                let r = size * 0.21
                ZStack {
                    Circle().fill(Palette.surface).frame(width: 2 * (r + size * 0.05), height: 2 * (r + size * 0.05))
                    Circle().fill(Color(uiColor: UIColor(hex: 0x42A5F5))).frame(width: 2 * r, height: 2 * r)
                    Image(systemName: "arrow.up.right").font(.system(size: r * 1.1, weight: .bold)).foregroundStyle(.white)
                }.position(x: size - r, y: size - r)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}
