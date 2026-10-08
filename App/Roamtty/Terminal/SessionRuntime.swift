import UIKit
import SwiftUI
import SwiftTerm
import RoamttyCore
import RoamttyTransport

@MainActor final class SessionRuntime: NSObject, ObservableObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
    @Published var record: SessionRecord
    let host: Host
    private(set) var loginSnapshot: SessionLoginSnapshot
    @Published var phase: ConnectionPhase = .connecting
    @Published var message: String?
    @Published var transportName = "SSH"
    @Published var terminalTitle = ""
    @Published var currentDirectory = "~"
    @Published var controlArmed = false
    @Published var shiftArmed = false
    @Published var outputRevision = 0
    @Published private(set) var workspaceTouches = 0
    @Published var pendingPaste: String?
    /// Shell history commands run from the commands sheet in this session, newest first (memory only).
    var recentCommands: [String] = []
    /// Pinch-to-zoom reports the settled font size so it persists like Android's.
    var onFontScaled: ((Double) -> Void)?
    @Published private(set) var cursorRowBounds: CGRect?
    @Published private(set) var cursorRowKey: CursorRowKey = .escape
    let terminalView: TerminalView
    private(set) var ssh: SSHConnection?
    private var mosh: MoshTransport?
    private var generation = UUID()
    private var columns = 80
    private var rows = 24
    private var configuredFont: String?
    private var configuredSize: Double?
    private var configuredFontRevision: Int?
    private var configuredScheme: ColorScheme?
    var onFailure: ((Error) -> Void)?
    private var startupSent = false
    private var startupAttempt = UUID()
    private var startupGate: TerminalStartupGate?
    private var startupCommand: String?
    private var startupTask: Task<Void, Never>?
    private var startupTimeoutTask: Task<Void, Never>?
    private var startupCancellation: TransferCancellation?
    private let lifetimeCancellation = TransferCancellation()
    private var worker: Task<Void, Never>?
    private weak var selectionTap: UITapGestureRecognizer?
    private var cursorControls = TerminalCursorControls()
    private var cursorTimer: Task<Void, Never>?
    private var keyboardHide: Task<Void, Never>?
    private var cursorRefreshQueued = false
    private var capturedPaste: Data?
    private var capturedPasteBracketed = false
    private var capturedPasteTooLarge = false
    private weak var horizontalPan: UIPanGestureRecognizer?
    private var swipeHold: Task<Void, Never>?
    private var swipeGeneration: UUID?
    private var swipeHeld = false
    private var swipeHoldPosition: CGPoint?
    private weak var verticalPan: UIPanGestureRecognizer?
    private var scrollGeneration: UUID?
    private var scrollAccumulator = TerminalScrollAccumulator()
    private var sendingScrollEvent = false
    private var inputGestureHadPinch = false

    init(record: SessionRecord, host: Host, loginSnapshot: SessionLoginSnapshot? = nil) {
        self.record = record; self.host = host
        self.loginSnapshot = loginSnapshot ?? SessionLoginSnapshot(host: host)
        terminalView = AccessibleTerminalView(frame: .zero)
        super.init()
        terminalView.terminalDelegate = self
        terminalView.inputAccessoryView = nil
        terminalView.allowMouseReporting = false
        terminalView.notifyUpdateChanges = true
        terminalView.autocorrectionType = .no
        terminalView.autocapitalizationType = .none
        terminalView.accessibilityIdentifier = "terminal-surface"
        // Keep SwiftTerm's native single tap solely for dismissing an intentional selection.
        // Its long press and selection handles remain installed; normal taps use Android's rules.
        for recognizer in terminalView.gestureRecognizers ?? [] {
            guard let tap = recognizer as? UITapGestureRecognizer else { continue }
            if tap.numberOfTapsRequired == 1 { selectionTap = tap; tap.delegate = self }
            else { tap.isEnabled = false }
        }
        let single = UITapGestureRecognizer(target: self, action: #selector(cursorTap(_:)))
        let double = UITapGestureRecognizer(target: self, action: #selector(completionTap(_:)))
        let triple = UITapGestureRecognizer(target: self, action: #selector(pasteTap(_:)))
        double.numberOfTapsRequired = 2; triple.numberOfTapsRequired = 3
        single.require(toFail: double); double.require(toFail: triple)
        for tap in [single, double, triple] { tap.delegate = self; terminalView.addGestureRecognizer(tap) }
        (terminalView as? AccessibleTerminalView)?.viewportChanged = { [weak self] in self?.queueCursorRefresh() }
        (terminalView as? AccessibleTerminalView)?.pasteStarted = { [weak self] bracketed in
            self?.clearModifiers(); self?.capturedPaste = Data(); self?.capturedPasteBracketed = bracketed; self?.capturedPasteTooLarge = false
        }
        (terminalView as? AccessibleTerminalView)?.pasteFinished = { [weak self] in self?.finishNativePaste() }
        let touchObserver = TerminalTouchObserver { [weak self] in self?.workspaceTouches += 1; self?.inputGestureHadPinch = false }
        terminalView.addGestureRecognizer(touchObserver)
        let swipe = UIPanGestureRecognizer(target: self, action: #selector(horizontalSwipe(_:)))
        swipe.minimumNumberOfTouches = 1; swipe.maximumNumberOfTouches = 1; swipe.delegate = self
        horizontalPan = swipe; terminalView.addGestureRecognizer(swipe)
        terminalView.panGestureRecognizer.require(toFail: swipe)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(verticalScroll(_:)))
        scroll.minimumNumberOfTouches = 1; scroll.maximumNumberOfTouches = 1; scroll.delegate = self
        verticalPan = scroll; terminalView.addGestureRecognizer(scroll)
        terminalView.panGestureRecognizer.require(toFail: scroll)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchFont(_:)))
        terminalView.addGestureRecognizer(pinch)
    }
    func configure(settings: AppSettings, scheme: ColorScheme) {
        let fonts = FontCatalog.shared
        if configuredFont != settings.font || configuredSize != settings.fontSize || configuredFontRevision != fonts.revision {
            terminalView.font = fonts.font(selection: settings.font, size: settings.fontSize)
            configuredFont = settings.font; configuredSize = settings.fontSize
            configuredFontRevision = fonts.revision
        }
        if configuredScheme != scheme {
            terminalView.nativeBackgroundColor = UIColor(hex: scheme == .dark ? 0x252728 : 0xFFFDF9)
            terminalView.nativeForegroundColor = UIColor(hex: scheme == .dark ? 0xF3F0EA : 0x2B2A27)
            terminalView.caretColor = UIColor(hex: scheme == .dark ? 0xEFA783 : 0x9E462C)
            terminalView.keyboardAppearance = scheme == .dark ? .dark : .light
            configuredScheme = scheme
        }
        queueCursorRefresh()
    }
    func clearLoginCredentials() { loginSnapshot.clear() }
    func connect(ssh: SSHConnection, credentials: Credentials, preferMosh: Bool, directory: String, agent: AgentLaunch?) {
        loginSnapshot = SessionLoginSnapshot(host: host, credentials: credentials)
        self.ssh = ssh; currentDirectory = directory; phase = .connecting
        let token = generation
        ssh.onPhase = { [weak self] value in DispatchQueue.main.async { guard self?.generation == token else { return }; self?.phase = value == .connected && self?.startupSent == false ? .connecting : value } }
        let startup: String? = agent?.commandLine ?? StartDirectory.command(directory)
        let mode = record.mode, name = record.remoteName, cols = columns, rows = rows
        let lifetime = lifetimeCancellation
        worker = Task { [weak self] in
            do {
                try await performInBackground {
                    try ssh.connect()
                    if preferMosh {
                        do {
                            let previous = mode == .tmux ? try Self.tmuxClients(ssh, name: name, cancellation: lifetime) : []
                            let attempt = UUID()
                            let mosh = try ssh.startMosh(mode: mode, remoteName: name, columns: cols, rows: rows)
                            DispatchQueue.main.sync {
                                guard self?.generation == token else { mosh.close(); return }
                                self?.mosh = mosh; self?.transportName = "mosh"
                                self?.beginStartup(startup, ssh: ssh, mode: mode, name: name, previousClients: previous, token: token, attempt: attempt, afterFirstContact: true)
                            }
                            try mosh.run(columns: cols, rows: rows, firstContactTimeout: 8, silenceTimeout: mode == .shell ? 43_740 : 840, stallTimeout: mode == .shell ? nil : 10) { data in
                                DispatchQueue.main.sync { self?.receive(data, token: token, attempt: attempt) }
                            }
                            return
                        } catch {
                            let canFallback = DispatchQueue.main.sync { () -> Bool in
                                guard let self, self.generation == token, !self.startupSent else { return false }
                                self.cancelStartup(); self.mosh?.close(); self.mosh = nil; self.transportName = "SSH"; self.message = "Mosh unavailable · SSH"
                                return true
                            }
                            // Commitment and fallback are one main-thread transaction, so no
                            // readiness callback can authorize input between those decisions.
                            guard canFallback else { throw error }
                        }
                    }
                    guard !lifetime.isCancelled else { throw RoamError.cancelled }
                    let previous = mode == .tmux ? try Self.tmuxClients(ssh, name: name, cancellation: lifetime) : []
                    let attempt = UUID()
                    try ssh.openTerminal(mode: mode, remoteName: name, columns: cols, rows: rows)
                    DispatchQueue.main.sync {
                        guard self?.generation == token else { return }
                        self?.beginStartup(startup, ssh: ssh, mode: mode, name: name, previousClients: previous, token: token, attempt: attempt, afterFirstContact: false)
                    }
                    try ssh.runTerminal { data in DispatchQueue.main.sync { self?.receive(data, token: token, attempt: attempt) } }
                }
                guard self?.generation == token else { return }
                self?.cancelStartup(); self?.phase = .disconnected
            } catch { guard self?.generation == token else { return }; self?.cancelStartup(); self?.fail(error) }
        }
    }
    private func beginStartup(_ command: String?, ssh: SSHConnection, mode: SessionMode, name: String, previousClients: Set<String>, token: UUID, attempt: UUID, afterFirstContact: Bool) {
        cancelStartup()
        startupAttempt = attempt; startupCommand = command
        startupGate = TerminalStartupGate(needsTmuxClient: mode == .tmux, requiresOutput: afterFirstContact || mode == .tmux, previousClients: previousClients)
        if !afterFirstContact { waitForStartup(ssh: ssh, name: name, token: token, attempt: attempt) }
        finishStartup(token: token, attempt: attempt)
    }
    private func receive(_ data: Data, token: UUID, attempt: UUID) {
        guard generation == token, startupAttempt == attempt else { return }
        terminalView.feed(byteArray: Array(data)[...]); outputRevision += 1
        queueCursorRefresh()
        if !startupSent {
            startupGate?.sawOutput = true
            if let ssh { waitForStartup(ssh: ssh, name: record.remoteName, token: token, attempt: attempt) }
            finishStartup(token: token, attempt: attempt)
        }
    }
    private func finishStartup(token: UUID, attempt: UUID) {
        guard generation == token, startupAttempt == attempt, !startupSent, startupGate?.ready == true else { return }
        if let startupCommand {
            let input = Data((startupCommand + "\r").utf8)
            guard mosh?.write(input) ?? ssh?.write(input) ?? false else {
                close(); fail(RoamError.transport("启动命令未发送 / Startup command was not accepted")); return
            }
        }
        // Acceptance is irreversible: any later transport failure must not replay startup input.
        startupSent = true; phase = .connected
        startupTask?.cancel(); startupTask = nil; startupCancellation?.cancel(); startupCancellation = nil
        startupTimeoutTask?.cancel(); startupTimeoutTask = nil
    }
    private func waitForStartup(ssh: SSHConnection, name: String, token: UUID, attempt: UUID) {
        guard startupTask == nil, startupGate?.needsTmuxClient == true else { return }
        let cancellation = TransferCancellation(), deadline = ProcessInfo.processInfo.systemUptime + 8
        startupCancellation = cancellation
        startupTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, self.generation == token, self.startupAttempt == attempt, !self.startupSent else { return }
                self.close(); self.fail(RoamError.transport("tmux 未在 8 秒内准备就绪，请重连 / tmux was not ready within 8 seconds; reconnect"))
            } catch { }
        }
        startupTask = Task { [weak self] in
            await withTaskCancellationHandler(operation: {
                do {
                    while ProcessInfo.processInfo.systemUptime < deadline {
                        try Task.checkCancellation()
                        guard let self, self.generation == token, self.startupAttempt == attempt else { return }
                        if self.startupGate?.sawNewClient != true {
                            let remaining = min(2, deadline - ProcessInfo.processInfo.systemUptime)
                            guard remaining > 0 else { throw RoamError.timeout }
                            let clients = try await performInBackground { try Self.tmuxClients(ssh, name: name, cancellation: cancellation, timeout: remaining) }
                            guard self.generation == token, self.startupAttempt == attempt else { return }
                            self.startupGate?.observe(clients: clients)
                        }
                        self.finishStartup(token: token, attempt: attempt)
                        if self.startupSent { return }
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    throw RoamError.transport("tmux 未在 8 秒内准备就绪，请重连 / tmux was not ready within 8 seconds; reconnect")
                } catch {
                    guard !Task.isCancelled, let self, self.generation == token, self.startupAttempt == attempt else { return }
                    self.close(); self.fail(error)
                }
            }, onCancel: { cancellation.cancel() })
        }
    }
    nonisolated private static func tmuxClients(_ ssh: SSHConnection, name: String, cancellation: TransferCancellation, timeout: TimeInterval = 2) throws -> Set<String> {
        let target = "=" + RemoteCommands.sanitizeSessionName(name)
        let script = RemoteCommands.pathSetup + "; tmux list-clients -t " + RemoteCommands.shellQuote(target) + " -F '__ROAMTTY_CLIENT__#{client_pid}|#{client_tty}' 2>/dev/null"
        let result = try ssh.exec("/bin/sh -c " + RemoteCommands.shellQuote(script), input: Data(), timeout: timeout, cancellation: cancellation)
        return result.status == 0 ? TerminalStartupGate.clients(from: String(decoding: result.output, as: UTF8.self)) : []
    }
    private func cancelStartup() {
        startupAttempt = UUID(); startupTask?.cancel(); startupTask = nil; startupCancellation?.cancel(); startupCancellation = nil
        startupTimeoutTask?.cancel(); startupTimeoutTask = nil
        startupGate = nil; startupCommand = nil
    }
    func fail(_ error: Error) {
        pendingPaste = nil
        if (error as? RoamError) == .authentication { loginSnapshot.invalidateAuthentication() }
        onFailure?(error)
        if let error = error as? RoamError {
            switch error {
            case .authentication: phase = .authFailed
            case .hostKeyChanged: phase = .hostKeyChanged
            case .tmuxMissing: phase = .tmuxMissing
            case .cancelled, .rejected: phase = .disconnected
            default: phase = .failed
            }
        } else { phase = .failed }
        message = error.localizedDescription
    }
    @discardableResult func send(_ string: String) -> Bool { send(Data(string.utf8)) }
    @discardableResult func send(_ data: Data) -> Bool {
        guard phase == .connected else { return false }
        let sent = mosh?.write(data) ?? ssh?.write(data) ?? false
        if !sent { message = "输入未发送 / Input was not sent" }
        return sent
    }
    func close() {
        pendingPaste = nil; capturedPaste = nil
        swipeHold?.cancel(); swipeHold = nil; swipeGeneration = nil
        scrollGeneration = nil; scrollAccumulator.reset()
        generation = UUID(); worker?.cancel(); worker = nil; mosh?.close(); mosh = nil
        lifetimeCancellation.cancel(); cancelStartup()
        cursorTimer?.cancel(); keyboardHide?.cancel(); cursorControls = TerminalCursorControls(); cursorRowBounds = nil; cursorRowKey = .escape
        let connection = ssh; ssh = nil; DispatchQueue.global(qos: .utility).async { connection?.disconnect() }
        phase = .disconnected; terminalView.resignFirstResponder()
    }
    func probe() { mosh?.probe() }
    func toggleKeyboard() { if terminalView.isFirstResponder { terminalView.resignFirstResponder() } else { terminalView.becomeFirstResponder() } }
    func paste() { terminalView.paste(nil) }
    @discardableResult func pasteText(_ text: String, confirmed: Bool = false) -> Bool {
        guard phase == .connected else { return false }
        guard text.utf8.count <= TerminalPaste.byteLimit else { message = "单次发送上限为 128 KiB，请分段发送。 / Send at most 128 KiB at a time."; return false }
        let bracketed = terminalView.getTerminal().bracketedPasteMode
        if !confirmed && TerminalPaste.needsConfirmation(text, bracketed: bracketed) { pendingPaste = text; return false }
        guard let input = try? TerminalPaste.input(text, bracketed: bracketed) else { return false }
        clearModifiers(); terminalView.scroll(toPosition: 1)
        let accepted = send(input)
        if accepted { userTyped(Data(input.utf8)) }
        return accepted
    }
    @discardableResult func confirmPendingPaste() -> Bool {
        guard let text = pendingPaste else { return false }
        pendingPaste = nil
        return pasteText(text, confirmed: true)
    }
    private func finishNativePaste() {
        guard var data = capturedPaste else { return }
        capturedPaste = nil
        if capturedPasteTooLarge { message = "单次发送上限为 128 KiB，请分段发送。 / Send at most 128 KiB at a time."; return }
        // SwiftTerm owns selection cleanup and reads the clipboard once. Its delegate
        // output is staged here until the whole paste can be validated and enqueued.
        if capturedPasteBracketed, data.count >= 12 { data.removeFirst(6); data.removeLast(6) }
        guard !data.isEmpty else { return }
        _ = pasteText(String(decoding: data, as: UTF8.self))
    }
    func screenApp() -> ScreenApp {
        let terminal = terminalView.getTerminal()
        let lines = (0..<terminal.rows).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
        return ScreenApp.detect(rows: lines, cursorRow: terminal.getCursorLocation().y)
    }
    func copySelection() { terminalView.copy(nil) }
    func armControl() { controlArmed.toggle(); terminalView.controlModifier = controlArmed }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === selectionTap { return terminalView.selectionActive }
        return !terminalView.selectionActive
    }
    private var writableViewport: Bool { phase == .connected && !terminalView.selectionActive && (!terminalView.canScroll || terminalView.scrollPosition >= 1) }
    private var scrollDisposition: TerminalScrollDisposition {
        let terminal = terminalView.getTerminal()
        return TerminalScrolling.disposition(connected: phase == .connected, selecting: terminalView.selectionActive,
                                             mouseTracking: terminal.mouseMode != .off, alternate: terminal.isCurrentBufferAlternate)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === horizontalPan, let pan = horizontalPan {
            let movement = pan.translation(in: terminalView)
            return !inputGestureHadPinch && writableViewport && abs(movement.x) > 1.5 * abs(movement.y)
        }
        if gestureRecognizer === verticalPan, let pan = verticalPan {
            let movement = pan.translation(in: terminalView), disposition = scrollDisposition
            return !inputGestureHadPinch && (disposition == .wheel || disposition == .arrows) && abs(movement.x) <= 1.5 * abs(movement.y)
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let isPan = gestureRecognizer === horizontalPan || gestureRecognizer === verticalPan
        return isPan && otherGestureRecognizer is UIPinchGestureRecognizer
    }
    @objc private func verticalScroll(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began: scrollGeneration = generation; scrollAccumulator.reset()
        case .changed: break
        case .ended, .cancelled, .failed: scrollGeneration = nil; scrollAccumulator.reset(); return
        default: return
        }
        guard !inputGestureHadPinch, scrollGeneration == generation, recognizer.numberOfTouches == 1 else { scrollGeneration = nil; return }
        let disposition = scrollDisposition
        guard disposition == .wheel || disposition == .arrows else { scrollGeneration = nil; return }
        let terminal = terminalView.getTerminal(), optimal = terminalView.getOptimalFrameSize()
        let cell = CGSize(width: optimal.width / CGFloat(max(1, terminal.cols)), height: optimal.height / CGFloat(max(1, terminal.rows)))
        let rows = scrollAccumulator.rowsDown(translationY: recognizer.translation(in: terminalView).y, rowHeight: cell.height)
        guard rows != 0 else { return }
        if disposition == .arrows {
            let key = TerminalKeys.arrow(rows < 0 ? "A" : "B", applicationCursor: terminal.applicationCursor, control: false, shift: false)
            _ = send(String(repeating: key, count: abs(rows)))
        } else {
            let position = recognizer.location(in: terminalView)
            let point = TerminalScrolling.mousePoint(CGPoint(x: position.x - terminalView.contentOffset.x, y: position.y - terminalView.contentOffset.y), cell: cell, columns: terminal.cols, rows: terminal.rows)
            let flags = terminal.encodeButton(button: TerminalScrolling.mouseButton(rowsDown: rows), release: false, shift: false, meta: false, control: false)
            sendingScrollEvent = true
            defer { sendingScrollEvent = false }
            for _ in 0..<abs(rows) {
                terminal.sendEvent(buttonFlags: flags, x: point.column, y: point.row, pixelX: point.pixelX, pixelY: point.pixelY)
            }
        }
    }
    @objc private func horizontalSwipe(_ recognizer: UIPanGestureRecognizer) {
        let movement = recognizer.translation(in: terminalView)
        switch recognizer.state {
        case .began:
            swipeGeneration = generation; swipeHeld = false; swipeHoldPosition = nil
            trackSwipeHold(recognizer, movement: movement)
        case .changed: trackSwipeHold(recognizer, movement: movement)
        case .ended:
            swipeHold?.cancel(); swipeHold = nil
            defer { swipeGeneration = nil; swipeHoldPosition = nil; swipeHeld = false }
            guard !inputGestureHadPinch, swipeGeneration == generation, writableViewport, !swipeHeld,
                  let direction = TerminalKeys.swipeDirection(x: movement.x, y: movement.y) else { return }
            let input = TerminalKeys.arrow(direction < 0 ? "D" : "C", applicationCursor: terminalView.getTerminal().applicationCursor, control: controlArmed, shift: shiftArmed)
            clearModifiers(); send(input)
        case .cancelled, .failed:
            swipeHold?.cancel(); swipeHold = nil; swipeGeneration = nil; swipeHoldPosition = nil
        default: break
        }
    }
    private func trackSwipeHold(_ recognizer: UIPanGestureRecognizer, movement: CGPoint) {
        guard !swipeHeld else { return }
        guard writableViewport, TerminalKeys.swipeDirection(x: movement.x, y: movement.y) != nil else { swipeHold?.cancel(); swipeHold = nil; swipeHoldPosition = nil; return }
        if let previous = swipeHoldPosition, abs(previous.x - movement.x) <= 8, abs(previous.y - movement.y) <= 8 { return }
        swipeHoldPosition = movement; swipeHold?.cancel()
        let token = generation
        swipeHold = Task { [weak self, weak recognizer] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
                guard let self, let recognizer, self.generation == token, self.swipeGeneration == token, self.writableViewport,
                      recognizer.state == .began || recognizer.state == .changed else { return }
                let point = recognizer.translation(in: self.terminalView)
                guard let direction = TerminalKeys.swipeDirection(x: point.x, y: point.y) else { return }
                self.swipeHeld = true; self.clearModifiers(); self.send(direction < 0 ? "\u{1}" : "\u{5}")
            } catch { }
        }
    }
    @objc private func cursorTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, phase == .connected else { return }
        UIMenuController.shared.hideMenu()
        refreshCursor()
        guard let row = cursorRowBounds else { return }
        let y = recognizer.location(in: terminalView).y - terminalView.contentOffset.y
        if TerminalCursorControls.tapHitsCursor(y: y, rowTop: row.minY, rowHeight: row.height, viewportHeight: terminalView.bounds.height) { terminalView.becomeFirstResponder() }
        // iPhone keyboards have no dismiss key and there is no Back button: a reading tap elsewhere puts it away.
        else if terminalView.isFirstResponder { terminalView.resignFirstResponder() }
    }
    @objc private func completionTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, phase == .connected else { return }
        clearModifiers()
        if send("\t") { wakeCursor(dismissSlash: true) }
    }
    @objc private func pasteTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, phase == .connected else { return }
        clearModifiers(); paste()
    }
    func sendCursorKey(_ key: CursorRowKey, up: Bool = false) {
        let control = controlArmed, shift = shiftArmed
        clearModifiers()
        terminalView.scroll(toPosition: 1)
        let value: String
        switch key {
        case .enter: value = "\r"
        case .escape: value = "\u{1b}"
        case .arrows: value = TerminalKeys.arrow(up ? "A" : "B", applicationCursor: terminalView.getTerminal().applicationCursor, control: control, shift: shift)
        }
        guard send(value) else { return }
        if key != .escape { wakeCursor() }
        if key == .enter { hideKeyboardSoon() }
    }
    private func clearModifiers() { controlArmed = false; shiftArmed = false; terminalView.controlModifier = false }
    private func userTyped(_ data: Data) {
        keyboardHide?.cancel()
        cursorControls.typed(at: Date.timeIntervalSinceReferenceDate)
        updateCursorKey()
        scheduleCursorTimer(typing: true)
        if data == Data([13]) || data == Data([10]) { hideKeyboardSoon() }
    }
    private func wakeCursor(dismissSlash: Bool = false) {
        cursorControls.wake(at: Date.timeIntervalSinceReferenceDate, dismissSlash: dismissSlash)
        updateCursorKey(); scheduleCursorTimer(typing: false)
    }
    private func scheduleCursorTimer(typing: Bool) {
        cursorTimer?.cancel()
        cursorTimer = Task { [weak self] in
            do {
                if typing { try await Task.sleep(nanoseconds: 700_000_000); self?.updateCursorKey() }
                try await Task.sleep(nanoseconds: 3_000_000_000); self?.updateCursorKey()
            } catch { }
        }
    }
    private func hideKeyboardSoon() {
        keyboardHide?.cancel()
        keyboardHide = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000); self?.terminalView.resignFirstResponder() } catch { }
        }
    }
    private func updateCursorKey() {
        let key = cursorControls.key(at: Date.timeIntervalSinceReferenceDate)
        if cursorRowKey != key { cursorRowKey = key }
    }
    private func queueCursorRefresh() {
        guard !cursorRefreshQueued else { return }
        cursorRefreshQueued = true
        DispatchQueue.main.async { [weak self] in self?.cursorRefreshQueued = false; self?.refreshCursor() }
    }
    private func refreshCursor() {
        let view = terminalView
        let frame = view.caretFrame.offsetBy(dx: -view.contentOffset.x, dy: -view.contentOffset.y)
        let visible = frame.height > 0 && frame.maxY > 0 && frame.minY < view.bounds.height && !view.selectionActive
        let value = visible ? frame : nil
        if cursorRowBounds != value { cursorRowBounds = value }
        if visible {
            let terminal = view.getTerminal()
            if let row = terminal.getLine(row: terminal.getCursorLocation().y) { cursorControls.observe(row: row.translateToString(trimRight: true)) }
            updateCursorKey()
        }
    }
    @objc private func pinchFont(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .began { inputGestureHadPinch = true; scrollGeneration = nil; swipeGeneration = nil; swipeHold?.cancel(); swipeHold = nil }
        if recognizer.state == .ended { onFontScaled?(Double(terminalView.font.pointSize.rounded())); return }
        guard recognizer.state == .changed else { return }
        let size = min(28, max(8, terminalView.font.pointSize * recognizer.scale))
        terminalView.font = terminalView.font.withSize(size); recognizer.scale = 1
        queueCursorRefresh()
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        columns = max(2, newCols); rows = max(2, newRows)
        if let mosh { mosh.resize(columns: columns, rows: rows) } else { ssh?.resize(columns: columns, rows: rows) }
        queueCursorRefresh()
    }
    func setTerminalTitle(source: TerminalView, title: String) { terminalTitle = String(title.prefix(200)) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        if let url = URL(string: directory), url.scheme == "file" { currentDirectory = url.path }
        else if directory.hasPrefix("/") { currentDirectory = directory }
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if capturedPaste != nil {
            if data.count <= TerminalPaste.byteLimit + 12 - capturedPaste!.count { capturedPaste?.append(contentsOf: data) }
            else { capturedPasteTooLarge = true }
            return
        }
        if sendingScrollEvent { _ = send(Data(data)); return }
        var bytes = Data(data)
        if shiftArmed, let string = String(data: bytes, encoding: .utf8) { bytes = Data(string.uppercased().utf8); shiftArmed = false }
        if send(bytes) { userTyped(bytes) }
        if controlArmed { controlArmed = false; terminalView.controlModifier = false }
    }
    func scrolled(source: TerminalView, position: Double) { queueCursorRefresh() }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        UIApplication.shared.open(url)
    }
    func bell(source: TerminalView) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    func clipboardCopy(source: TerminalView, content: Data) { /* OSC 52 is intentionally ignored. Native selection copying remains available. */ }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { outputRevision += 1; queueCursorRefresh() }
}
func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

