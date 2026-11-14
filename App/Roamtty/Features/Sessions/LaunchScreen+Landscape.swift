import SwiftUI
import RoamttyCore

/// Landscape: the folders on the left, and a side column with the recent folders, the agent pickers and the launch button.
extension LaunchScreen {
    /// Landscape, like the host page there: one flat bar with close and the heading; the folders take the whole height
    /// on the left, and a side column holds the recent folders, the agent pickers and the launch button.
    @ViewBuilder var landscape: some View {
        LandscapeBar(title: heading) {
            BarIconButton(icon: "ic_close", label: model.text("关闭", "Close"), id: "launch-cancel") { dismiss() }
        } trailing: { EmptyView() }
        HStack(alignment: .top, spacing: 10) {
            folderBox
            // The pickers and the button keep their place at the bottom; the recent folders scroll in what is left.
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !recent.isEmpty { sideLabel(model.text("最近", "Recent")); recentList }
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { testControls }
                        #endif
                    }
                }.frame(maxHeight: .infinity)
                if forAgent {
                    sideLabel("Agent")
                    agentPickers
                }
                launchButton
            }.frame(width: 250)
        }.padding(.horizontal, 6).padding(.bottom, 8)
    }
    func sideLabel(_ text: String) -> some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(Palette.secondary).padding(.horizontal, 4)
    }
    /// The recent folders as a list.
    var recentList: some View {
        VStack(spacing: 0) {
            ForEach(recent, id: \.self) { path in
                let selected = StartDirectory.normalize(path) == directory
                HStack(spacing: 9) {
                    AppIcon("ic_history", size: 16).foregroundStyle(Palette.secondary)
                    Text(StartDirectory.isHome(path) ? model.text("主目录", "home") : (path.split(separator: "/").last.map(String.init) ?? "/"))
                        .font(.subheadline).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    Button { recent.removeAll { $0 == path }; persistRecent() } label: { AppIcon("ic_clear", size: 16).foregroundStyle(Palette.secondary).frame(width: 32, height: 38) }
                        .buttonStyle(.plain).accessibilityLabel(model.text("移除 \(path)", "Remove \(path)"))
                }.padding(.leading, 12).padding(.trailing, 4).frame(height: 38)
                    .background(selected ? Palette.foreground.opacity(0.08) : Color.clear)
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.outline).frame(height: 0.5) }
                    .contentShape(Rectangle()).onTapGesture { navigate(path) }
                    .accessibilityElement(children: .contain).accessibilityIdentifier("launch-recent-\(path)")
            }
        }
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 16)).clipShape(RoundedRectangle(cornerRadius: 16))
    }

    #if DEBUG
    /// UI tests only: Android has no per-launch mode, mosh or typed path, but the suite needs them deterministically.
    var testControls: some View {
        VStack(spacing: 6) {
            Picker("", selection: Binding(get: { sessionMode }, set: { sessionMode = $0; sessionModeExplicit = true })) {
                Text("tmux").tag(SessionMode.tmux)
                Text("SSH").tag(SessionMode.shell)
            }.pickerStyle(.segmented).accessibilityIdentifier("launch-mode")
            HStack {
                TextField("", text: $pathDraft).font(.caption.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit {
                    navigate(pathDraft)
                }.accessibilityIdentifier("launch-directory")
                Toggle("mosh", isOn: Binding(get: { mosh }, set: { mosh = $0; moshExplicit = true })).font(.caption).fixedSize().accessibilityIdentifier("launch-mosh")
            }
            if forAgent {
                Text(AgentLaunch(agent: agent, directory: directory, mode: agentMode).agentCommand).font(.caption2.monospaced()).accessibilityIdentifier("launch-command-preview")
                Text(modeHint(agentMode)).font(.caption2).accessibilityIdentifier("launch-permission-hint")
            }
        }.padding(.horizontal, 16).padding(.top, 8).opacity(0.6)
    }
    #endif
}
