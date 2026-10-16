import SwiftUI
import UIKit
import RoamttyCore

typealias Host = RoamttyCore.Host

@main struct RoamttyApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
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