struct NativeTerminal: UIViewRepresentable {
    @ObservedObject var runtime: SessionRuntime
    @ObservedObject private var fonts = FontCatalog.shared
    var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    func makeUIView(context: Context) -> TerminalView { runtime.configure(settings: settings, scheme: scheme); return runtime.terminalView }
    func updateUIView(_ view: TerminalView, context: Context) { runtime.configure(settings: settings, scheme: scheme) }
    static func dismantleUIView(_ view: TerminalView, coordinator: ()) { view.resignFirstResponder() }
}

@MainActor private final class AccessibleTerminalView: TerminalView {
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
    override func mouseModeChanged(source: Terminal) {
        // SwiftTerm's implementation adds a button-drag recognizer even with
        // allowMouseReporting=false. Only our vertical wheel recognizer reports
        // mouse input; native long-press selection must remain local.
        viewportChanged?()
    }
    override init(frame: CGRect) {
        super.init(frame: frame); terminalReady = true
        getTerminal().setCursorStyle(.steadyBlock)
        isAccessibilityElement = true; accessibilityLabel = "Terminal"; accessibilityTraits = [.updatesFrequently]
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder); terminalReady = true
        getTerminal().setCursorStyle(.steadyBlock)
        isAccessibilityElement = true; accessibilityLabel = "Terminal"
    }
    override var accessibilityValue: String? {
        get { String(decoding: getTerminal().getBufferAsData().suffix(16_384), as: UTF8.self) }
        set { }
    }
}

/// Observes the initial workspace press without recognizing or consuming a gesture.
@MainActor private final class TerminalTouchObserver: UIGestureRecognizer {
    let touched: () -> Void
    init(touched: @escaping () -> Void) {
        self.touched = touched
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { touched(); state = .failed }
}
