import UIKit
import SwiftTerm
import RoamttyCore

/// A vertical swipe carried on after the finger lifts; see `TerminalScrollInertia`.
struct ScrollFling {
    var inertia: TerminalScrollInertia
    let start: CFTimeInterval
    let point: CGPoint
    /// The connection it started on; a fling stops with it.
    let generation: UUID
    let disposition: TerminalScrollDisposition
}

/// Android's terminal gestures: taps place the cursor, complete or paste; a sideways swipe sends arrows; a vertical
/// swipe scrolls the host's screen; a pinch zooms the font.
extension SessionRuntime: UIGestureRecognizerDelegate {
    func installGestures() {
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
        let touchObserver = TerminalTouchObserver { [weak self] in
            self?.workspaceTouches += 1; self?.inputGestureHadPinch = false; self?.stopScrollInertia()
        }
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
        ownRecognizers = [single, double, triple, touchObserver, swipe, scroll, pinch]
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === selectionTap { return terminalView.selectionActive }
        return !terminalView.selectionActive
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

    // MARK: Geometry

    /// Input typed now lands at the live cursor: connected, nothing selected, scrolled to the bottom.
    private var writableViewport: Bool { phase == .connected && !terminalView.selectionActive && (!terminalView.canScroll || terminalView.scrollPosition >= 1) }
    private var scrollDisposition: TerminalScrollDisposition {
        let terminal = terminalView.getTerminal()
        return TerminalScrolling.disposition(connected: phase == .connected, selecting: terminalView.selectionActive,
                                             mouseTracking: terminal.mouseMode != .off, alternate: terminal.isCurrentBufferAlternate)
    }
    private var cellSize: CGSize {
        let terminal = terminalView.getTerminal(), optimal = terminalView.getOptimalFrameSize()
        return CGSize(width: optimal.width / CGFloat(max(1, terminal.cols)), height: optimal.height / CGFloat(max(1, terminal.rows)))
    }

    // MARK: Vertical scrolling

    @objc private func verticalScroll(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began: scrollGeneration = generation; scrollAccumulator.reset(); stopScrollInertia()
        case .changed: break
        case .ended:
            defer { scrollGeneration = nil; scrollAccumulator.reset() }
            guard !inputGestureHadPinch, scrollGeneration == generation else { return }
            startScrollInertia(velocityY: recognizer.velocity(in: terminalView).y, at: recognizer.location(in: terminalView))
            return
        case .cancelled, .failed: scrollGeneration = nil; scrollAccumulator.reset(); return
        default: return
        }
        guard !inputGestureHadPinch, scrollGeneration == generation, recognizer.numberOfTouches == 1 else { scrollGeneration = nil; return }
        let disposition = scrollDisposition
        guard disposition == .wheel || disposition == .arrows else { scrollGeneration = nil; return }
        let rows = scrollAccumulator.rowsDown(translationY: recognizer.translation(in: terminalView).y, rowHeight: cellSize.height)
        scrollRemotely(rows: rows, disposition: disposition, at: recognizer.location(in: terminalView))
    }
    /// Scrolls the host's screen: arrow keys for a full-screen app without mouse support, else mouse wheel events.
    private func scrollRemotely(rows: Int, disposition: TerminalScrollDisposition, at position: CGPoint) {
        guard rows != 0 else { return }
        let terminal = terminalView.getTerminal()
        if disposition == .arrows {
            let key = TerminalKeys.arrow(rows < 0 ? "A" : "B", applicationCursor: terminal.applicationCursor, control: false, shift: false)
            _ = send(String(repeating: key, count: abs(rows)))
        } else {
            let cell = cellSize
            let point = TerminalScrolling.mousePoint(CGPoint(x: position.x - terminalView.contentOffset.x, y: position.y - terminalView.contentOffset.y), cell: cell, columns: terminal.cols, rows: terminal.rows)
            let flags = terminal.encodeButton(button: TerminalScrolling.mouseButton(rowsDown: rows), release: false, shift: false, meta: false, control: false)
            sendingScrollEvent = true
            defer { sendingScrollEvent = false }
            for _ in 0..<abs(rows) {
                terminal.sendEvent(buttonFlags: flags, x: point.column, y: point.row, pixelX: point.pixelX, pixelY: point.pixelY)
            }
        }
    }
    /// A finger moving up scrolls down, so the fling runs against the touch velocity.
    private func startScrollInertia(velocityY: CGFloat, at position: CGPoint) {
        stopScrollInertia()
        let disposition = scrollDisposition, rowHeight = cellSize.height
        guard disposition == .wheel || disposition == .arrows, rowHeight > 0,
              let inertia = TerminalScrollInertia(rowsPerSecond: -Double(velocityY / rowHeight), screenRows: terminalView.getTerminal().rows) else { return }
        fling = ScrollFling(inertia: inertia, start: CACurrentMediaTime(), point: position, generation: generation, disposition: disposition)
        let link = CADisplayLink(target: self, selector: #selector(stepScrollInertia(_:)))
        link.add(to: .main, forMode: .common); flingLink = link
    }
    @objc private func stepScrollInertia(_ link: CADisplayLink) {
        // Like Android, a fling stops once the session or the host's scrolling mode changes under it.
        guard var current = fling, current.generation == generation, scrollDisposition == current.disposition else { stopScrollInertia(); return }
        let rows = current.inertia.rowsDown(after: link.targetTimestamp - current.start)
        fling = current
        scrollRemotely(rows: rows, disposition: current.disposition, at: current.point)
        if current.inertia.finished { stopScrollInertia() }
    }
    func stopScrollInertia() {
        flingLink?.invalidate(); flingLink = nil
        fling = nil
    }

    // MARK: Sideways swipes

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
    /// Holding a sideways swipe for half a second jumps to the line's start or end (Ctrl-A / Ctrl-E).
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

    // MARK: Taps

    @objc private func cursorTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        if let link = link(at: recognizer.location(in: terminalView)) { open(link); return }
        guard phase == .connected else { return }
        UIMenuController.shared.hideMenu()
        refreshCursor()
        guard let row = cursorRowBounds else { return }
        // The user now decides about the keyboard: an earlier Enter's delayed hide must not undo it.
        keyboardHide?.cancel()
        let y = recognizer.location(in: terminalView).y - terminalView.contentOffset.y
        if TerminalCursorControls.tapHitsCursor(y: y, rowTop: row.minY, rowHeight: row.height, viewportHeight: terminalView.bounds.height) { terminalView.becomeFirstResponder() }
        // iPhone keyboards have no dismiss key and there is no Back button: a reading tap elsewhere puts it away.
        else if terminalView.isFirstResponder { terminalView.resignFirstResponder() }
    }
    @objc private func completionTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, phase == .connected else { return }
        clearModifiers()
        if send("\t") { wakeCursor(); petArrowTouches += 1 }
    }
    @objc private func pasteTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, phase == .connected else { return }
        clearModifiers(); paste()
    }
    /// The complete HTTP(S) URL under a tap, including soft and TUI hard wraps and scrolled history.
    private func link(at point: CGPoint) -> String? {
        let cell = cellSize
        let x = point.x - terminalView.contentOffset.x, y = point.y - terminalView.contentOffset.y
        guard cell.width > 0, cell.height > 0, x >= 0, y >= 0 else { return nil }
        return TerminalUrl.at(SwiftTermTextGrid(terminal: terminalView.getTerminal()), column: Int(x / cell.width), row: Int(y / cell.height))
    }
    /// iOS hands GitHub and other universal links to their app when it is installed, else to the browser.
    private func open(_ link: String) {
        guard let url = terminalLinkTarget(link) else { return }
        UIApplication.shared.open(url) { [weak self] opened in
            if !opened { self?.message = "无法打开链接：\(link) / Cannot open link: \(link)" }
        }
    }

    // MARK: Pinch

    @objc private func pinchFont(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .began { inputGestureHadPinch = true; scrollGeneration = nil; stopScrollInertia(); swipeGeneration = nil; swipeHold?.cancel(); swipeHold = nil }
        if recognizer.state == .ended { onFontScaled?(Double(terminalView.font.pointSize.rounded())); return }
        guard recognizer.state == .changed else { return }
        let size = min(28, max(8, terminalView.font.pointSize * recognizer.scale))
        terminalView.font = terminalView.font.withSize(size); recognizer.scale = 1
        queueCursorRefresh()
    }
}
