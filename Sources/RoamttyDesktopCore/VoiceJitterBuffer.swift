import Foundation

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
    private let maxSpanAboveTarget: Int
    private let decoder: VoiceOpusDecoder
    private var slots: [UInt32: Slot] = [:]
    private var playoutSeq: UInt32?
    private var highestSeq: UInt32 = 0
    private var started = false
    private var firstArrivalMs: Int64?
    private var turnGen: UInt8 = 0
    private var turnGenLocked = false
    // Legacy SPK_CLEAR contains only a stream ID. Media carries the authoritative turn number.
    private var absoluteTurn: UInt32?
    private var clearAtMs: Int64?
    private var clearSeq: UInt32?
    private var pendingClearSkips = 0
    private var lastImplicitAdvanceMs: Int64 = 0
    private static let lateClearWindowMs: Int64 = 5_000
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

    public init?(streamId: UInt32, sampleRate: UInt32, maxSpanAboveTarget: Int = 50) {
        guard let dec = VoiceOpusDecoder(sampleRate: sampleRate) else { return nil }
        self.streamId = streamId
        self.sampleRate = sampleRate
        self.maxSpanAboveTarget = maxSpanAboveTarget
        self.decoder = dec
    }

    public func clear(nextTurnGen: UInt8? = nil, resetPendingSkips: Bool = true) {
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
        if resetPendingSkips {
            pendingClearSkips = 0
            lastImplicitAdvanceMs = 0
        }
        if let g = nextTurnGen {
            turnGen = g & 0x0F
            turnGenLocked = true
        }
    }

    @discardableResult
    public func push(_ pkt: VoiceOpusPacket, nowMs: Int64) -> Bool {
        let gen = VoiceProtocol.turnGenOf(pkt.flags)
        let changedTurn = turnGenLocked && gen != turnGen
        guard acceptTurnGen(gen, nowMs: nowMs) else { return false }
        if let cleared = clearAtMs, let watermark = clearSeq {
            // A duplicate CLEAR can arrive on SSH after this turn is already playing. Suppress
            // in-flight packets briefly, then accept genuinely newer sequences of the same turn.
            guard nowMs - cleared >= 160, Int32(bitPattern: pkt.seq &- watermark) > 0 else { return false }
        }
        let isDtxPkt = (pkt.flags & VoiceProtocol.VOICE_FLAG_DTX) != 0
        let isResetPkt = (pkt.flags & VoiceProtocol.VOICE_FLAG_RESET) != 0
        rxStats.onPrimary(seq: pkt.seq, nowMs: nowMs, resetDiscontinuity: isDtxPkt || isResetPkt || inDtx)
        if firstArrivalMs == nil { firstArrivalMs = nowMs }
        reanchorIfStale(pkt: pkt, isDtxPkt: isDtxPkt)
        insertPrimary(pkt)
        insertRedEntries(pkt)
        trimOldSlotsIfNeeded()
        updateTarget(nowMs: nowMs)
        return changedTurn
    }

    private func reanchorIfStale(pkt: VoiceOpusPacket, isDtxPkt: Bool) {
        guard slots.isEmpty, let cur = playoutSeq else { return }
        let behind = Int32(bitPattern: pkt.seq &- cur)
        if (inDtx && !isDtxPkt) || (behind < 0 && behind >= -64 && (inDtx || consecutivePlc >= 2)) {
            playoutSeq = pkt.seq
            highestSeq = pkt.seq
            inDtx = false
            consecutivePlc = 0
        }
    }

    public func queuedFrames() -> Int {
        guard !slots.isEmpty, let p = playoutSeq else { return 0 }
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
        if excess >= 3 {
            if res.isSilence && !slots.isEmpty { return popFrame(nowMs: nowMs) }
            if !res.isSilence {
                res.pcm = VoiceOpusMath.wsolaCompress(res.pcm, targetLen: (res.pcm.count * 90) / 100)
            }
        }
        if jumped && !lastTail.isEmpty { VoiceOpusMath.crossfadeHead(prevTail: lastTail, frame: &res.pcm) }
        let tailLen = min(Int(sampleRate) * 5 / 1000, res.pcm.count)
        lastTail = tailLen > 0 ? Array(res.pcm[(res.pcm.count - tailLen)...]) : []
        return res.pcm
    }

    private func acceptTurnGen(_ pktGen: UInt8, nowMs: Int64) -> Bool {
        if !turnGenLocked {
            turnGen = pktGen
            turnGenLocked = true
            return true
        }
        if pktGen == turnGen { return true }
        let ahead = (pktGen &- turnGen) & 0x0F
        guard ahead > 0 && ahead < 8 else { return false }
        if let value = absoluteTurn { absoluteTurn = value &+ UInt32(ahead) }
        if clearAtMs == nil {
            pendingClearSkips = min(7, pendingClearSkips + Int(ahead))
        }
        clearAtMs = nil
        clearSeq = nil
        lastImplicitAdvanceMs = nowMs
        clear(nextTurnGen: pktGen, resetPendingSkips: false)
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
        guard span > targetFrames + maxSpanAboveTarget else { return (current, false) }
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
            return PopResult(pcm: [Int16](repeating: 0, count: decoder.frameLen), isSilence: true, advanceSeq: !slots.isEmpty)
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
        var advanceSeq = true
        if consecutivePlc <= VoiceOpusMath.maxConsecutivePlc {
            plcFrames += 1
            pcm = decoder.decodePlc() ?? [Int16](repeating: 0, count: decoder.frameLen)
            if consecutivePlc >= 3 {
                let gain = max(0.0, 1.0 - Float(consecutivePlc - 2) * 0.28)
                for i in 0..<pcm.count { pcm[i] = Int16(Float(pcm[i]) * gain) }
            }
            if slots.isEmpty {
                advanceSeq = false
                if expandCredits > 0 { expandCredits -= 1 }
            }
        } else {
            if slots.isEmpty {
                playoutSeq = nil; started = false; firstArrivalMs = nil; consecutivePlc = 0
                underrunPenaltyMs = 0.0
                rxStats.resetTiming()
                return nil
            }
            pcm = [Int16](repeating: 0, count: decoder.frameLen)
            isSilence = true
        }
        return PopResult(pcm: pcm, isSilence: isSilence, advanceSeq: advanceSeq)
    }
}

