import SwiftUI
import UIKit

/// The text editor's bar under the terminal: text is staged there and sent as a paste.
extension TerminalScreen {
    @ViewBuilder func editorBar(landscape: Bool) -> some View {
        let field = DraftEditor(controller: draft, placeholder: model.text("输入文本后，在这里确认", "Type text, then confirm here"), maxLines: keyboardVisible ? 2 : (landscape ? 3 : 4))
            .background(RoundedRectangle(cornerRadius: 10).stroke(Palette.secondary.opacity(0.7), lineWidth: 1))
        let collapse = Button(model.text("收起", "Hide")) { editor = false; _ = runtime.terminalView.resignFirstResponder(); hideKeyboard() }.buttonStyle(TextActionStyle())
        let enter = Button { _ = runtime.send("\r") } label: { Text(landscape ? model.text("回车 ↵", "Enter ↵") : "↵").font(landscape ? .subheadline.weight(.medium) : .system(size: 22)) }
            .buttonStyle(TextActionStyle()).disabled(!connected).accessibilityLabel(model.text("回车", "Enter")).accessibilityIdentifier("prompt-enter")
        let send = Button(model.text("发送文本", "Send text")) { _ = runtime.pasteText(draft.text) }
            .buttonStyle(FilledButtonStyle()).disabled(draft.text.isEmpty || !connected).accessibilityIdentifier("prompt-send")
        if landscape {
            HStack(spacing: 4) { field; DraftInputControls(controller: draft); collapse; enter; send }.padding(.horizontal, 4).padding(.vertical, 2)
        } else {
            VStack(spacing: 0) {
                field
                HStack(spacing: 0) { DraftInputControls(controller: draft); Spacer(); collapse.frame(minWidth: 48); enter.frame(minWidth: 48); send.frame(minWidth: 88) }
            }.padding(4)
        }
    }
    func hideKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
    /// Android stages clipboard text in the editor instead of typing it straight into the program.
    func pasteIntoEditor() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        draft.insert(text); editor = true; _ = runtime.terminalView.resignFirstResponder()
    }
}
