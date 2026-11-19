import SwiftUI
import RoamttyDesktopCore

/// The desktop page's own dark colours (Android `DesktopPage`): the picture is always shown on black, whatever
/// the app's theme.
enum DesktopTheme {
    static let panel = Color(red: 28/255, green: 28/255, blue: 30/255)
    static let rail = Color(red: 20/255, green: 20/255, blue: 22/255)
    static let ink = Color(red: 242/255, green: 242/255, blue: 247/255)
    static let inkDim = Color(red: 154/255, green: 154/255, blue: 161/255)
    static let accent = Color(red: 1, green: 159/255, blue: 10/255)
    /// The fill of a button or a choice on a panel.
    static let control = Color.white.opacity(20/255)

    static func tone(_ tone: DesktopStatsText.Tone, android: Bool = false) -> Color {
        switch tone {
        case .ink: return android ? ink : .white
        case .dim: return android ? inkDim : .white.opacity(0.65)
        case .warn: return Palette.warning
        case .bad: return Palette.danger
        }
    }
}
