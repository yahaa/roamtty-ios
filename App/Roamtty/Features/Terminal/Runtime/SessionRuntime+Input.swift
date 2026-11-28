import UIKit
import SwiftTerm
import RoamttyCore

/// What the user sends to the host: keys, pastes and the toolbox's keys, plus the keyboard and the cursor-row
/// controls that follow the typing.
extension SessionRuntime {
    // MARK: Sending

    @discardableResult func send(_ string: String) -> Bool { send(Data(string.utf8)) }
    @discardableResult func send(_ data: Data, reportFailure: Bool = true) -> Bool {
        keyboardDeleteHold.reset()
        return write(data, reportFailure: reportFailure)
    }
    private func write(_ data: Data, reportFailure: Bool = true) -> Bool {
        guard phase == .connected else { return false }
        if voice.awaitingManualStatus {
            voice.codexInputRevision &+= 1
            if data.count == 1, let key = data.first, key == 13 || key == 10, hasCodexStatusCommand {
                voice.pendingCodexStatus = Data()
                voice.awaitingManualStatus = false
            }
        }
        let sent = mosh?.write(data) ?? ssh?.write(data) ?? false
        if !sent && reportFailure { message = "输入未发送 / Input was not sent" }
        if sent { lastTerminalWriteAt = ProcessInfo.processInfo.systemUptime }
        return sent
    }
    /// A delete from the keyboard: holding the key clears the line once (`TerminalDeleteHold`).
    func sendKeyboardDelete(_ bytes: Data) {
        switch keyboardDeleteHold.onDelete(at: ProcessInfo.processInfo.systemUptime) {
        case .delete:
            if write(bytes) { userTyped(bytes) }
            if controlArmed { clearModifiers() }
        case .clear:
            clearModifiers(); terminalView.scrollToLiveOutput()
            if write(TerminalDeleteHold.clearLine) { userTyped(TerminalDeleteHold.clearLine) }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .ignore:
            userTyped(bytes)
        }
    }
    /// The Up/Down/Left keys around the toolbox pet.
    func sendPetArrow(_ final: String) {
        let control = controlArmed, shift = shiftArmed
        clearModifiers(); terminalView.scrollToLiveOutput()
        if send(TerminalKeys.arrow(final, applicationCursor: terminalView.getTerminal().applicationCursor, control: control, shift: shift)) { petArrowTouches += 1 }
    }
    func sendCursorKey(_ key: CursorRowKey) {
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
    /// SwiftTerm owns selection cleanup and reads the clipboard once. Its delegate output is staged in
    /// `capturedPaste` until the whole paste can be validated and enqueued.
    func finishNativePaste() {
        guard let capture = capturedPaste else { return }
        capturedPaste = nil
        if capture.tooLarge { message = TerminalPaste.tooLargeMessage; return }
        guard let text = capture.text else { return }
        _ = pasteText(text)
    }
    /// What the visible terminal screen currently shows, without assuming `launchedAgent` is still running.
    func detectScreenApp() -> ScreenApp {
        let terminal = terminalView.getTerminal()
        let lines = (0..<terminal.rows).map { terminal.getLine(row: $0)?.screenText ?? "" }
        return ScreenApp.detect(rows: lines, cursorRow: terminal.getCursorLocation().y)
    }
    var hasCodexStatusCommand: Bool {
        let terminal = terminalView.getTerminal()
        return writableViewport && terminal.getLine(row: terminal.getCursorLocation().y)?.screenText.trimmingCharacters(in: .whitespaces) == "› /status"
    }

    /// A dim Codex placeholder at the insertion point establishes that no draft is present.
    var hasEmptyCodexComposer: Bool {
        let terminal = terminalView.getTerminal(), cursor = terminal.getCursorLocation()
        guard writableViewport, ProcessInfo.processInfo.systemUptime - lastTerminalWriteAt > 0.75,
              cursor.x == 2, terminal.getCharacter(col: 0, row: cursor.y) == "›",
              cursor.x < terminal.cols else { return false }
        var hasPlaceholder = false
        for col in cursor.x..<terminal.cols {
            guard let cell = terminal.getCharData(col: col, row: cursor.y) else { continue }
            let character = cell.getCharacter()
            if character == "\0" || character.isWhitespace { continue }
            guard cell.attribute.style.contains(.dim) else { return false }
            hasPlaceholder = true
        }
        return hasPlaceholder
    }

    func refreshDetectedScreen() {
        let next = detectScreenApp()
        if detectedScreen != next { detectedScreen = next }
    }
    /// The agent currently active in this session (reported by hooks, launching, or visible on screen).
    func screenApp() -> ScreenApp {
        if let agent = activeAgentKind { return ScreenApp(agent) }
        return detectScreenApp()
    }

    // MARK: Keyboard

    func hideKeyboard() { keyboardHide?.cancel(); _ = terminalView.resignFirstResponder() }
    func hideKeyboardSoon() {
        keyboardHide?.cancel()
        keyboardHide = Task { [weak self] in
            // Enter puts the keyboard away after 15 s without typing, so a follow-up line can still be typed.
            do { try await Task.sleep(for: .seconds(15)); _ = self?.terminalView.resignFirstResponder() } catch { }
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
                if typing { try await Task.sleep(for: .milliseconds(700)); self?.updateCursorKey() }
                try await Task.sleep(for: .seconds(3)); self?.updateCursorKey()
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
        finishCursorTap()
        if visible {
            let terminal = view.getTerminal()
            if let row = terminal.getLine(row: terminal.getCursorLocation().y) { cursorControls.observe(row: row.screenText) }
            if slashCommandLine != cursorControls.onSlashLine { slashCommandLine = cursorControls.onSlashLine }
            updateCursorKey()
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastScreenDetectAt >= 0.5 {
            lastScreenDetectAt = uptime
            refreshDetectedScreen()
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
