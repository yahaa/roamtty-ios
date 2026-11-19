import UIKit
import SwiftUI
import Combine
import SwiftTerm
import RoamttyCore
import RoamttyTransport

/// One terminal session: its view, its transport (SSH or mosh) and what the screens show of it.
/// This file holds the session's lifecycle; the rest lives in extensions:
/// - `SessionRuntime+Connection`: the worker that connects and carries the terminal over mosh or SSH
/// - `SessionRuntime+Startup`: when a new connection counts as connected, and the start command
/// - `SessionRuntime+Agent`: the agent status poll and the actions on tmux and the agent
/// - `SessionRuntime+Input`: keys, paste, the keyboard and the cursor-row controls
/// - `SessionRuntime+Gestures`: taps, swipes, scrolling, flings and pinch-to-zoom
/// - `SessionRuntime+TerminalDelegate`: SwiftTerm's callbacks
@MainActor final class SessionRuntime: NSObject, ObservableObject {
    // MARK: State the screens show

    @Published var record: SessionRecord
    let host: Host
    var loginSnapshot: SessionLoginSnapshot
    @Published var phase: ConnectionPhase = .connecting
    @Published var message: String?
    @Published var transportName = "SSH"
    /// Kept, not published: Claude Code animates its title several times a second, and no screen shows it.
    var terminalTitle = ""
    var currentDirectory = "~"
    @Published var controlArmed = false
    @Published var shiftArmed = false
    @Published var workspaceTouches = 0
    @Published var pendingPaste: String?
    /// Why the terminal is not connected: a drop or a restore reconnects by itself (Android `reconnectsOnOpen`).
    @Published var end: SessionEnd?
    /// The agent this session was started to run; restored sessions tell it by their title.
    @Published var launchedAgent: CodingAgent?
    /// What an agent started with hooks reports in this tmux session; nil for none, or while the host is out of reach.
    @Published var agentStatus: AgentStatus?
    /// When `agentStatus` was last read, so its elapsed time can move on between polls.
    var agentStatusAt = Date()
    /// Whether the host has answered a status poll since this connection came up; until then the list shows what the
    /// session reported last.
    @Published var agentPolled = false
    /// The status the last answered poll reported, starting from what the session reported before this runtime: what
    /// `onAgentReport` compares the next report with. Unlike `agentStatus`, a dropped connection does not clear it.
    var reportedAgentStatus: AgentStatus?
    /// Each answered poll's report after the one before it, for the agent notifications.
    var onAgentReport: ((_ previous: AgentStatus?, _ current: AgentStatus?) -> Void)?
    /// The folder the tmux pane was last seen in, agent or not; empty until the first poll answers.
    @Published var paneDirectory = ""
    /// A double tap (Tab) brings the Up/Down/Left keys around the toolbox pet; each one restarts their idle clock.
    @Published var petArrowTouches = 0
    /// Where the cursor row is and which key it offers. It moves with every chunk of output and every scrolled
    /// frame, so it has its own publisher: only the views placed by it redraw, not the whole terminal page.
    let cursorRow = TerminalCursorRow()
    /// The cursor line starts with `/`, so its command menu keeps the pet's arrow keys up.
    var slashCommandLine: Bool { get { cursorRow.slashCommandLine } set { cursorRow.slashCommandLine = newValue } }
    var cursorRowBounds: CGRect? { get { cursorRow.bounds } set { cursorRow.bounds = newValue } }
    var cursorRowKey: CursorRowKey { get { cursorRow.key } set { cursorRow.key = newValue } }
    /// Shell history commands run from the commands sheet in this session, newest first (memory only).
    var recentCommands: [String] = []
    /// Pinch-to-zoom reports the settled font size so it persists like Android's.
    var onFontScaled: ((Double) -> Void)?
    /// A tapped path that names a file on the host, with its 1-based line or 0; nil leaves paths as plain text.
    var onOpenPath: ((_ path: String, _ line: Int) -> Void)?
    /// A tapped page on the server's own loopback (`http://localhost:5173/`), shown in the app through a tunnel.
    var onOpenLoopback: ((LoopbackUrl) -> Void)?
    var onFailure: ((Error) -> Void)?
    let terminalView: TerminalView

    // MARK: Connection

