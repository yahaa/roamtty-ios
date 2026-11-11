import SwiftUI
import UIKit
import RoamttyCore

/// A card to rename, as its row saw it: the name the user gave it (empty for none), the one the list gives it by
/// itself, one more name to offer, and what tells this card from the next (its agent, host and folder).
struct SessionRenameRequest: Identifiable, Equatable {
    let id: String
    let current: String
    let automatic: String
    /// What the suggestion is ("提问", "目录") and the name it fills in; nil when it would only repeat the automatic one.
    let suggestion: (label: String, value: String)?
    let agent: CodingAgent?
    let hostName: String
    let hostID: String
    let offline: Bool
    /// "终端 · tmux" for a card without an agent.
    let kind: String
    let path: String

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.current == rhs.current && lhs.automatic == rhs.automatic }
}

/// The rename dialog on top of everything (Android `RenameSessionDialog`): the field starts with the name selected, so
/// typing replaces it; ✕ or 自动 clears it, which gives the card back its automatic name. Saves on the keyboard's 完成.
struct RenameSessionOverlay: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let request = model.renaming {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { model.renaming = nil }
                    .accessibilityHidden(true)
                // Centered in what the keyboard leaves; in landscape it scrolls rather than slipping under the keyboard.
                GeometryReader { geo in
                    ScrollView {
                        RenameSessionCard(request: request).id(request.id).frame(maxWidth: 400).padding(20)
                            .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    }
                }
            }.zIndex(90).accessibilityAddTraits(.isModal)
        }
    }
}

private struct RenameSessionCard: View {
    @EnvironmentObject var model: AppModel
    let request: SessionRenameRequest
    @State private var text = ""
    @State private var focused = false

    /// What saving keeps: nothing when the name is the automatic one, so the card follows its folder again.
    private var chosen: String { let name = sessionName(text); return name == request.automatic ? "" : name }

    var body: some View {
        let changed = chosen != request.current
        VStack(alignment: .leading, spacing: 0) {
            Text(model.text("重命名会话", "Rename session")).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home-session-rename-title")
            identity.padding(.top, 10)
            field.padding(.top, 18)
            if text.isEmpty {
                Text(model.text("留空则使用自动名称", "Leave it empty to use the automatic name")).font(.footnote).foregroundStyle(Palette.secondary)
                    .padding(.top, 6).padding(.horizontal, 4).accessibilityIdentifier("home-session-rename-help")
            }
            suggestions.padding(.top, 12)
            HStack(spacing: 10) {
                Button(model.text("取消", "Cancel")) { model.renaming = nil }.buttonStyle(RoamButtonStyle())
                    .accessibilityIdentifier("home-session-rename-cancel")
                Button(model.text("保存", "Save")) { save() }.buttonStyle(RoamButtonStyle(primary: true)).disabled(!changed).opacity(changed ? 1 : 0.45)
                    .accessibilityIdentifier("home-session-rename-save")
            }.padding(.top, 22)
        }
        .padding(24).background(Palette.raised, in: RoundedRectangle(cornerRadius: 28)).foregroundStyle(Palette.foreground)
        .accessibilityElement(children: .contain).accessibilityIdentifier("home-session-rename-dialog")
        .onAppear { text = request.current.isEmpty ? request.automatic : request.current }
    }

    /// Which card this is: its agent and host, or that it is a plain terminal, then its folder.
    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let agent = request.agent { AgentNameBadge(agent: agent) }
                if !request.hostName.isEmpty { HostChip(name: request.hostName, id: request.hostID, offline: request.offline) }
                if request.agent == nil { Text(request.kind).font(.system(size: 12)).foregroundStyle(Palette.secondary) }
            }
            if !request.path.isEmpty {
                Text(request.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.secondary.opacity(0.85))
                    .lineLimit(1).truncationMode(.middle).accessibilityIdentifier("home-session-rename-path")
            }
        }
    }

    private var field: some View {
        HStack(spacing: 4) {
            // Room under the label for the selection's grab handle.
            VStack(alignment: .leading, spacing: 7) {
                Text(model.text("名称", "Name")).font(.system(size: 12, weight: .medium)).foregroundStyle(focused ? Palette.accent : Palette.secondary)
                SelectingTextField(text: $text, focused: $focused, placeholder: request.automatic) { if chosen != request.current { save() } }
                    .frame(height: 24).accessibilityLabel(model.text("名称", "Name")).accessibilityIdentifier("home-session-rename-input")
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    AppIcon("ic_close", size: 16).foregroundStyle(Palette.secondary).frame(width: 36, height: 36).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(model.text("清空名称", "Clear name")).accessibilityIdentifier("home-session-rename-clear")
            }
        }
        .padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 8).frame(minHeight: 58)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(focused ? Palette.accent : Palette.outline, lineWidth: focused ? 1.5 : 1) }
    }

    /// One tap fills in a name: the automatic one, and the agent's last prompt or the folder's name.
    private var suggestions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chips }
            VStack(alignment: .leading, spacing: 8) { chips }
        }
    }
    @ViewBuilder private var chips: some View {
        chip(label: model.text("自动", "Auto"), value: request.automatic, fills: "", on: sessionName(text) == request.automatic || text.isEmpty)
            .accessibilityIdentifier("home-session-rename-auto")
        if let suggestion = request.suggestion {
            chip(label: suggestion.label, value: suggestion.value, fills: suggestion.value, on: sessionName(text) == sessionName(suggestion.value))
                .accessibilityIdentifier("home-session-rename-suggestion")
        }
    }
    private func chip(label: String, value: String, fills: String, on: Bool) -> some View {
        Button { text = fills } label: {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(on ? Palette.accent : Palette.secondary.opacity(0.8))
                Text(value).font(.system(size: 13)).foregroundStyle(on ? Palette.accent : Palette.foreground).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 12).frame(minHeight: 34)
            .background(on ? Palette.accentPanel : Color.clear, in: Capsule())
            .overlay { Capsule().stroke(on ? Color.clear : Palette.outline, lineWidth: 1) }
            .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel("\(label) \(value)")
    }

    private func save() {
        model.renameSession(request.id, to: chosen)
        model.renaming = nil
    }
}

/// A one-line field that takes the keyboard when it appears with all its text selected, so typing replaces it, and
/// whose 完成 key calls `onDone`. SwiftUI's `TextField` can neither select its text nor (before iOS 18) be told to.
private struct SelectingTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let onDone: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 17)
        field.textColor = UIColor(Palette.foreground)
        field.tintColor = UIColor(Palette.accent)
        field.returnKeyType = .done
        field.autocorrectionType = .no
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        // Once it is in a window: take the keyboard and select what the field holds.
        DispatchQueue.main.async {
            field.becomeFirstResponder()
            field.selectAll(nil)
        }
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor(Palette.secondary).withAlphaComponent(0.6)])
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SelectingTextField
        init(_ parent: SelectingTextField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ textField: UITextField) { parent.focused = true }
        func textFieldDidEndEditing(_ textField: UITextField) { parent.focused = false }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { parent.onDone(); return false }
    }
}
