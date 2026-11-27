import CNative
import Foundation

/// Real-time Opus VOIP codec, adaptive RED + bitrate controller, WSOLA math, and capture DSP preprocessor
/// for iOS / macOS `agy /voice`. Mirrors `roamtty-desktop/.../voice_codec.rs` and Android `VoiceOpusPipeline.kt`.
public enum VoiceOpusMath {
    public static let frameMs: Int = 20
    public static let silenceRmsThreshold: Float = 0.004
    public static let maxConsecutivePlc: Int = 5
    public static let statsWindowMs: Int64 = 1_000
    public static let jitterWindow: Int = 150
    public static let stepDownHoldMs: Int64 = 3_000
    public static let dtxHangoverFrames: Int = 10
    public static let dtxKeepaliveInterval: Int = 10

    public static func isOpusSampleRate(_ rate: UInt32) -> Bool {
        rate == 8_000 || rate == 12_000 || rate == 16_000 || rate == 24_000 || rate == 48_000
    }

    public static func frameSamples(rate: UInt32) -> Int {
        Int(rate) * frameMs / 1000
    }

    public static func pcmRms(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for s in samples {
            let f = Double(s) / 32768.0
            sum += f * f
        }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    public static func bytesToInt16(_ bytes: [UInt8]) -> [Int16] {
        let count = bytes.count / 2
        var out = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let lo = UInt16(bytes[i * 2])
            let hi = UInt16(bytes[i * 2 + 1]) << 8
            out[i] = Int16(bitPattern: lo | hi)
        }
        return out
    }

    public static func int16ToBytes(_ samples: [Int16]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: samples.count * 2)
        for i in 0..<samples.count {
            let u = UInt16(bitPattern: samples[i])
            out[i * 2] = UInt8(truncatingIfNeeded: u)
            out[i * 2 + 1] = UInt8(truncatingIfNeeded: u >> 8)
        }
        return out
    }

    /// Pitch-preserving WSOLA time compression (~10-15%) to converge backlog without clicks or pitch shift.
    public static func wsolaCompress(_ input: [Int16], targetLen: Int) -> [Int16] {
        guard targetLen > 0, targetLen < input.count, input.count >= 64 else { return input }
        let cut = input.count - targetLen
        let overlap = min(input.count / 2, max(32, targetLen / 3))
        let maxShift = min(input.count - overlap, cut + overlap / 2)
        let minShift = max(1, cut - overlap / 3)
        guard minShift < maxShift else { return Array(input.prefix(targetLen)) }

        let anchor = (targetLen - overlap) / 2
        let bestShift = findBestWsolaShift(input, anchor: anchor, overlap: overlap, minShift: minShift, maxShift: maxShift, fallback: cut)
        var out = [Int16]()
        out.reserveCapacity(input.count - bestShift)
        out.append(contentsOf: input[0..<anchor])
        let invOverlap = 1.0 / Float(overlap)
        for i in 0..<overlap {
            let w = Float(i) * invOverlap
            let mixed = Float(input[anchor + i]) * (1 - w) + Float(input[anchor + bestShift + i]) * w
            out.append(Int16(max(-32768.0, min(32767.0, mixed.rounded()))))
        }
        let tailStart = anchor + bestShift + overlap
        if tailStart < input.count { out.append(contentsOf: input[tailStart...]) }
        return out
    }

    private static func findBestWsolaShift(
        _ input: [Int16],
        anchor: Int,
        overlap: Int,
        minShift: Int,
        maxShift: Int,
        fallback: Int
    ) -> Int {
        var bestShift = min(max(fallback, minShift), maxShift)
        var bestScore = Int64.min
        let step = overlap > 120 ? 2 : 1
        for shift in minShift...maxShift {
            if anchor + shift + overlap > input.count { break }
            var corr: Int64 = 0
            var i = 0
            while i < overlap {
                corr &+= Int64(input[anchor + i]) &* Int64(input[anchor + shift + i])
                i += step
            }
            if corr > bestScore {
                bestScore = corr
                bestShift = shift
            }
        }
        return bestShift
    }

    /// 5 ms raised-cosine crossfade between previous tail and new frame head after fast-forward jumps.
    public static func crossfadeHead(prevTail: [Int16], frame: inout [Int16]) {
        let n = min(prevTail.count, frame.count)
        guard n > 0 else { return }
        for i in 0..<n {
            let w = Float(0.5 * (1.0 - cos(Double.pi * Double(i) / Double(n))))
            let mixed = Float(prevTail[i]) * (1 - w) + Float(frame[i]) * w
            frame[i] = Int16(max(-32768.0, min(32767.0, mixed.rounded())))
        }
    }
}