    var ssh: SSHConnection?
    var mosh: MoshTransport?
    /// Moves on with every connect and close, so callbacks of an earlier connection drop out.
    var generation = UUID()
    var columns = 80
    var rows = 24
    let lifetimeCancellation = TransferCancellation()
    var worker: Task<Void, Never>?
    var configuredFont: String?
    var configuredSize: Double?
    var configuredFontRevision: Int?
    var configuredScheme: ColorScheme?
    var startupSent = false
    var startupAttempt = UUID()
    var startupGate: TerminalStartupGate?
    var startupCommand: String?
    var startupTask: Task<Void, Never>?
    var startupTimeoutTask: Task<Void, Never>?
    var startupCancellation: TransferCancellation?
    /// The mouse mode the host asked for, kept by xterm's rules; see `TerminalMouseTracking`.
    var mouseTracking = TerminalMouseTracking()
    /// Shown as the 提示 card once the SSH fallback connects (Android `moshFallback` → `inputWarning`).
    var fallbackNotice: String?
    var agentPoll: Task<Void, Never>?
    /// Logs in again for the SSH connection a mosh terminal keeps for its side work (the status poll, the tmux
    /// actions), once that one dropped while mosh carried on. Set by the app, which owns logins.
    var reopenSideConnection: (() async throws -> SSHConnection)?
    var sideReconnect: Task<SSHConnection?, Never>?
    var sideReconnectAt: Date?
    static let moshFallbackNotice = "mosh 无法连接（可能未放行 UDP 60000–61000），已改用 SSH。 / Mosh unavailable (UDP 60000–61000 may be blocked), so this session uses SSH."
    static let tmuxNotReadyMessage = "tmux 未在 8 秒内准备就绪，请重连 / tmux was not ready within 8 seconds; reconnect"

    // MARK: Input (SessionRuntime+Input)

    var cursorControls = TerminalCursorControls()
    var cursorTimer: Task<Void, Never>?
    var keyboardHide: Task<Void, Never>?
    var cursorRefreshQueued = false
    /// A native paste being gathered from the delegate's output.
    var capturedPaste: TerminalPasteCapture?
    var keyboardDeleteHold = TerminalDeleteHold()

    // MARK: Gestures (SessionRuntime+Gestures)

    weak var selectionTap: UITapGestureRecognizer?
    /// A tap on another row of a multi-line input: ↑/↓ went out, ←/→ follow once the cursor is drawn on that row.
    var pendingCursorTap: PendingCursorTap?
    weak var horizontalPan: UIPanGestureRecognizer?
    weak var verticalPan: UIPanGestureRecognizer?
    /// The recognizers this runtime put on the terminal view, taken off again by `discard`.
    var ownRecognizers: [UIGestureRecognizer] = []
    /// Marks the link under a finger, as Android does.
    lazy var linkPress = TerminalLinkPress(terminalView: terminalView)
    var inputGestureHadPinch = false
    var swipeHold: Task<Void, Never>?
    var swipeGeneration: UUID?
    var swipeHeld = false
    var swipeHoldPosition: CGPoint?
    var scrollGeneration: UUID?
    var scrollAccumulator = TerminalScrollAccumulator()
    /// Gathers the wheel events of one scroll step from the delegate, so they go out as one write.
    var scrollEventBytes: Data?
    /// Carries a vertical swipe on after the finger lifts (Android's fling); any new touch stops it.
    var fling: ScrollFling?
    var flingLink: CADisplayLink?

