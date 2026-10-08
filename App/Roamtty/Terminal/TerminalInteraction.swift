import Foundation

enum CursorRowKey: Equatable { case escape, enter, arrows }

/// Mirrors Android's cursor-row controls, using screen contents rather than guessed keystrokes.
struct TerminalCursorControls {
    private var slashLine = 0
    private var nextSlashLine = 0
    private var dismissedSlashLine = 0
    private var enterFrom: TimeInterval = .infinity
    private var enterUntil: TimeInterval = 0

    mutating func observe(row: String) {
        if Self.startsWithSlash(row) {
            if slashLine == 0 { nextSlashLine += 1; slashLine = nextSlashLine }
        } else { slashLine = 0 }
    }
    mutating func typed(at time: TimeInterval) {
        enterFrom = time + 0.7
        enterUntil = enterFrom + 3
    }
    mutating func wake(at time: TimeInterval, dismissSlash: Bool = false) {
        enterFrom = time
        enterUntil = time + 3
        if dismissSlash { dismissedSlashLine = slashLine }
    }
    func key(at time: TimeInterval) -> CursorRowKey {
        if slashLine != 0 && (slashLine != dismissedSlashLine || time >= enterUntil) { return .arrows }
        return time >= enterFrom && time < enterUntil ? .enter : .escape
    }
    static func startsWithSlash(_ row: String) -> Bool {
        let chars = Array(row.unicodeScalars)
        func blank(_ c: Unicode.Scalar) -> Bool { CharacterSet.whitespacesAndNewlines.contains(c) || c.value == 0xa0 }
        func skip(_ start: Int) -> Int {
            var index = start
            while index < chars.count && (blank(chars[index]) || (0x2500...0x259f).contains(chars[index].value)) { index += 1 }
            return index
        }
        var index = skip(0)
        let prompts = "❯›>»▶➜$#%".unicodeScalars
        if index < chars.count, prompts.contains(chars[index]), index + 1 == chars.count || blank(chars[index + 1]) { index = skip(index + 1) }
        return index < chars.count && chars[index] == "/"
    }
    static func tapHitsCursor(y: Double, rowTop: Double, rowHeight: Double, viewportHeight: Double) -> Bool {
        guard rowHeight > 0, rowTop + rowHeight > 0, rowTop < viewportHeight else { return false }
        let half = max(rowHeight * 2.5, 32)
        let top = max(0, rowTop + rowHeight / 2 - half)
        return y >= top && y < min(viewportHeight, top + half * 2)
    }
}

struct TerminalStartupGate {
    let needsTmuxClient: Bool
    let requiresOutput: Bool
    let previousClients: Set<String>
    var sawOutput = false
    private(set) var sawNewClient = false
    var ready: Bool { (!requiresOutput || sawOutput) && (!needsTmuxClient || sawNewClient) }
    mutating func observe(clients: Set<String>) { sawNewClient = !clients.subtracting(previousClients).isEmpty }
    static func clients(from output: String) -> Set<String> {
        let prefix = "__ROAMTTY_CLIENT__"
        return Set(output.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix(prefix) else { return nil }
            let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            let fields = value.split(separator: "|", maxSplits: 1)
            guard fields.count == 2, let pid = Int(fields[0]), pid > 0, fields[1].hasPrefix("/") else { return nil }
            return value
        })
    }
}

/// The Android collapsed pet and released shortcut ring have independent idle clocks.
struct TerminalToolboxState {
    private(set) var pinned = false
    private(set) var expanded = false
    private(set) var awake = true
    private(set) var ringOpen = false
    private(set) var ringPinned = false
    private var ghostDeadline: TimeInterval = 0
    private var ringDeadline: TimeInterval = 0
    var dockVisible: Bool { pinned || expanded }
    var ghostVisible: Bool { !dockVisible && (awake || ringOpen) }
    var deadline: TimeInterval? { dockVisible ? nil : ringOpen ? (ringPinned ? ringDeadline : nil) : awake ? ghostDeadline : nil }
    mutating func wake(at time: TimeInterval) { awake = true; ghostDeadline = time + 5; if ringPinned { ringDeadline = time + 4 } }
    mutating func workspaceTouch(at time: TimeInterval) { if !pinned { expanded = false }; wake(at: time) }
    mutating func setPinned(_ value: Bool, at time: TimeInterval) { pinned = value; expanded = value; closeRing(); wake(at: time) }
    mutating func openDock(at time: TimeInterval) { expanded = true; closeRing(); wake(at: time) }
    mutating func collapseDock(at time: TimeInterval) { pinned = false; expanded = false; closeRing(); wake(at: time) }
    mutating func beginRing(at time: TimeInterval) { ringOpen = true; ringPinned = false; wake(at: time) }
    mutating func pinRing(at time: TimeInterval) { ringOpen = true; ringPinned = true; wake(at: time) }
    mutating func completeRing(at time: TimeInterval) { closeRing(); wake(at: time) }
    mutating func dismissRing() { closeRing(); awake = false }
    mutating func closeRing() { ringOpen = false; ringPinned = false }
    mutating func expire(at time: TimeInterval) {
        guard !dockVisible else { return }
        if ringPinned && time >= ringDeadline { dismissRing() }
        else if !ringOpen && time >= ghostDeadline { awake = false }
    }
}

