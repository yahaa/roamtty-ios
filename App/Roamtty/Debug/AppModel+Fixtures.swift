#if DEBUG
import Foundation
import UIKit
import RoamttyCore
import RoamttyTransport
import RoamttyDesktopCore

/// What UI tests and on-device checks install at launch, each only when its launch argument asks for it.
extension AppModel {
    /// UI tests pass a live host's login in the environment; it becomes a saved host.
    func installUITestFixture(_ store: AppStore) throws {
        let environment = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"), let address = environment["ROAMTTY_TEST_HOST"],
              let username = environment["ROAMTTY_TEST_USERNAME"], let password = environment["ROAMTTY_TEST_PASSWORD"] else { return }
        let fixture = Host(id: "ui-live-host", name: "UI Live Host", address: address, port: Int(environment["ROAMTTY_TEST_PORT"] ?? "22") ?? 22,
            username: username, auth: .password, mode: .tmux, savePassword: true)
        try store.saveHost(fixture); try logins.vault.save(data: Data(password.utf8), hostID: fixture.id, purpose: .password); hosts = try store.hosts()
    }

    /// An isolated, offline UI fixture: no credentials, network connection or user-store changes.
    func installDesktopControlsFixture() throws {
        guard ProcessInfo.processInfo.arguments.contains("--desktop-controls-fixture"),
              ProcessInfo.processInfo.environment["ROAMTTY_STORAGE_NAME"] == "DesktopControlsFixture" else { return }
        let environment = ProcessInfo.processInfo.environment
        if let language = environment["ROAMTTY_DESKTOP_FIXTURE_LANGUAGE"] { settings.language = language }
        if let stats = environment["ROAMTTY_DESKTOP_STATS_FIXTURE"] { settings.desktopShowStats = stats == "1" }
        // Every launch starts with the figures at the top left, wherever a drag left them last time.
        settings.desktopStatsX = 0; settings.desktopStatsY = 0
        let host = Host(id: "desktop-controls-fixture", name: "MacBook", address: "127.0.0.1", port: 9, username: "fixture")
        let session = DesktopSession(config: .init(hostName: host.name, address: host.address, clientWidth: 1280, clientHeight: 720, clientDpi: 160),
                                     manifest: try PluginManifest.bundled(),
                                     login: { .failed(message: "Offline UI fixture", connecting: false) })
        let controller = DesktopController(host: host, session: session, prefs: DesktopHostSettings(),
                                           showStats: false, english: english, onPrefs: { _ in }, onEnded: { _ in })
        controller.configureLayoutFixture(status: environment["ROAMTTY_DESKTOP_STATUS_FIXTURE"], english: english)
        desktops.put(controller)
        path = [.desktop(host.id)]
    }