    init(record: SessionRecord, host: Host, loginSnapshot: SessionLoginSnapshot? = nil) {
        self.record = record; self.host = host
        self.loginSnapshot = loginSnapshot ?? SessionLoginSnapshot(host: host)
        self.launchedAgent = CodingAgent.fromTitle(record.title)
        self.reportedAgentStatus = AgentStatusMemory.value(record.id)
        let view = AccessibleTerminalView(frame: .zero)
        terminalView = view
        super.init()
        terminalView.terminalDelegate = self
        terminalView.inputAccessoryView = nil
        // Android keeps xterm's fixed 256-colour cube and grey ramp instead of deriving them from the 16 ANSI colours.
        terminalView.getTerminal().options.ansi256PaletteStrategy = .xterm
        // 2000 lines of history like Android (Termux's default) rather than SwiftTerm's 500.
        terminalView.changeScrollback(2000)
        // iOS 26 frosts a scroll view's edges under the status bar and home indicator; the terminal stays clear to the edge.
        if #available(iOS 26.0, *) { terminalView.topEdgeEffect.isHidden = true; terminalView.bottomEdgeEffect.isHidden = true }
        // The page lays the terminal under the status bar itself; the scroll view must not add its own safe-area insets.
        terminalView.contentInsetAdjustmentBehavior = .never
        terminalView.allowMouseReporting = false
        terminalView.notifyUpdateChanges = true
        terminalView.autocorrectionType = .no
        terminalView.autocapitalizationType = .none
        terminalView.accessibilityIdentifier = "terminal-surface"
        view.viewportChanged = { [weak self] in self?.queueCursorRefresh() }
        view.pasteStarted = { [weak self] bracketed in self?.clearModifiers(); self?.capturedPaste = TerminalPasteCapture(bracketed: bracketed) }
        view.pasteFinished = { [weak self] in self?.finishNativePaste() }
        installGestures()
    }
    /// Fires before a change to what the screens outside this terminal show of it: the session list, the drawer
    /// and the session menu. Output, the cursor and gestures stay with the terminal's own views, so a busy
    /// terminal does not redraw the whole app on every chunk it receives.
    var summaryWillChange: AnyPublisher<Void, Never> {
        func changes<T>(_ publisher: Published<T>.Publisher) -> AnyPublisher<Void, Never> { publisher.dropFirst().map { _ in () }.eraseToAnyPublisher() }
        return Publishers.MergeMany(changes($record), changes($phase), changes($end), changes($agentStatus), changes($agentPolled),
                                    changes($paneDirectory), changes($transportName), changes($launchedAgent)).eraseToAnyPublisher()
    }
    static func background(_ scheme: ColorScheme) -> UIColor { UIColor(hex: scheme == .dark ? 0x252728 : 0xFFFDF9) }
    /// Android's 16 ANSI colours (`TerminalColorScheme`), so a program's colours look the same on both. Black is the
    /// grey Claude Code paints its prompt rows with, rather than SwiftTerm's pure black.
    static func ansiColors(_ scheme: ColorScheme) -> [SwiftTerm.Color] {
        let values: [Int] = scheme == .dark
            ? [0x202221, 0xD97579, 0x80C99A, 0xD9BB76, 0x7EADD8, 0xBD9BD5, 0x79C4CD, 0xD9D4CC,
               0x777A75, 0xF18E92, 0xA5DFB4, 0xEFD391, 0xA6CAEB, 0xD4B5E7, 0xA1DEE3, 0xF5F1EB]
            : [0x2B2A27, 0xA33B49, 0x277550, 0x8A6317, 0x285F9A, 0x82539C, 0x177986, 0x837D74,
               0x6F6B64, 0xBD4A56, 0x31865B, 0x9C7524, 0x3977B7, 0x9563AD, 0x248D99, 0x5F5B54]
        return values.map { SwiftTerm.Color(red: UInt16($0 >> 16 & 255) * 257, green: UInt16($0 >> 8 & 255) * 257, blue: UInt16($0 & 255) * 257) }
    }
    func configure(settings: AppSettings, scheme: ColorScheme) {
        let fonts = FontCatalog.shared
        if configuredFont != settings.font || configuredSize != settings.fontSize || configuredFontRevision != fonts.revision {
            terminalView.font = fonts.font(selection: settings.font, size: settings.fontSize)
            configuredFont = settings.font; configuredSize = settings.fontSize
            configuredFontRevision = fonts.revision
        }
        if configuredScheme != scheme {
            terminalView.installColors(Self.ansiColors(scheme))
            terminalView.nativeBackgroundColor = Self.background(scheme)
            terminalView.nativeForegroundColor = UIColor(hex: scheme == .dark ? 0xF3F0EA : 0x2B2A27)
            terminalView.caretColor = UIColor(hex: scheme == .dark ? 0xEFA783 : 0x9E462C)
            terminalView.keyboardAppearance = scheme == .dark ? .dark : .light
            configuredScheme = scheme
        }
        queueCursorRefresh()
    }
    func clearLoginCredentials() { loginSnapshot.clear() }

    // MARK: Failing and closing

    func fail(_ error: Error) {
        pendingPaste = nil
        stopAgentStatusPolling()
        end = SessionEnd(failure: error, wasConnected: startupSent)
        if (error as? RoamError) == .authentication { loginSnapshot.invalidateAuthentication() }
        onFailure?(error)
        phase = ConnectionPhase(failure: error)
        message = error.localizedDescription
    }
    func close() {
        pendingPaste = nil; capturedPaste = nil
        swipeHold?.cancel(); swipeHold = nil; swipeGeneration = nil
        scrollGeneration = nil; scrollAccumulator.reset(); stopScrollInertia()
        generation = UUID(); worker?.cancel(); worker = nil; mosh?.close(); mosh = nil
        lifetimeCancellation.cancel(); cancelStartup()
        cursorTimer?.cancel(); keyboardHide?.cancel(); cursorControls = TerminalCursorControls(); cursorRowBounds = nil; cursorRowKey = .escape
        stopAgentStatusPolling()
        sideReconnect?.cancel(); sideReconnect = nil; sideReconnectAt = nil
        ssh?.disconnectInBackground(); ssh = nil
        end = .ended; phase = .disconnected; _ = terminalView.resignFirstResponder()
    }
    func probe() { mosh?.probe() }
    /// Closes the session for good once the app has let go of it. SwiftTerm's display link retains its view
    /// until `updateUiClosed`, so without this every reconnect kept the old terminal alive: its buffers and a
    /// screen-sized backing store, until iOS ended the app for its memory.
    func discard() {
        linkPress.clear()
        close()
        terminalView.updateUiClosed()
        terminalView.terminalDelegate = nil
        for recognizer in ownRecognizers { terminalView.removeGestureRecognizer(recognizer) }
        ownRecognizers = []
        onFailure = nil; onFontScaled = nil; onOpenPath = nil; onOpenLoopback = nil; reopenSideConnection = nil
    }
}
