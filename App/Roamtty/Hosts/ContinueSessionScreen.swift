import SwiftUI
import RoamttyCore
import RoamttyTransport

/// The tmux sessions already running on `host`; tapping one opens it, or its card when it already has one. With none
/// running it offers a fresh terminal; without tmux, the host's plugins; a failed login can be retried.
struct ContinueSessionScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let host: Host
    private enum Listing { case sessions([TmuxSessionInfo]), missing, loginFailed(String), failed }
    @State private var listing: Listing?
    @State private var busy = false
    @State private var home: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.text("继续会话 · \(host.name)", "Continue session · \(host.name)")).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { dismiss() } label: { AppIcon("ic_close").frame(width: 48, height: 48) }.accessibilityLabel(model.text("关闭", "Close")).accessibilityIdentifier("continue-close")
            }.padding(.leading, 24).padding(.trailing, 12).padding(.top, 16).padding(.bottom, 12)
            VStack(spacing: 0) {
                HStack {
                    Text(model.text("服务器上正在运行的会话", "Sessions running on the server")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button { load() } label: { AppIcon("ic_refresh", size: 20).frame(width: 40, height: 40) }.disabled(busy)
                        .accessibilityLabel(model.text("刷新", "Refresh")).accessibilityIdentifier("continue-refresh")
                }.padding(.leading, 16).padding(.trailing, 4).frame(minHeight: 48)
                Divider().overlay(Palette.outline)
                ZStack(alignment: .top) {
                    content
                    if busy && listing != nil { ProgressView().progressViewStyle(.linear).tint(Palette.accent) }
                }.frame(maxHeight: .infinity)
            }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16).padding(.bottom, 16).accessibilityIdentifier("continue-sheet")
        }.foregroundStyle(Palette.foreground).background(Palette.sheet.ignoresSafeArea())
            .task { load() }
    }
    @ViewBuilder private var content: some View {
        switch listing {
        case .none: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loginFailed(let message): centerNote(message, action: model.text("重新连接", "Reconnect")) { load() }
        case .missing:
            centerNote(model.text("\(host.name) 没有安装 tmux", "tmux is not installed on \(host.name)"), action: model.text("安装插件", "Install plugins")) {
                model.replaceSheet(with: .plugins(host))
            }
        case .failed: centerNote(model.text("无法读取 tmux 会话", "Cannot list tmux sessions"), action: model.text("重试", "Retry")) { load() }
        case .sessions(let sessions) where sessions.isEmpty:
            centerNote(model.text("\(host.name) 上没有正在运行的会话", "No sessions are running on \(host.name)"),
                       action: model.text("在 \(host.name) 新开终端", "Open a new terminal on \(host.name)")) {
                let current = model.host(host.id) ?? host
                model.launch(current, mode: current.newSessionMode, directory: StartDirectory.home, agent: nil, mosh: nil)
            }
        case .sessions(let sessions):
            TmuxSessionList(hostID: host.id, sessions: sessions, home: home, idPrefix: "continue") { model.attachExisting(host, name: $0.name, mosh: nil) }
        }
    }
    private func centerNote(_ message: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(message).font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).accessibilityIdentifier("continue-note")
            Button(action, action: perform).buttonStyle(TextActionStyle()).accessibilityIdentifier("continue-note-action")
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func load() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            // The login comes first, so a failure to sign in reads as such and offers to reconnect, not to retry a list.
            do { _ = try await model.connection(for: host.id) } catch {
                listing = .loginFailed(error.localizedDescription); return
            }
            // Only to show the sessions' folders as `~/…`; first, so the list does not change under the finger.
            if home == nil { home = await homeDirectory() }
            do { listing = try await model.tmuxSessions(on: host.id).map(Listing.sessions) ?? .missing } catch { listing = .failed }
        }
    }
    private func homeDirectory() async -> String? {
        guard let ssh = try? await model.connection(for: host.id), let script = try? RemoteFolders.script(StartDirectory.home),
              let result = try? await performInBackground({ try ssh.exec("/bin/sh -s", input: Data(script.utf8), timeout: 10) }),
              result.status == 0 else { return nil }
        return RemoteFolders.parse(String(decoding: result.output, as: UTF8.self))?.home
    }
}