enum TerminalDockGeometry {
    static func twoColumns(landscape: Bool, keyboardVisible: Bool, height: CGFloat) -> Bool { landscape && !keyboardVisible && height - 8 >= 320 }
    static func frame(viewport: CGSize, content: CGSize, endInset: CGFloat = 8, avoiding obstacle: CGRect? = nil) -> CGRect {
        let margin = min(4, viewport.height / 2), inset = min(endInset, viewport.width)
        let size = CGSize(width: min(content.width, max(0, viewport.width - inset)), height: min(content.height, max(0, viewport.height - 2 * margin)))
        let ideal = viewport.height * 0.382 - size.height / 2
        var frame = CGRect(x: viewport.width - inset - size.width, y: min(max(margin, ideal), max(margin, viewport.height - margin - size.height)), width: size.width, height: size.height)
        if let obstacle, frame.intersects(obstacle.insetBy(dx: -4, dy: -4)) {
            let candidates = [obstacle.minY - 8 - size.height, obstacle.maxY + 8].filter { $0 >= margin && $0 + size.height <= viewport.height - margin }
            if let y = candidates.min(by: { abs($0 - ideal) < abs($1 - ideal) }) { frame.origin.y = y }
            else { frame.origin.x = max(0, obstacle.minX - 8 - size.width) }
        }
        return frame
    }
}

enum TerminalPaste {
    enum Failure: Error { case tooLarge }
    static let byteLimit = 128 * 1024
    static func needsConfirmation(_ text: String, bracketed: Bool) -> Bool { !bracketed && (text.contains("\n") || text.contains("\r")) }
    static func input(_ text: String, bracketed: Bool) throws -> String {
        guard text.utf8.count <= byteLimit else { throw Failure.tooLarge }
        let scalars = text.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || ($0.value >= 32 && !(127...159).contains($0.value)) }
        let cleaned = String(String.UnicodeScalarView(scalars)).replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        return bracketed ? "\u{1b}[200~" + cleaned + "\u{1b}[201~" : cleaned
    }
}

enum TerminalKeys {
    static func arrow(_ final: String, applicationCursor: Bool, control: Bool, shift: Bool) -> String {
        let modifier = 1 + (shift ? 1 : 0) + (control ? 4 : 0)
        return modifier == 1 ? "\u{1b}" + (applicationCursor ? "O" : "[") + final : "\u{1b}[1;\(modifier)" + final
    }
    static func function(_ number: Int, control: Bool, shift: Bool) -> String? {
        guard (1...12).contains(number) else { return nil }
        let modifier = 1 + (shift ? 1 : 0) + (control ? 4 : 0)
        if number <= 4 {
            let final = ["P", "Q", "R", "S"][number - 1]
            return modifier == 1 ? "\u{1b}O" + final : "\u{1b}[1;\(modifier)" + final
        }
        let code = [15, 17, 18, 19, 20, 21, 23, 24][number - 5]
        return "\u{1b}[\(code)" + (modifier == 1 ? "" : ";\(modifier)") + "~"
    }
    static func swipeDirection(x: Double, y: Double) -> Int? {
        guard abs(x) >= 32, abs(x) > 1.5 * abs(y) else { return nil }
        return x < 0 ? -1 : 1
    }
}

enum TerminalScrollDisposition: Equatable { case ignored, local, wheel, arrows }
enum TerminalScrolling {
    static func disposition(connected: Bool, selecting: Bool, mouseTracking: Bool, alternate: Bool) -> TerminalScrollDisposition {
        if !connected || selecting { return .ignored }
        if mouseTracking { return .wheel }
        return alternate ? .arrows : .local
    }
    static func mouseButton(rowsDown: Int) -> Int { rowsDown < 0 ? 4 : 5 }
    static func mousePoint(_ point: CGPoint, cell: CGSize, columns: Int, rows: Int) -> (column: Int, row: Int, pixelX: Int, pixelY: Int) {
        let width = max(1, cell.width), height = max(1, cell.height)
        let x = min(max(0, point.x), width * CGFloat(max(1, columns)) - 1)
        let y = min(max(0, point.y), height * CGFloat(max(1, rows)) - 1)
        // SwiftTerm 1.13's legacy X10 encoder converts (cell+33) to UInt8 before
        // clamping. Keep the shared API safe even when a wide window exceeds it.
        return (min(222, Int(x / width)), min(222, Int(y / height)), Int(x) + 1, Int(y) + 1)
    }
}
struct TerminalScrollAccumulator {
    private var previous: Double = 0
    private var remainder: Double = 0
    mutating func reset() { previous = 0; remainder = 0 }
    mutating func rowsDown(translationY: Double, rowHeight: Double) -> Int {
        guard translationY.isFinite, rowHeight.isFinite, rowHeight > 0 else { return 0 }
        let distance = previous - translationY + remainder
        previous = translationY
        remainder = distance.truncatingRemainder(dividingBy: rowHeight)
        return Int(min(256, max(-256, distance / rowHeight)))
    }
}