extension VoiceJitterBuffer {
    /// A numbered clear sets a definitive generation floor, including before the first media packet.
    @discardableResult
    public func clearForTurn(_ turn: UInt32) -> Bool {
        let gen = UInt8(truncatingIfNeeded: turn) & 0x0F
        if let latest = absoluteTurn, Int32(bitPattern: turn &- latest) <= 0 { return false }
        if absoluteTurn == nil && turnGenLocked {
            let behind = (turnGen &- gen) & 0x0F
            // The full number is authoritative across large jumps. Only preserve a newer
            // media turn when it was already observed before this control arrived.
            if gen == turnGen || turn < UInt32(turnGen) || (behind <= 7 && Int(behind) <= pendingClearSkips) {
                absoluteTurn = turn &+ UInt32(behind)
                return false
            }
        }
        absoluteTurn = turn
        clearAtMs = nil; clearSeq = nil
        clear(nextTurnGen: gen)
        return true
    }

    @discardableResult
    public func clearForBargeIn(nowMs: Int64 = 0) -> Bool {
        if pendingClearSkips > 0 {
            let withinWindow = nowMs <= 0 || lastImplicitAdvanceMs <= 0 || (nowMs - lastImplicitAdvanceMs) <= Self.lateClearWindowMs
            if withinWindow {
                pendingClearSkips -= 1
                return false
            }
            pendingClearSkips = 0
        }
        clearAtMs = nowMs
        if turnGenLocked { clearSeq = highestSeq }
        clear()
        return true
    }
}