    /// The live gesture UI test: a real desktop on the host in ROAMTTY_TEST_*, opened straight away,
    /// in an isolated store. The host key is accepted as is: only a disposable test host is named here.
    func installDesktopGestureFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--desktop-gesture-fixture"),
              environment["ROAMTTY_STORAGE_NAME"]?.hasPrefix("DesktopGesture") == true,
              let address = environment["ROAMTTY_TEST_HOST"], let user = environment["ROAMTTY_TEST_USERNAME"],
              let password = environment["ROAMTTY_TEST_PASSWORD"] else { return }
        let port = Int(environment["ROAMTTY_TEST_PORT"] ?? "22") ?? 22
        settings.desktopShowStats = true
        let host = Host(id: "desktop-gesture-fixture", name: "Gesture test host", address: address, port: port, username: user, auth: .password)
        var config = desktopConfig(for: host)
        config.audio = false
        let session = DesktopSession(config: config, manifest: try desktopManifest(), login: {
            do {
                let pins = try AppStore(url: URL(fileURLWithPath: ":memory:"))
                let ssh = SSHConnection(host: host, credentials: Credentials(password: Data(password.utf8)), pinStore: pins) { prompt in
                    if case .verifyHost = prompt { return ["verified"] }
                    return nil
                }
                try ssh.connect()
                return .host(SSHDesktopHost(connection: ssh))
            } catch { return .failed(message: error.localizedDescription, connecting: true) }
        })
        var prefs = DesktopHostSettings()
        prefs.pointerMode = environment["ROAMTTY_DESKTOP_POINTER"] == "mouse" ? "mouse" : "touch"
        prefs.audio = false
        let controller = DesktopController(host: host, session: session, prefs: prefs, showStats: true, english: english,
                                           onPrefs: { _ in }, onEnded: { _ in })
        desktops.put(controller)
        controller.start()
        path = [.desktop(host.id)]
    }

    /// Isolated offline UI fixture for Terminal `agy /voice` UI verification and simulator screenshots.
    func installVoiceUIFixture(_ store: AppStore) throws {
        guard ProcessInfo.processInfo.arguments.contains("--voice-ui-fixture"),
              ProcessInfo.processInfo.environment["ROAMTTY_STORAGE_NAME"] == "VoiceUIFixture" else { return }
        let env = ProcessInfo.processInfo.environment
        if let language = env["ROAMTTY_VOICE_FIXTURE_LANGUAGE"] { settings.language = language }
        settings.theme = .dark
        settings.toolboxPinned = false
        var host = Host(id: "voice-ui-host", name: "mac-studio", address: "127.0.0.1", port: 22, username: "zihua", auth: .password, mode: .tmux)
        host.system = "MACOS"
        host.desktop = "yes"
        host.desktopProbedAt = Int64(Date().timeIntervalSince1970 * 1000)
        try store.saveHost(host)
        hosts = try store.hosts()
        desktopPluginInstalled[host.id] = env["ROAMTTY_VOICE_FIXTURE_PLUGIN_MISSING"] != "1"

        let record = SessionRecord(id: "voice-ui-session", hostID: host.id, mode: .tmux, title: "Antigravity · roamtty", external: false)
        records = [record]
        let runtime = SessionRuntime(record: record, host: host)
        runtime.launchedAgent = .agy
        runtime.phase = .connected
        runtime.transportName = "SSH"
        runtime.agentUsage = AgentSessionUsage(agent: .agy, model: "gemini-2.5-pro", contextUsed: 72_000, contextLimit: 200_000)
        let banner = [
            "", "",
            "\u{1b}[90mAntigravity CLI v1.5.18 · Gemini 2.5 Pro · ~/work/roamtty\u{1b}[0m",
            "",
            "\u{1b}[33m›\u{1b}[0m 帮我看下 TerminalDock 里加电话按钮的改动点",
            "",
            "已定位 iOS \u{1b}[36mTerminalScreen+Dock.swift\u{1b}[0m 与 \u{1b}[36mGhostArt.swift\u{1b}[0m。",
            "\u{1b}[90m· 新增 voiceDockButton，仅在 agy 会话显示\u{1b}[0m",
            "\u{1b}[90m· 通话中复用 ToolboxPetArt，左手键盘换弯曲电话听筒\u{1b}[0m",
            "\u{1b}[32m✓ 0 errors · ready\u{1b}[0m",
            "",
            "\u{1b}[90m────────────────────────────────────────────\u{1b}[0m",
            "\u{1b}[33m>\u{1b}[0m "
        ].joined(separator: "\r\n")
        runtime.terminalView.feed(text: banner)
        let state = env["ROAMTTY_VOICE_FIXTURE_STATE"]
        let popover = env["ROAMTTY_VOICE_FIXTURE_POPOVER"] == "1"
        let unstable = env["ROAMTTY_VOICE_FIXTURE_UNSTABLE"] == "1"
        runtime.voice.configureFixture(state: state, mode: .live, popover: popover, networkUnstable: unstable)
        runtimes[record.id] = runtime
        path = [.terminal(record.id)]
    }
}
#endif