/// Capture front-end: 80 Hz 1st-order high-pass filter + soft-knee limiter before Opus encoding.
public final class VoiceAudioPreprocessor: @unchecked Sendable {
    private let alpha: Float
    private var prevX: Float = 0
    private var prevY: Float = 0

    public init(sampleRate: Double = 16_000) {
        let rc = 1.0 / (2.0 * Double.pi * 80.0)
        let dt = 1.0 / max(8_000.0, sampleRate)
        self.alpha = Float(rc / (rc + dt))
    }

    public func reset() {
        prevX = 0
        prevY = 0
    }

    public func processInPlace(_ samples: UnsafeMutablePointer<Int16>, count: Int) {
        var xPrev = prevX
        var yPrev = prevY
        let a = alpha
        for i in 0..<count {
            let raw = Float(samples[i]) / 32768.0
            let hp = a * (yPrev + raw - xPrev)
            xPrev = raw
            yPrev = hp
            let limited: Float
            if abs(hp) > 0.85 {
                let sign: Float = hp >= 0 ? 1 : -1
                limited = sign * (0.85 + 0.15 * Float(tanh(Double((abs(hp) - 0.85) / 0.15))))
            } else {
                limited = hp
            }
            samples[i] = Int16(max(-32768.0, min(32767.0, (limited * 32767.0).rounded())))
        }
        prevX = xPrev
        prevY = yPrev
    }
}

/// Native libopus VOIP encoder via `CNative`.
public final class VoiceOpusEncoder: @unchecked Sendable {
    public let sampleRate: UInt32
    public let frameLen: Int
    private var handle: OpaquePointer?
    private var outBuf = [UInt8](repeating: 0, count: 512)

    public init?(sampleRate: UInt32, bitrate: Int32, dtx: Bool = true) {
        guard VoiceOpusMath.isOpusSampleRate(sampleRate),
              let ptr = roam_opus_encoder_create(Int32(sampleRate), bitrate, dtx ? 1 : 0) else { return nil }
        self.sampleRate = sampleRate
        self.frameLen = VoiceOpusMath.frameSamples(rate: sampleRate)
        self.handle = ptr
    }

    deinit {
        if let h = handle { roam_opus_encoder_destroy(h) }
    }

    public func applyParams(bitrate: Int32, lossPerc: Int32) {
        guard let h = handle else { return }
        roam_opus_encoder_set_params(h, bitrate, lossPerc)
    }

    public func reset() {
        guard let h = handle else { return }
        roam_opus_encoder_reset(h)
    }

    public func encode(_ pcm: [Int16]) -> [UInt8]? {
        guard let h = handle, pcm.count == frameLen else { return nil }
        let n: Int32 = pcm.withUnsafeBufferPointer { src in
            outBuf.withUnsafeMutableBufferPointer { dst in
                roam_opus_encoder_encode(h, src.baseAddress, Int32(frameLen), dst.baseAddress, Int32(dst.count))
            }
        }
        guard n > 0 else { return nil }
        return Array(outBuf[0..<Int(n)])
    }
}

/// Native libopus VOIP decoder via `CNative` (normal decode, In-band FEC LBRR, and PLC).
public final class VoiceOpusDecoder: @unchecked Sendable {
    public let sampleRate: UInt32
    public let frameLen: Int
    private var handle: OpaquePointer?

    public init?(sampleRate: UInt32) {
        guard VoiceOpusMath.isOpusSampleRate(sampleRate),
              let ptr = roam_opus_decoder_create(Int32(sampleRate)) else { return nil }
        self.sampleRate = sampleRate
        self.frameLen = VoiceOpusMath.frameSamples(rate: sampleRate)
        self.handle = ptr
    }

    deinit {
        if let h = handle { roam_opus_decoder_destroy(h) }
    }

    public func reset() {
        guard let h = handle else { return }
        roam_opus_decoder_reset(h)
    }

