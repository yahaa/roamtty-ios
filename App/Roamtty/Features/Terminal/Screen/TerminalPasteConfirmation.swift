import SwiftUI
import RoamttyCore

/// Asks before a multi-line paste goes to a program that has not enabled bracketed paste.
struct TerminalPasteConfirmation: ViewModifier {
    @EnvironmentObject var model: AppModel
    @ObservedObject var runtime: SessionRuntime
    var enabled = true
    var onSent: () -> Void = { }
    func body(content: Content) -> some View {
        content.alert(model.text("发送多行文本？", "Send multiple lines?"),
            isPresented: Binding(get: { enabled && runtime.pendingPaste != nil }, set: { if !$0 { runtime.pendingPaste = nil } }),
            presenting: runtime.pendingPaste) { text in
            Button(model.text("发送", "Send")) {
                runtime.pendingPaste = nil
                if runtime.pasteText(text, confirmed: true) { onSent() }
            }.disabled(runtime.phase != .connected).accessibilityIdentifier("terminal-paste-send")
            Button(model.text("取消", "Cancel"), role: .cancel) { runtime.pendingPaste = nil }.accessibilityIdentifier("terminal-paste-cancel")
        } message: { _ in
            Text(model.text("远端尚未启用 bracketed paste。文本中的换行可能立即执行命令，请确认当前程序能安全接收多行输入。",
                "The remote program has not enabled bracketed paste. Newlines may run commands immediately. Confirm that it can safely receive multiple lines."))
        }
    }
}

/// A file a path tapped in the terminal names, and the line it points at (0 for none).
struct TappedTerminalFile: Identifiable {
    let path: String
    let line: Int
    var id: String { "\(path):\(line)" }
}
