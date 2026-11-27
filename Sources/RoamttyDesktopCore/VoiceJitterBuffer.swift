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
        lastTransitMs = nil
    }

    public func onPrimary(seq: UInt32, nowMs: Int64) {
        guard !seenSeqs.contains(seq) else { return }
        seenSeqs.append(seq)
        if seenSeqs.count > 256 { seenSeqs.removeFirst(seenSeqs.count - 256) }
        recordArrival(seq: seq, nowMs: nowMs)
        recordLossProgress(seq: seq, nowMs: nowMs)
        prune(nowMs: nowMs)
    }

    private func recordArrival(seq: UInt32, nowMs: Int64) {
        let transit = nowMs - Int64(seq) * Int64(VoiceOpusMath.frameMs)
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

    private func recordLossProgress(seq: UInt32, nowMs: Int64) {
        guard let prevMax = maxSeq else {
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

/// Adaptive Speech Jitter Buffer: seq reorder + temporal RED + Opus LBRR + native PLC + NetEQ expansion + WSOLA.
public final class VoiceJitterBuffer: @unchecked Sendable {
    private struct Slot {
        let data: [UInt8]
        let flags: UInt8
    }

    private struct PopResult {
        var pcm: [Int16]
        var isSilence: Bool
        var advanceSeq: Bool
    }

    public let streamId: UInt32
    public let sampleRate: UInt32
    private let decoder: VoiceOpusDecoder
    private var slots: [UInt32: Slot] = [:]
    private var playoutSeq: UInt32?
    private var highestSeq: UInt32 = 0
    private var started = false
    private var firstArrivalMs: Int64?
    private var turnGen: UInt8 = 0
    private var turnGenLocked = false
    private var targetFrames = 1
    private var underrunPenaltyMs = 0.0
    private var lastDecayMs: Int64 = 0
    private var consecutivePlc = 0
    private var expandCredits = 0
    private var inDtx = false
    private var lastTail: [Int16] = []
    private let rxStats = VoiceRxStats()

    public private(set) var plcFrames: UInt64 = 0
    public private(set) var redRecovered: UInt64 = 0
    public private(set) var lbrrRecovered: UInt64 = 0

    public init?(streamId: UInt32, sampleRate: UInt32) {
        guard let dec = VoiceOpusDecoder(sampleRate: sampleRate) else { return nil }
        self.streamId = streamId
        self.sampleRate = sampleRate
        self.decoder = dec
    }

    public func clear(nextTurnGen: UInt8? = nil) {
        slots.removeAll(keepingCapacity: true)
        playoutSeq = nil
        started = false
        firstArrivalMs = nil
        consecutivePlc = 0
        expandCredits = 0
        inDtx = false
        lastTail.removeAll(keepingCapacity: true)
        decoder.reset()
        rxStats.resetSeqCursor()
        if let g = nextTurnGen {
            turnGen = g & 0x0F
            turnGenLocked = true
        }
    }

    public func clearForBargeIn() {
        let next: UInt8? = turnGenLocked ? ((turnGen &+ 1) & 0x0F) : nil
        clear(nextTurnGen: next)
    }

    public func push(_ pkt: VoiceOpusPacket, nowMs: Int64) {
        guard acceptTurnGen(VoiceProtocol.turnGenOf(pkt.flags)) else { return }
        rxStats.onPrimary(seq: pkt.seq, nowMs: nowMs)
        if firstArrivalMs == nil { firstArrivalMs = nowMs }
        insertPrimary(pkt)
        insertRedEntries(pkt)
        trimOldSlotsIfNeeded()
        updateTarget(nowMs: nowMs)
    }

    public func queuedFrames() -> Int {
        guard let p = playoutSeq else { return 0 }
        let span = Int(Int32(bitPattern: highestSeq &- p))
        return span < 0 ? 0 : min(span + 1, slots.count + 4)
    }

    public func bufferMs() -> UInt16 {
        UInt16(min(Int(UInt16.max), queuedFrames() * VoiceOpusMath.frameMs))
    }

    public func statsSnapshot(nowMs: Int64) -> VoiceStats {
        rxStats.snapshot(streamId: streamId, bufferMs: bufferMs(), nowMs: nowMs)
    }

    public func popFrame(nowMs: Int64) -> [Int16]? {
        guard let p = playoutSeq else { return nil }
        if !started {
            let waited = firstArrivalMs.map { max(0, nowMs - $0) } ?? 0
            guard slots.count >= targetFrames || waited >= 100 else { return nil }
            started = true
        }

        let (curSeq, jumped) = enforceMaxSpan(current: p)
        guard var res = decodeOrConceal(curSeq: curSeq, nowMs: nowMs) else { return nil }
        if res.advanceSeq { playoutSeq = curSeq &+ 1 }

        let excess = Int(Int32(bitPattern: highestSeq &- curSeq)) - targetFrames
        if excess >= 2 {
            if res.isSilence && !slots.isEmpty { return popFrame(nowMs: nowMs) }
            if !res.isSilence {
                res.pcm = VoiceOpusMath.wsolaCompress(res.pcm, targetLen: (res.pcm.count * 88) / 100)
            }
        }
        if jumped && !lastTail.isEmpty { VoiceOpusMath.crossfadeHead(prevTail: lastTail, frame: &res.pcm) }
        let tailLen = min(Int(sampleRate) * 5 / 1000, res.pcm.count)
        lastTail = tailLen > 0 ? Array(res.pcm[(res.pcm.count - tailLen)...]) : []
        return res.pcm
    }

    private func acceptTurnGen(_ pktGen: UInt8) -> Bool {
        if !turnGenLocked {
            turnGen = pktGen
            turnGenLocked = true
            return true
        }
        if pktGen == turnGen { return true }
        let ahead = (pktGen &- turnGen) & 0x0F
        guard ahead > 0 && ahead < 8 else { return false }
        clear(nextTurnGen: pktGen)
        return true
    }

    private func acceptSeq(_ seq: UInt32) -> Bool {
        guard let p = playoutSeq else { return true }
        return Int32(bitPattern: seq &- p) >= 0
    }

    private func insertPrimary(_ pkt: VoiceOpusPacket) {
        guard acceptSeq(pkt.seq) else { return }
        if slots[pkt.seq] == nil { slots[pkt.seq] = Slot(data: pkt.primary, flags: pkt.flags) }
        if playoutSeq == nil {
            playoutSeq = pkt.seq
            highestSeq = pkt.seq
        } else if Int32(bitPattern: pkt.seq &- highestSeq) > 0 {
            highestSeq = pkt.seq
        }
    }

    private func insertRedEntries(_ pkt: VoiceOpusPacket) {
        let flags = VoiceProtocol.VOICE_FLAG_FEC | VoiceProtocol.VOICE_FLAG_SPEECH
        for red in pkt.red {
            let rSeq = pkt.seq &- UInt32(red.deltaSeq)
            if acceptSeq(rSeq) && slots[rSeq] == nil {
                slots[rSeq] = Slot(data: red.data, flags: flags)
                redRecovered += 1
                if playoutSeq == nil { playoutSeq = rSeq }
            }
        }
    }

    private func trimOldSlotsIfNeeded() {
        guard slots.count > 64 else { return }
        let sortedKeys = slots.keys.sorted { Int32(bitPattern: $0 &- $1) < 0 }
        for k in sortedKeys.prefix(slots.count - 64) { slots.removeValue(forKey: k) }
    }

    private func updateTarget(nowMs: Int64) {
        if lastDecayMs > 0 && nowMs > lastDecayMs {
            underrunPenaltyMs = max(0.0, underrunPenaltyMs - (Double(nowMs - lastDecayMs) / 1000.0) * 2.0)
        }
        lastDecayMs = nowMs

        let stats = rxStats.snapshot(streamId: streamId, bufferMs: bufferMs(), nowMs: nowMs)
        let lossFloorMs: Double
        if stats.lossPermille >= 150 || stats.maxBurstLoss >= 3 {
            lossFloorMs = 60.0
        } else if stats.lossPermille >= 20 || stats.maxBurstLoss >= 1 {
            lossFloorMs = 40.0
        } else {
            lossFloorMs = 20.0
        }
        let prevTarget = targetFrames
        let desiredMs = max(lossFloorMs, min(180.0, rxStats.p95JitterMs() + 15.0 + underrunPenaltyMs))
        targetFrames = max(1, min(9, Int(ceil(desiredMs / Double(VoiceOpusMath.frameMs)))))
        if targetFrames > prevTarget {
            expandCredits = min(4, expandCredits + (targetFrames - prevTarget))
        }
    }

    private func enforceMaxSpan(current: UInt32) -> (UInt32, Bool) {
        let span = Int(Int32(bitPattern: highestSeq &- current))
        guard span > targetFrames + 9 else { return (current, false) }
        let jumpTo = highestSeq &- UInt32(targetFrames)
        slots = slots.filter { Int32(bitPattern: $0.key &- jumpTo) >= 0 }
        playoutSeq = jumpTo
        return (jumpTo, true)
    }

    private func decodeOrConceal(curSeq: UInt32, nowMs: Int64) -> PopResult? {
        if let entry = slots.removeValue(forKey: curSeq) {
            return decodePresent(entry)
        }
        if let nextEntry = slots[curSeq &+ 1] {
            return decodeFromLookahead(nextEntry)
        }
        if inDtx {
            return PopResult(pcm: [Int16](repeating: 0, count: decoder.frameLen), isSilence: true, advanceSeq: true)
        }
        return decodePlc(nowMs: nowMs)
    }

    private func decodePresent(_ entry: Slot) -> PopResult {
        consecutivePlc = 0
        if (entry.flags & VoiceProtocol.VOICE_FLAG_DTX) != 0 && entry.data.isEmpty {
            inDtx = true
            return PopResult(pcm: [Int16](repeating: 0, count: decoder.frameLen), isSilence: true, advanceSeq: true)
        }
        inDtx = false
        let pcm = decoder.decode(entry.data, decodeFec: false) ?? [Int16](repeating: 0, count: decoder.frameLen)
        return PopResult(pcm: pcm, isSilence: VoiceOpusMath.pcmRms(pcm) < VoiceOpusMath.silenceRmsThreshold, advanceSeq: true)
    }

    private func decodeFromLookahead(_ nextEntry: Slot) -> PopResult {
        if (nextEntry.flags & VoiceProtocol.VOICE_FLAG_DTX) != 0 {
            inDtx = true
            return PopResult(pcm: [Int16](repeating: 0, count: decoder.frameLen), isSilence: true, advanceSeq: true)
        }
        consecutivePlc = 0
        inDtx = false
        if !nextEntry.data.isEmpty, let recovered = decoder.decode(nextEntry.data, decodeFec: true) {
            lbrrRecovered += 1
            return PopResult(pcm: recovered, isSilence: false, advanceSeq: true)
        }
        plcFrames += 1
        let pcm = decoder.decodePlc() ?? [Int16](repeating: 0, count: decoder.frameLen)
        return PopResult(pcm: pcm, isSilence: false, advanceSeq: true)
    }

    private func decodePlc(nowMs: Int64) -> PopResult? {
        consecutivePlc += 1
        if consecutivePlc == 1 {
            underrunPenaltyMs = min(120.0, underrunPenaltyMs + 20.0)
            updateTarget(nowMs: nowMs)
        }
        var pcm: [Int16]
        var isSilence = false
        if consecutivePlc <= VoiceOpusMath.maxConsecutivePlc {
            plcFrames += 1
            pcm = decoder.decodePlc() ?? [Int16](repeating: 0, count: decoder.frameLen)
            if consecutivePlc >= 3 {
                let gain = max(0.0, 1.0 - Float(consecutivePlc - 2) * 0.28)
                for i in 0..<pcm.count { pcm[i] = Int16(Float(pcm[i]) * gain) }
            }
        } else {
            if slots.isEmpty {
                playoutSeq = nil; started = false; firstArrivalMs = nil
                return nil
            }
            pcm = [Int16](repeating: 0, count: decoder.frameLen)
            isSilence = true
        }
        var advanceSeq = true
        if expandCredits > 0 && slots.isEmpty && consecutivePlc <= 2 {
            expandCredits -= 1
            advanceSeq = false
        }
        return PopResult(pcm: pcm, isSilence: isSilence, advanceSeq: advanceSeq)
    }
}
