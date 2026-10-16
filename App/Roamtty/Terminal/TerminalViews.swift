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
    /// Feeds host output without pulling a reader back. SwiftTerm puts the view at the live bottom on each new line
    /// and each synchronized-output frame, as Claude Code draws, so dragging back through a busy terminal fought
    /// every update. Someone reading back, or with a finger or fling on the view, keeps their place; a view left
    /// at the bottom still follows the output.
    func feedKeepingPlace(_ bytes: ArraySlice<UInt8>) {
        let terminal = getTerminal(), before = terminal.displayBuffer
        let rowHeight = getOptimalFrameSize().height / CGFloat(max(1, terminal.rows))
        let bottom = CGFloat(before.lines.count - before.rows) * rowHeight
        let reading = rowHeight > 0 && !terminal.isDisplayBufferAlternate
            && (isTracking || isDecelerating || contentOffset.y < bottom - rowHeight / 2)
        let place = contentOffset.y, lines = before.lines.count, yDisp = before.yDisp
        feed(byteArray: bytes)
        guard reading, !terminal.isDisplayBufferAlternate else { return }
        let after = terminal.displayBuffer
        // A full scrollback drops its oldest lines as new ones arrive; move up with the text being read.
        let dropped = max(0, (after.yDisp - yDisp) - (after.lines.count - lines))
        let target = min(max(0, contentSize.height - bounds.height), max(0, place - CGFloat(dropped) * rowHeight))
        if contentOffset.y != target { contentOffset.y = target }
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

extension TerminalView {
    /// Back to the live bottom before input the app sends itself. SwiftTerm's `scroll(toPosition: 1)` only moves the
    /// terminal's own viewport, which stays at the bottom while the view is dragged back through its history.
    func scrollToLiveOutput() {
        scroll(toPosition: 1)
        contentOffset.y = max(0, contentSize.height - bounds.height)
    }
}

/// How many terminal views are alive, for the diagnostics log: more than the open sessions means some leaked.
enum TerminalCensus {
    private static let lock = NSLock()
    private static var count = 0
    static var live: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func change(_ delta: Int) { lock.lock(); count += delta; lock.unlock() }
}

/// The terminal's own taps. Once the keyboard has been up, iOS 26 leaves a text recognizer
/// (UIPhraseBoundaryGestureRecognizer) on a view it adds inside the terminal, and it wins every later tap, so
/// a tap could no longer bring the keyboard back: only recognizers on the terminal view itself may prevent these.
@MainActor final class TerminalTapRecognizer: UITapGestureRecognizer {
    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool { preventing.view === view }
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
