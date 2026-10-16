import UIKit
import SwiftUI
import SwiftTerm
import RoamttyCore

struct NativeTerminal: UIViewRepresentable {
    @ObservedObject var runtime: SessionRuntime
    @ObservedObject private var fonts = FontCatalog.shared
    var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    func makeUIView(context: Context) -> TerminalView { runtime.configure(settings: settings, scheme: scheme); return runtime.terminalView }
    func updateUIView(_ view: TerminalView, context: Context) { runtime.configure(settings: settings, scheme: scheme) }
    static func dismantleUIView(_ view: TerminalView, coordinator: ()) { view.resignFirstResponder() }
}

/// The terminal surface: steady cursors like Android's, VoiceOver text, and hooks the runtime needs from the view.
@MainActor final class AccessibleTerminalView: TerminalView {
    private var terminalReady = false
    private var cursorShape: CursorStyle = .steadyBlock
    var viewportChanged: (() -> Void)?
    var pasteStarted: ((Bool) -> Void)?
    var pasteFinished: (() -> Void)?
    override func paste(_ sender: Any?) {
        pasteStarted?(getTerminal().bracketedPasteMode)
        super.paste(sender)
        pasteFinished?()
    }
    override var contentOffset: CGPoint { didSet { viewportChanged?() } }
    override func layoutSubviews() {
        super.layoutSubviews()
        if terminalReady {
            let terminal = getTerminal()
            terminal.setCursorStyle(cursorShape)
        }
        viewportChanged?()
    }
    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        // Android's terminal preserves DECSCUSR shapes without enabling blinking.
        // Apply that same policy after remote style changes and SwiftTerm font resets.
        cursorShape = Self.steadyCursor(newStyle)
        super.cursorStyleChanged(source: source, newStyle: cursorShape)
    }
    private static func steadyCursor(_ style: CursorStyle) -> CursorStyle {
        switch style {
        case .blinkBlock: return .steadyBlock
        case .blinkBar: return .steadyBar
        case .blinkUnderline: return .steadyUnderline
        default: return style
        }
    }
    override func selectionChanged(source: Terminal) { super.selectionChanged(source: source); viewportChanged?() }
    /// The host hid the cursor (DECTCEM), as Claude Code's and Codex's panels do; it is then parked anywhere.
    private(set) var hostHidCursor = false
    override func showCursor(source: Terminal) { hostHidCursor = false; super.showCursor(source: source) }
    override func hideCursor(source: Terminal) { hostHidCursor = true; super.hideCursor(source: source) }
    override func mouseModeChanged(source: Terminal) {
        // SwiftTerm's implementation adds a button-drag recognizer even with
        // allowMouseReporting=false. Only our vertical wheel recognizer reports
        // mouse input; native long-press selection must remain local.
        viewportChanged?()
    }
    deinit { TerminalCensus.change(-1) }
    override init(frame: CGRect) {
        TerminalCensus.change(1)
        super.init(frame: frame); terminalReady = true
        getTerminal().setCursorStyle(.steadyBlock)
        isAccessibilityElement = true; accessibilityLabel = "Terminal"; accessibilityTraits = [.updatesFrequently]
    }
    required init?(coder: NSCoder) {
        TerminalCensus.change(1)
        super.init(coder: coder); terminalReady = true
        getTerminal().setCursorStyle(.steadyBlock)
        isAccessibilityElement = true; accessibilityLabel = "Terminal"
    }
    override var accessibilityValue: String? {
        get { String(decoding: getTerminal().getBufferAsData().suffix(16_384), as: UTF8.self) }
        set { }
    }
}

/// How many terminal views are alive, for the diagnostics log: more than the open sessions means some leaked.
enum TerminalCensus {
    private static let lock = NSLock()
    private static var count = 0
    static var live: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func change(_ delta: Int) { lock.lock(); count += delta; lock.unlock() }
}

/// Observes the initial workspace press without recognizing or consuming a gesture.
@MainActor final class TerminalTouchObserver: UIGestureRecognizer {
    let touched: () -> Void
    init(touched: @escaping () -> Void) {
        self.touched = touched
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { touched(); state = .failed }
}
