import Foundation

/// Frames for the SSH channel, written in order by the stream's writer thread.
/// Bounds queued live voice `MIC_AUDIO` frames by dropping oldest mic chunks under backpressure
/// while keeping control frames (`SPK_ACK`, `CONFIG`, `PING`) intact.
final class DesktopOutQueue {
    static let maxQueuedMicFrames = 20

    private let cond = NSCondition()
    private var items: [[UInt8]] = []
    private var queuedMicFrames = 0
    private var closed = false

    private func isMic(_ frame: [UInt8]) -> Bool {
        frame.first == UInt8(VoiceProtocol.MIC_AUDIO) || frame.first == UInt8(VoiceProtocol.MIC_OPUS)
    }

    func send(_ b: [UInt8]) {
        cond.lock()
        if !closed {
            if isMic(b) {
                while queuedMicFrames >= Self.maxQueuedMicFrames,
                      let oldest = items.firstIndex(where: isMic) {
                    items.remove(at: oldest)
                    queuedMicFrames -= 1
                }
                queuedMicFrames += 1
            }
            items.append(b)
            cond.signal()
        }
        cond.unlock()
    }

    func close() {
        cond.lock()
        closed = true
        items.removeAll()
        queuedMicFrames = 0
        cond.broadcast()
        cond.unlock()
    }

    /// Everything queued, or nil once closed.
    func take() -> [[UInt8]]? {
        cond.lock(); defer { cond.unlock() }
        while items.isEmpty && !closed { cond.wait() }
        if closed { return nil }
        let out = items; items.removeAll(); queuedMicFrames = 0; return out
    }
}

/// Runs `body` every `intervalMs` on its own thread until `stop`.
final class DesktopTicker: @unchecked Sendable {
    private let cond = NSCondition()
    private var stopped = false

    init(intervalMs: Int64, _ body: @escaping () -> Void) {
        let t = Thread { [self] in
            cond.lock()
            while !stopped {
                cond.unlock()
                body()
                cond.lock()
                if stopped { break }
                _ = cond.wait(until: Date().addingTimeInterval(Double(intervalMs) / 1000))
            }
            cond.unlock()
        }
        t.name = "roamtty.desktop.ticker"
        t.start()
    }

    func stop() { cond.lock(); stopped = true; cond.broadcast(); cond.unlock() }
}

/// The once-a-second ping that measures the round trip. A value type: the session mutates it under its lock.
struct DesktopPingClock {
    private var sentUs: Int64 = 0
    private var answered = true
    private var resetAtUs: Int64 = 0
    private(set) var missed = 0
    private var smoothedRtt = -1.0
    private var samples = 0

    /// The smoothed round trip in ms; 0 until three answers came.
    var rttMs: Int { (smoothedRtt >= 0 && samples >= 3) ? Int(smoothedRtt) : 0 }

    /// The timestamp of the ping to send now: the first one, or the next a second after the last one left.
    mutating func due(nowUs: Int64) -> Int64? {
        if answered && resetAtUs != 0 && nowUs >= resetAtUs { sentUs = 0; resetAtUs = 0 }
        guard sentUs == 0 else { return nil }
        answered = false; sentUs = nowUs
        return nowUs
    }

    /// A ping unanswered past `lateMs` is sent again (UDP may have dropped it) and counted as missed.
    mutating func resendIfLate(nowUs: Int64, lateMs: Int64) -> Int64? {
        let waiting = (!answered && sentUs != 0) ? (nowUs - sentUs) / 1000 : 0
        guard waiting > lateMs else { return nil }
        missed += 1; sentUs = nowUs
        return nowUs
    }

    /// The answer to the ping sent at `t1`: its round trip in ms, nil for an answer to an older ping.
    mutating func answer(t1: Int64, nowUs: Int64) -> Int? {
        guard t1 == sentUs && !answered else { return nil }
        answered = true
        missed = 0
        let rtt = Int((nowUs - t1) / 1000)
        smoothedRtt = smoothedRtt < 0 ? Double(rtt) : smoothedRtt * 0.75 + Double(rtt) * 0.25
        samples += 1
        // The next ping goes a second after this one left.
        resetAtUs = nowUs + Int64(max(0, 1000 - rtt)) * 1000
        return rtt
    }
}

/// Which video frames may reach the decoder. A value type: the session mutates it under its lock.
struct DesktopVideoOrder {
    enum Verdict { case stale, broken, ok }

    private var lastFrame: Int64 = -1
    private var brokenUntilKey = false

    /// A new stream: its first frame must be a keyframe.
    mutating func restart() { lastFrame = -1; brokenUntilKey = true }

    /// Nothing decodes until the next keyframe (the page came back).
    mutating func awaitKeyframe() { brokenUntilKey = true }

    mutating func accept(frame: Int64, keyframe: Bool) -> Verdict {
        // Both transports may deliver around a switch: older frames than the newest are stale.
        if frame <= lastFrame { return .stale }
        // A frame lost on UDP breaks every frame after it that refers back to it: decoding them
        // smeared the picture into stripes. Hold the last good picture until a keyframe.
        if !keyframe && lastFrame >= 0 && frame != lastFrame + 1 { brokenUntilKey = true }
        lastFrame = frame
        if keyframe { brokenUntilKey = false }
        return brokenUntilKey ? .broken : .ok
    }
}

/// At most one keyframe request a second: a lost frame on UDP otherwise asks for each one after it.
/// A request inside that second waits for it rather than vanishing, or a still screen would stay broken.
struct DesktopKeyframeThrottle {
    private var lastAskMs: Int64 = 0
    private(set) var pending = false

    /// Whether to ask now; otherwise the request stays pending for the next tick.
    mutating func shouldAsk(nowMs: Int64) -> Bool {
        if nowMs - lastAskMs < 1000 { pending = true; return false }
        pending = false; lastAskMs = nowMs
        return true
    }

    /// The next request goes out at once.
    mutating func lift() { lastAskMs = 0 }
}

/// Frames and bytes received since the statistics were last published.
struct DesktopTrafficWindow {
    private var frames = 0
    private var bytes: Int64 = 0
    private var startedMs: Int64 = 0

    mutating func restart(nowMs: Int64) { startedMs = nowMs }

    mutating func count(bytes count: Int) { frames += 1; bytes += Int64(count) }

    /// The window once it is a second old, and a new one starts.
    mutating func take(nowMs: Int64) -> (seconds: Double, frames: Int, bytes: Int64)? {
        guard nowMs - startedMs >= 1000 else { return nil }
        let window = (Double(nowMs - startedMs) / 1000, frames, bytes)
        frames = 0; bytes = 0; startedMs = nowMs
        return window
    }
}