    public func decode(_ packet: [UInt8], decodeFec: Bool = false) -> [Int16]? {
        guard let h = handle, !packet.isEmpty else { return nil }
        var out = [Int16](repeating: 0, count: frameLen)
        let n: Int32 = packet.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                roam_opus_decoder_decode(h, src.baseAddress, Int32(src.count), dst.baseAddress, Int32(frameLen), decodeFec ? 1 : 0)
            }
        }
        guard n > 0 else { return nil }
        if Int(n) < out.count { out.removeLast(out.count - Int(n)) }
        return out
    }

    public func decodePlc() -> [Int16]? {
        guard let h = handle else { return nil }
        var out = [Int16](repeating: 0, count: frameLen)
        let n: Int32 = out.withUnsafeMutableBufferPointer { dst in
            roam_opus_decoder_decode(h, nil, 0, dst.baseAddress, Int32(frameLen), 0)
        }
        guard n > 0 else { return nil }
        if Int(n) < out.count { out.removeLast(out.count - Int(n)) }
        return out
    }
}

public struct VoiceLinkProfile: Equatable, Sendable {
    public let bitrate: Int32
    public let redCount: Int
    public let opusLossPerc: Int32
}

/// Adapts Opus bitrate, temporal RED depth (0..3), and Opus in-band FEC percentage from peer `VoiceStats`.
public final class VoiceLinkController: @unchecked Sendable {
    private let baseBitrate: Double
    private var tier = 0
    private var smoothedLoss = 0.0
    private var smoothedBurst = 0.0
    private var cleanSinceMs: Int64?

    public var currentLoss: Double { smoothedLoss }

    public init(sampleRate: UInt32) {
        switch sampleRate {
        case ...12_000: baseBitrate = 18_000
        case 16_000: baseBitrate = 28_000
        case 24_000: baseBitrate = 36_000
        default: baseBitrate = 48_000
        }
    }

    public func profile() -> VoiceLinkProfile {
        let scale: Double
        let redCount: Int
        let lossPerc: Int32
        switch tier {
        case 0: (scale, redCount, lossPerc) = (1.00, 0, 5)
        case 1: (scale, redCount, lossPerc) = (0.86, 1, 10)
        case 2: (scale, redCount, lossPerc) = (0.66, 2, 20)
        default: (scale, redCount, lossPerc) = (0.45, 3, 30)
        }
        let bitrate = Int32(max(12_000.0, min(64_000.0, baseBitrate * scale)))
        return VoiceLinkProfile(bitrate: bitrate, redCount: redCount, opusLossPerc: lossPerc)
    }

    @discardableResult
    public func onStats(_ st: VoiceStats, nowMs: Int64) -> VoiceLinkProfile {
        let loss = Double(st.lossPermille) / 1000.0
        let burst = Double(st.maxBurstLoss)
        smoothedLoss = loss > smoothedLoss ? smoothedLoss * 0.4 + loss * 0.6 : smoothedLoss * 0.85 + loss * 0.15
        smoothedBurst = burst > smoothedBurst ? burst : smoothedBurst * 0.80 + burst * 0.20

        let desired = targetTier(jitterMs: st.jitterMs)
        if desired > tier {
            tier = desired
            cleanSinceMs = nil
        } else if desired < tier {
            let since = cleanSinceMs ?? nowMs
            cleanSinceMs = since
            if nowMs - since >= VoiceOpusMath.stepDownHoldMs {
                tier = max(0, tier - 1)
                cleanSinceMs = nowMs
            }
        } else {
            cleanSinceMs = nil
        }
        return profile()
    }

    private func targetTier(jitterMs: UInt16) -> Int {
        if smoothedLoss >= 0.15 || smoothedBurst >= 3.0 { return 3 }
        if smoothedLoss >= 0.05 || smoothedBurst >= 2.0 { return 2 }
        if smoothedLoss >= 0.01 || smoothedBurst >= 1.0 || jitterMs >= 35 { return 1 }
        return 0
    }
}

/// Encodes 20 ms mic PCM frames into sequenced `VoiceOpusPacket`s with adaptive RED history and DTX suppression.
public final class VoiceRedSender: @unchecked Sendable {
    public let streamId: UInt32
    public let sampleRate: UInt32
    public let controller: VoiceLinkController
    private let enableDtx: Bool
    private let encoder: VoiceOpusEncoder
    private var recent: [(seq: UInt32, data: [UInt8])] = []
    private var seq: UInt32 = 0
    private var silentRun = 0
    private var dtxTicksSinceKeepalive = 0
    private var sentFirst = false

