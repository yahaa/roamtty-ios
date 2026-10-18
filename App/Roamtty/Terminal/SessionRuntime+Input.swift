import UIKit
import SwiftTerm
import RoamttyCore

/// What the user sends to the host: keys, pastes and the toolbox's keys, plus the keyboard and the cursor-row
/// controls that follow the typing.
extension SessionRuntime {
    // MARK: Sending

    @discardableResult func send(_ string: String) -> Bool { send(Data(string.utf8)) }
    @discardableResult func send(_ data: Data) -> Bool {
        guard phase == .connected else { return false }
        let sent = mosh?.write(data) ?? ssh?.write(data) ?? false
        if !sent { message = "输入未发送 / Input was not sent" }
        return sent
    }
    /// The Up/Down/Left keys around the toolbox pet.
    func sendPetArrow(_ final: String) {
        let control = controlArmed, shift = shiftArmed
        clearModifiers(); terminalView.scrollToLiveOutput()
        if send(TerminalKeys.arrow(final, applicationCursor: terminalView.getTerminal().applicationCursor, control: control, shift: shift)) { petArrowTouches += 1 }
    }
    func sendCursorKey(_ key: CursorRowKey, up: Bool = false) {
        clearModifiers()
        terminalView.scrollToLiveOutput()
        let value: String
        switch key {
        case .enter: value = "\r"
        case .escape: value = "\u{1b}"
        }
        guard send(value) else { return }
        if key != .escape { wakeCursor() }
        if key == .enter { hideKeyboardSoon() }
    }
    func armControl() { controlArmed.toggle(); terminalView.controlModifier = controlArmed }
    func clearModifiers() { controlArmed = false; shiftArmed = false; terminalView.controlModifier = false }

    // MARK: Paste and copy

    func paste() { terminalView.paste(nil) }
    @discardableResult func pasteText(_ text: String, confirmed: Bool = false) -> Bool {
        guard phase == .connected else { return false }
        guard text.utf8.count <= TerminalPaste.byteLimit else { message = TerminalPaste.tooLargeMessage; return false }
        let bracketed = terminalView.getTerminal().bracketedPasteMode
        if !confirmed && TerminalPaste.needsConfirmation(text, bracketed: bracketed) { pendingPaste = text; return false }
        guard let input = try? TerminalPaste.input(text, bracketed: bracketed) else { return false }
        clearModifiers(); terminalView.scrollToLiveOutput()
        let accepted = send(input)
        if accepted { userTyped(Data(input.utf8)) }
        return accepted
    }
    @discardableResult func confirmPendingPaste() -> Bool {
        guard let text = pendingPaste else { return false }
        pendingPaste = nil
        return pasteText(text, confirmed: true)
    }
    /// SwiftTerm owns selection cleanup and reads the clipboard once. Its delegate output is staged in
    /// `capturedPaste` until the whole paste can be validated and enqueued.
    func finishNativePaste() {
        guard let capture = capturedPaste else { return }
        capturedPaste = nil
        if capture.tooLarge { message = TerminalPaste.tooLargeMessage; return }
        guard let text = capture.text else { return }
        _ = pasteText(text)
    }
    func copySelection() { terminalView.copy(nil) }
    /// The agent the session was started for, else the one its hooks report, else what the screen shows (an agent
    /// started by hand in a plain session).
    func screenApp() -> ScreenApp {
        if let agent = launchedAgent ?? CodingAgent.fromCommand(agentStatus?.agent) { return ScreenApp(agent) }
        let terminal = terminalView.getTerminal()
        let lines = (0..<terminal.rows).map { terminal.getLine(row: $0)?.screenText ?? "" }
        return ScreenApp.detect(rows: lines, cursorRow: terminal.getCursorLocation().y)
    }

    // MARK: Keyboard

    func hideKeyboard() { keyboardHide?.cancel(); terminalView.resignFirstResponder() }
    func toggleKeyboard() { keyboardHide?.cancel(); if terminalView.isFirstResponder { terminalView.resignFirstResponder() } else { terminalView.becomeFirstResponder() } }
    func hideKeyboardSoon() {
        keyboardHide?.cancel()
        keyboardHide = Task { [weak self] in
            // Enter puts the keyboard away after 15 s without typing, so a follow-up line can still be typed.
            do { try await Task.sleep(nanoseconds: 15_000_000_000); self?.terminalView.resignFirstResponder() } catch { }
        }
    }

    // MARK: Cursor-row controls

    func userTyped(_ data: Data) {
        keyboardHide?.cancel()
        cursorControls.typed(at: Date.timeIntervalSinceReferenceDate)
        updateCursorKey()
        scheduleCursorTimer(typing: true)
        if data == Data([13]) || data == Data([10]) { hideKeyboardSoon() }
    }
    func wakeCursor() {
        cursorControls.wake(at: Date.timeIntervalSinceReferenceDate)
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
    private func updateCursorKey() {
        let key = cursorControls.key(at: Date.timeIntervalSinceReferenceDate)
        if cursorRowKey != key { cursorRowKey = key }
    }
    /// Refreshes the cursor-row controls once per main-loop turn, however many updates arrive in it.
    func queueCursorRefresh() {
        guard !cursorRefreshQueued else { return }
        cursorRefreshQueued = true
        DispatchQueue.main.async { [weak self] in self?.cursorRefreshQueued = false; self?.refreshCursor() }
    }
    func refreshCursor() {
        let view = terminalView
        let frame = view.caretFrame.offsetBy(dx: -view.contentOffset.x, dy: -view.contentOffset.y)
        let visible = frame.height > 0 && frame.maxY > 0 && frame.minY < view.bounds.height && !view.selectionActive
        let value = visible ? frame : nil
        if cursorRowBounds != value { cursorRowBounds = value }
        if visible {
            let terminal = view.getTerminal()
            if let row = terminal.getLine(row: terminal.getCursorLocation().y) { cursorControls.observe(row: row.screenText) }
            if slashCommandLine != cursorControls.onSlashLine { slashCommandLine = cursorControls.onSlashLine }
            updateCursorKey()
        }
    }
}

extension BufferLine {
    /// The row as Android reads it, with a space for each cell never written. SwiftTerm gives those as "\0", and
    /// Codex skips its blank cells when it draws, so its prompt read "›\0Ask Codex…" and was not taken for one.
    var screenText: String {
        translateToString(trimRight: true) { cell in
            let character = cell.getCharacter()
            return character == "\0" ? " " : character
        }
    }
}
