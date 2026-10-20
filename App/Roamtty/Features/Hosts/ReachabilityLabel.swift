import SwiftUI

struct ReachabilityLabel: View {
    @EnvironmentObject var model: AppModel
    let state: HostReachability
    private var tone: Color { switch state { case .checking: return Palette.secondary; case .online: return Palette.success; case .offline: return Palette.danger } }
    private var label: String {
        switch state {
        case .checking: return model.text("检测中", "Checking")
        case .offline: return model.text("离线", "Offline")
        case .online(let ms): return model.text("在线", "Online") + " · " + (ms < 1 ? "<1" : String(format: "%.0f", ms)) + " ms"
        }
    }
    var body: some View {
        // Android colours only the online label; offline and checking text stays secondary beside its dot.
        let online: Bool = { if case .online = state { return true }; return false }()
        HStack(spacing: 6) { Circle().fill(tone).frame(width: 8, height: 8); Text(label).font(.system(size: 12)).foregroundStyle(online ? tone : Palette.secondary) }
    }
}