    public init?(streamId: UInt32, sampleRate: UInt32 = VoiceProtocol.defaultMicSampleRate, enableDtx: Bool = true) {
        let ctrl = VoiceLinkController(sampleRate: sampleRate)
        guard let enc = VoiceOpusEncoder(sampleRate: sampleRate, bitrate: ctrl.profile().bitrate, dtx: enableDtx) else { return nil }
        self.streamId = streamId
        self.sampleRate = sampleRate
        self.controller = ctrl
        self.enableDtx = enableDtx
        self.encoder = enc
    }

    public func onPeerStats(_ stats: VoiceStats, nowMs: Int64) {
        let p = controller.onStats(stats, nowMs: nowMs)
        encoder.applyParams(bitrate: p.bitrate, lossPerc: p.opusLossPerc)
    }

    public func encodePcm20ms(_ pcmBytes: [UInt8]) -> VoiceOpusPacket? {
        guard pcmBytes.count >= encoder.frameLen * 2 else { return nil }
        return encodeSamples20ms(VoiceOpusMath.bytesToInt16(Array(pcmBytes.prefix(encoder.frameLen * 2))))
    }

    public func encodeSamples20ms(_ samples: [Int16]) -> VoiceOpusPacket? {
        guard samples.count == encoder.frameLen else { return nil }
        let curSeq = seq
        seq &+= 1
        let tsSamples = curSeq &* UInt32(encoder.frameLen)
        let isSpeech = VoiceOpusMath.pcmRms(samples) >= VoiceOpusMath.silenceRmsThreshold
        updateSilenceRun(isSpeech: isSpeech)

        if enableDtx && sentFirst && silentRun > VoiceOpusMath.dtxHangoverFrames {
            return nextDtxKeepalive(seq: curSeq, tsSamples: tsSamples)
        }

        let profile = controller.profile()
        encoder.applyParams(bitrate: profile.bitrate, lossPerc: profile.opusLossPerc)
        guard let encoded = encoder.encode(samples), !encoded.isEmpty else { return nil }
        if enableDtx && sentFirst && encoded.count <= 2 && !isSpeech {
            return nextDtxKeepalive(seq: curSeq, tsSamples: tsSamples)
        }

        let red = buildRed(curSeq: curSeq, maxCount: profile.redCount)
        recordRecent(seq: curSeq, data: encoded)
        var flags = VoiceProtocol.VOICE_FLAG_FEC | (isSpeech ? VoiceProtocol.VOICE_FLAG_SPEECH : 0)
        if !sentFirst { flags |= VoiceProtocol.VOICE_FLAG_RESET; sentFirst = true }
        return VoiceOpusPacket(streamId: streamId, seq: curSeq, tsSamples: tsSamples, flags: flags, red: red, primary: encoded)
    }

    private func updateSilenceRun(isSpeech: Bool) {
        if isSpeech {
            silentRun = 0
            dtxTicksSinceKeepalive = 0
        } else {
            silentRun += 1
        }
    }

    private func nextDtxKeepalive(seq: UInt32, tsSamples: UInt32) -> VoiceOpusPacket? {
        dtxTicksSinceKeepalive += 1
        guard dtxTicksSinceKeepalive >= VoiceOpusMath.dtxKeepaliveInterval else { return nil }
        dtxTicksSinceKeepalive = 0
        return VoiceOpusPacket(streamId: streamId, seq: seq, tsSamples: tsSamples, flags: VoiceProtocol.VOICE_FLAG_DTX, red: [], primary: [])
    }

    private func buildRed(curSeq: UInt32, maxCount: Int) -> [VoiceRedEntry] {
        guard maxCount > 0, !recent.isEmpty else { return [] }
        let want = min(maxCount, VoiceProtocol.voiceMaxRedEntries)
        var out: [VoiceRedEntry] = []
        out.reserveCapacity(want)
        for item in recent.reversed() {
            let delta = curSeq &- item.seq
            if delta == 0 || delta > UInt32(VoiceProtocol.voiceMaxRedDelta) { continue }
            out.append(VoiceRedEntry(deltaSeq: UInt8(delta), data: item.data))
            if out.count >= want { break }
        }
        return out
    }

    private func recordRecent(seq: UInt32, data: [UInt8]) {
        recent.append((seq, data))
        if recent.count > 4 { recent.removeFirst(recent.count - 4) }
    }
}
