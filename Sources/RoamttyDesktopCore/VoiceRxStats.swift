import Foundation

/// Receiver-side raw primary packet loss, burst length, and P95/EWMA jitter estimator.
public final class VoiceRxStats: @unchecked Sendable {
    private var maxSeq: UInt32?
    private var windowEvents: [(at: Int64, received: Bool)] = []
    private var burstEvents: [(at: Int64, burst: UInt8)] = []
    private var currentLossStreak: UInt8 = 0
    private var seenSeqs: [UInt32] = []
    private var arrivalAt: [Int64] = []
    private var arrivalOffset: [Int64] = []
    private var ewmaJitterMs = 0.0
    private var lastTransitMs: Int64?

    public init() {}

    public func resetSeqCursor() {
        maxSeq = nil
        currentLossStreak = 0
        resetTiming()
    }

    public func resetTiming() {
        lastTransitMs = nil
        arrivalAt.removeAll(keepingCapacity: true)
        arrivalOffset.removeAll(keepingCapacity: true)
    }

    public func onPrimary(seq: UInt32, nowMs: Int64, resetDiscontinuity: Bool = false) {
        guard !seenSeqs.contains(seq) else { return }
        seenSeqs.append(seq)
        if seenSeqs.count > 256 { seenSeqs.removeFirst(seenSeqs.count - 256) }
        recordArrival(seq: seq, nowMs: nowMs, resetDiscontinuity: resetDiscontinuity)
        recordLossProgress(seq: seq, nowMs: nowMs, resetDiscontinuity: resetDiscontinuity)
        prune(nowMs: nowMs)
    }

    private func recordArrival(seq: UInt32, nowMs: Int64, resetDiscontinuity: Bool) {
        let transit = nowMs - Int64(seq) * Int64(VoiceOpusMath.frameMs)
        if resetDiscontinuity {
            lastTransitMs = transit
            return
        }
        if let prev = lastTransitMs {
            ewmaJitterMs += (Double(abs(transit - prev)) - ewmaJitterMs) / 16.0
        }
        lastTransitMs = transit
        if let lastO = arrivalOffset.last, abs(transit - lastO) > 2_000 {
            arrivalAt.removeAll(keepingCapacity: true)
            arrivalOffset.removeAll(keepingCapacity: true)
        }
        arrivalAt.append(nowMs)
        arrivalOffset.append(transit)
        if arrivalAt.count > VoiceOpusMath.jitterWindow {
            arrivalAt.removeFirst()
            arrivalOffset.removeFirst()
        }
    }

    private func recordLossProgress(seq: UInt32, nowMs: Int64, resetDiscontinuity: Bool) {
        guard !resetDiscontinuity, let prevMax = maxSeq else {
            maxSeq = seq
            windowEvents.append((nowMs, true))
            currentLossStreak = 0
            return
        }
        let diff = Int32(bitPattern: seq &- prevMax)
        if diff > 0 && diff <= 200 {
            for _ in 0..<Int(diff - 1) {
                windowEvents.append((nowMs, false))
                currentLossStreak = currentLossStreak < 255 ? currentLossStreak + 1 : 255
            }
            if currentLossStreak > 0 {
                burstEvents.append((nowMs, currentLossStreak))
                currentLossStreak = 0
            }
            windowEvents.append((nowMs, true))
            maxSeq = seq
        } else if diff > 200 {
            maxSeq = seq
            windowEvents.removeAll(keepingCapacity: true)
            burstEvents.removeAll(keepingCapacity: true)
            windowEvents.append((nowMs, true))
            currentLossStreak = 0
        } else if diff < 0 && diff >= -64 {
            if let idx = windowEvents.lastIndex(where: { !$0.received }) {
                windowEvents[idx].received = true
            }
        }
    }

    private func prune(nowMs: Int64) {
        windowEvents.removeAll { nowMs - $0.at > VoiceOpusMath.statsWindowMs }
        burstEvents.removeAll { nowMs - $0.at > VoiceOpusMath.statsWindowMs * 2 }
    }

    public func p95JitterMs() -> Double {
        let count = arrivalAt.count
        guard count >= 4 else { return ewmaJitterMs }
        let meanT = arrivalAt.reduce(0.0) { $0 + Double($1) } / Double(count)
        let meanO = arrivalOffset.reduce(0.0) { $0 + Double($1) } / Double(count)
        var num = 0.0
        var den = 0.0
        for i in 0..<count {
            let dt = Double(arrivalAt[i]) - meanT
            num += dt * (Double(arrivalOffset[i]) - meanO)
            den += dt * dt
        }
        let slope = den > 0 ? num / den : 0.0
        var residuals = (0..<count).map { i in Double(arrivalOffset[i]) - slope * (Double(arrivalAt[i]) - meanT) }
        let minR = residuals.min() ?? 0.0
        for i in 0..<residuals.count { residuals[i] -= minR }
        residuals.sort()
        return residuals[min(count - 1, count * 95 / 100)]
    }

    public func snapshot(streamId: UInt32, bufferMs: UInt16, nowMs: Int64) -> VoiceStats {
        prune(nowMs: nowMs)
        let total = windowEvents.count
        let lost = windowEvents.filter { !$0.received }.count
        let lossPermille = total == 0 ? UInt16(0) : UInt16(min(1000, (lost * 1000) / total))
        let maxBurst = burstEvents.map(\.burst).max() ?? 0
        let jitter = UInt16(max(0.0, min(2000.0, max(p95JitterMs(), ewmaJitterMs).rounded())))
        return VoiceStats(streamId: streamId, lossPermille: lossPermille, jitterMs: jitter, bufferMs: bufferMs, maxBurstLoss: maxBurst)
    }
}
