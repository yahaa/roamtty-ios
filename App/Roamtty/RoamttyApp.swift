import SwiftUI
import UIKit
import RoamttyCore

typealias Host = RoamttyCore.Host

@main struct RoamttyApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var splash = true
    init() { Diagnostics.shared.start() }
    var body: some Scene {
        WindowGroup {
            RootScreen().environmentObject(model).preferredColorScheme(model.colorScheme).tint(Palette.accent)
                .task {
                    #if DEBUG
                    await DeviceValidation.runIfRequested(model: model)
                    #endif
                }
                .onChange(of: scenePhase) { phase in if phase == .active { model.resume() } else if phase == .background { model.suspend() } }
                .overlay { if splash { StartupSplash { withAnimation(.easeOut(duration: 0.3)) { splash = false } }.transition(.opacity) } }
                .onOpenURL { url in
                    if url.isFileURL {
                        do {
                            let imported = try SharedInbox.copyIncoming(url)
                            if !model.incomingFiles.contains(imported) { model.incomingFiles.append(imported) }
                        } catch { model.error = error.localizedDescription }
                    } else if url.scheme == "roamtty" { model.resume() }
                }
        }
    }
}

/// Picks up from the system launch screen's colour: the logo pops in and plays for a moment, then fades into the app.
/// Touches pass through, so it never holds anything up.
private struct StartupSplash: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onDone: () -> Void
    @State private var shown = false
    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            RoamttyLogoArt(animated: !reduceMotion).frame(width: 72, height: 72)
                .scaleEffect(shown || reduceMotion ? 1 : 0.8).opacity(shown || reduceMotion ? 1 : 0)
        }.allowsHitTesting(false).accessibilityHidden(true)
            .task {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { shown = true }
                try? await Task.sleep(nanoseconds: reduceMotion ? 300_000_000 : 1_100_000_000)
                onDone()
            }
    }
}
