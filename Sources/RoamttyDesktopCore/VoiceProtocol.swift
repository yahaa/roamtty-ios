import Foundation

/// Wire protocol for `roamtty-desktop voice --proto 1` (V1 contract #6).
/// Reuses the outer framing `u8 type | u24 BE len | payload` and `UdpLink` from `DesktopProtocol`.
/// Voice payload integers are **little-endian**, and PCM payloads are mono **s16le**.
public enum VoiceProtocol {
    public static let supportedProto = 1
    public static let defaultPort = 24713
    public static let defaultIdleTimeoutSec = 300
    public static let defaultMicSampleRate: UInt32 = 16_000
    /// 20 ms at 16 kHz mono s16le (640 B): fits a single UDP shard with FEC parity 1.0.
    public static let micChunkBytes = 640
    public static let maxErrMsgBytes = 235
    public static let speakerRateRange: ClosedRange<UInt32> = 8_000...192_000

    // Client -> Server
    public static let MIC_AUDIO = 0x10
    public static let SPK_ACK = 0x11
    public static let MIC_OPUS = 0x12
    public static let VOICE_STATS_C2S = 0x13

    // Server -> Client
    public static let MIC_START = 0x90
    public static let MIC_STOP = 0x91
    public static let SPK_START = 0x92
    public static let SPK_AUDIO = 0x93
    public static let SPK_CLEAR = 0x94
    public static let SPK_STOP = 0x95
    public static let SPK_OPUS = 0x96
    public static let VOICE_STATS_S2C = 0x97

    // Bitflags carried in MIC_OPUS (0x12) and SPK_OPUS (0x96).
    public static let VOICE_FLAG_DTX: UInt8 = 1 << 0
    public static let VOICE_FLAG_FEC: UInt8 = 1 << 1
    public static let VOICE_FLAG_SPEECH: UInt8 = 1 << 2
    public static let VOICE_FLAG_RESET: UInt8 = 1 << 3
    public static let VOICE_GEN_SHIFT: UInt8 = 4
    public static let VOICE_GEN_MASK: UInt8 = 0xF0

    public static let voiceMaxRedEntries = 3
    public static let voiceMaxRedDelta: UInt8 = 6
    public static let voiceMaxOpusBytes = 1000

    public static func withTurnGen(_ flags: UInt8, turnGen: UInt8) -> UInt8 {
        (flags & ~VOICE_GEN_MASK) | ((turnGen & 0x0F) << VOICE_GEN_SHIFT)
    }

    public static func turnGenOf(_ flags: UInt8) -> UInt8 {
        (flags >> VOICE_GEN_SHIFT) & 0x0F
    }

    public static func parseStart(_ line: String, backend: VoiceBackend = .agy) -> VoiceStart {
        guard let json = JSONValue.object(line) else {
            return .failed(code: "internal", detail: "bad hello: \(String(line.prefix(200)))")
        }
        if json["error"] != nil {
            let detail = JSONValue.string(json["detail"])
            return .failed(
                code: JSONValue.string(json["error"]),
                detail: detail.isEmpty ? nil : detail,
                min: json["min"] != nil ? (JSONValue.int(json["min"]) ?? 0) : nil,
                max: json["max"] != nil ? (JSONValue.int(json["max"]) ?? 0) : nil
            )
        }
        guard let hello = VoiceHello.parse(json, allowZeroMicPort: backend == .codex) else {
            return .failed(code: "internal", detail: "bad voice hello: \(String(line.prefix(200)))")
        }
        return .ready(hello)
    }

    // MARK: Client -> Server frames

    public static func micAudio(streamId: UInt32, pcm: [UInt8]) -> [UInt8] {
        var payload = [UInt8]()
        payload.reserveCapacity(4 + pcm.count)
        appendU32LE(streamId, to: &payload)
        payload.append(contentsOf: pcm)
        return DesktopProtocol.frame(MIC_AUDIO, payload)
    }

    public static func spkAck(streamId: UInt32, ok: Bool, error: String = "") -> [UInt8] {
        var payload = [UInt8]()
        let sanitized = ok ? [] : sanitizeErrMsg(error)
        let errBytes = (!ok && sanitized.isEmpty) ? Array("speaker error".utf8) : sanitized
        payload.reserveCapacity(5 + errBytes.count)
        appendU32LE(streamId, to: &payload)
        payload.append(ok ? 1 : 0)
        payload.append(contentsOf: errBytes)
        return DesktopProtocol.frame(SPK_ACK, payload)
    }

    public static func config(_ values: [String: Any]) -> [UInt8] { DesktopProtocol.config(values) }
    public static func ping(_ t1: Int64) -> [UInt8] { DesktopProtocol.ping(t1) }
    public static func pong(_ t1: Int64, _ t2: Int64, _ t3: Int64) -> [UInt8] { DesktopProtocol.pong(t1, t2, t3) }

    public static func micOpus(_ packet: VoiceOpusPacket) -> [UInt8] {
        DesktopProtocol.frame(MIC_OPUS, encodeVoiceOpus(packet))
    }

    public static func voiceStats(_ stats: VoiceStats) -> [UInt8] {
        DesktopProtocol.frame(VOICE_STATS_C2S, encodeVoiceStats(stats))
    }

    public static func encodeVoiceOpus(_ packet: VoiceOpusPacket) -> [UInt8] {
        let redCount = min(packet.red.count, voiceMaxRedEntries)
        var redBytes = 0
        for i in 0..<redCount { redBytes += 3 + packet.red[i].data.count }
        var out: [UInt8] = []
        out.reserveCapacity(14 + redBytes + packet.primary.count)
        appendU32LE(packet.streamId, to: &out)
        appendU32LE(packet.seq, to: &out)
        appendU32LE(packet.tsSamples, to: &out)
        out.append(packet.flags)
        out.append(UInt8(redCount))
        for i in 0..<redCount {
            let entry = packet.red[i]
            out.append(entry.deltaSeq)
            appendU16LE(UInt16(truncatingIfNeeded: entry.data.count), to: &out)
            out.append(contentsOf: entry.data)
        }
        out.append(contentsOf: packet.primary)
        return out
    }

    public static func decodeVoiceOpus(_ payload: [UInt8]) -> VoiceOpusPacket? {
        guard payload.count >= 14,
              let streamId = readU32LE(payload, at: 0),
              let seq = readU32LE(payload, at: 4),
              let tsSamples = readU32LE(payload, at: 8) else { return nil }
        let flags = payload[12]
        let redCount = Int(payload[13])
        guard redCount <= voiceMaxRedEntries else { return nil }
        var cursor = 14
        var red: [VoiceRedEntry] = []
        red.reserveCapacity(redCount)
        for _ in 0..<redCount {
            guard payload.count - cursor >= 3 else { return nil }
            let delta = payload[cursor]
            let len = Int(UInt16(payload[cursor + 1]) | (UInt16(payload[cursor + 2]) << 8))
            cursor += 3
            guard delta > 0, delta <= voiceMaxRedDelta, len > 0, len <= voiceMaxOpusBytes,
                  payload.count - cursor >= len else { return nil }
            red.append(VoiceRedEntry(deltaSeq: delta, data: Array(payload[cursor..<(cursor + len)])))
            cursor += len
        }
        let rem = payload.count - cursor
        guard rem <= voiceMaxOpusBytes else { return nil }
        if rem == 0 && (flags & VOICE_FLAG_DTX) == 0 { return nil }
        let primary = rem > 0 ? Array(payload[cursor...]) : []
        return VoiceOpusPacket(streamId: streamId, seq: seq, tsSamples: tsSamples, flags: flags, red: red, primary: primary)
    }

    public static func encodeVoiceStats(_ stats: VoiceStats) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(12)
        appendU32LE(stats.streamId, to: &out)
        appendU16LE(min(stats.lossPermille, 1000), to: &out)
        appendU16LE(stats.jitterMs, to: &out)
        appendU16LE(stats.bufferMs, to: &out)
        out.append(stats.maxBurstLoss)
        out.append(stats.flags)
        return out
    }

    public static func decodeVoiceStats(_ payload: [UInt8]) -> VoiceStats? {
        guard payload.count >= 12,
              let streamId = readU32LE(payload, at: 0),
              let loss = readU16LE(payload, at: 4),
              let jitter = readU16LE(payload, at: 6),
              let buffer = readU16LE(payload, at: 8) else { return nil }
        return VoiceStats(
            streamId: streamId,
            lossPermille: min(loss, 1000),
            jitterMs: jitter,
            bufferMs: buffer,
            maxBurstLoss: payload[10],
            flags: payload[11]
        )
    }

    // MARK: Server -> Client decoding

    public static func decode(_ frame: Frame) -> VoiceServerMessage? {
        let p = frame.payload
        switch frame.type {
        case MIC_START:
            guard p.count >= 9, let id = readU32LE(p, at: 0), let rate = readU32LE(p, at: 4) else { return nil }
            let channels = p[8]
            guard rate > 0, channels >= 1 else { return nil }
            return .micStart(streamId: id, sampleRate: rate, channels: channels)
        case MIC_STOP:
            guard p.count >= 4, let id = readU32LE(p, at: 0) else { return nil }
            return .micStop(streamId: id)
        case SPK_START:
            guard p.count >= 9, let id = readU32LE(p, at: 0), let rate = readU32LE(p, at: 4) else { return nil }
            return .spkStart(streamId: id, sampleRate: rate, channels: p[8])
        case SPK_AUDIO:
            guard p.count >= 4, let id = readU32LE(p, at: 0) else { return nil }
            return .spkAudio(streamId: id, pcm: Array(p[4...]))
        case SPK_CLEAR:
            return decodeSpeakerClear(p)
        case SPK_STOP:
            guard p.count >= 4, let id = readU32LE(p, at: 0) else { return nil }
            return .spkStop(streamId: id)
        case SPK_OPUS:
            guard let pkt = decodeVoiceOpus(p) else { return nil }
            return .spkOpus(pkt)
        case VOICE_STATS_S2C:
            guard let st = decodeVoiceStats(p) else { return nil }
            return .voiceStats(st)
        case DesktopProtocol.STATE:
            guard let json = JSONValue.object(String(decoding: p, as: UTF8.self)) else { return nil }
            return .state(StateMessage(json: json))
        case DesktopProtocol.PING:
            var b = ByteReader(p)
            guard let t1 = b.i64() else { return nil }
            return .ping(t1: t1)
        case DesktopProtocol.PONG:
            var b = ByteReader(p)
            guard let t1 = b.i64(), let t2 = b.i64(), let t3 = b.i64() else { return nil }
            return .pong(t1: t1, t2: t2, t3: t3)
        default:
            return nil
        }
    }

    private static func decodeSpeakerClear(_ payload: [UInt8]) -> VoiceServerMessage? {
        guard let id = readU32LE(payload, at: 0) else { return nil }
        if payload.count == 4 { return .spkClear(streamId: id) }
        guard let turn = readU32LE(payload, at: 4) else { return nil }
        return .spkClearTurn(streamId: id, turn: turn)
    }

    // MARK: CLI builder

    static func validThread(_ id: String) -> Bool {
        id.utf8.count == 36 && UUID(uuidString: id) != nil
    }

    /// Parse only the new bytes produced by /status on the calling terminal.
    public static func codexThreadFromStatus(_ data: Data) -> String? {
        let output = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: #"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1b\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        guard output.localizedCaseInsensitiveContains("Model:"), output.localizedCaseInsensitiveContains("Directory:") else { return nil }
        let label = #"(?i)(?:^|[│\r\n \t])[ \t]*(?:Session(?: ID)?|Thread ID):[\s│]*([a-f0-9-](?:(?:\r?\n[ \t│]*)?[a-f0-9-]){35})(?![a-z0-9_-])"#
        guard let regex = try? NSRegularExpression(pattern: label) else { return nil }
        let ids = Set(regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: output) else { return nil }
            let id = output[range].filter { !$0.isWhitespace && $0 != "│" }
            return validThread(id) ? id : nil
        })
        return ids.count == 1 ? ids.first : nil
    }

    public static func voiceCommand(
        windows: Bool,
        port: Int? = nil,
        resumeSession: String? = nil,
        resumeToken: String? = nil,
        idleTimeoutSec: Int? = nil,
        backend: VoiceBackend = .agy,
        codexThread: String? = nil,
        codexCwd: String? = nil
    ) -> String {
        var args = ["--proto", "\(supportedProto)"]
        if backend != .agy {
            args += ["--backend", backend.rawValue]
        }
        if backend == .agy, let port, (1...65535).contains(port) {
            args += ["--port", "\(port)"]
        }
        if backend == .codex {
            if let rawThread = codexThread, !rawThread.isEmpty {
                let safeThread = String(rawThread.unicodeScalars.filter {
                    $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
                }.prefix(128))
                if !safeThread.isEmpty {
                    args += ["--codex-thread", safeThread]
                }
            }
            if !windows, let rawCwd = codexCwd, !rawCwd.isEmpty,
               !rawCwd.unicodeScalars.contains(where: { $0 == "\u{0}" || $0 == "\r" || $0 == "\n" }) {
                let quoted = "'" + rawCwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
                args += ["--codex-cwd", quoted]
            }
        }
        if let session = resumeSession, let token = resumeToken, !session.isEmpty, !token.isEmpty {
            let safeSession = String(session.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
            let safeToken = String(token.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+/=-_".unicodeScalars.contains($0)) })
            if !safeSession.isEmpty && !safeToken.isEmpty {
                args += ["--resume", safeSession, "--token", safeToken]
            }
        }
        if let idleTimeoutSec, idleTimeoutSec >= 0 {
            args += ["--idle-timeout", "\(idleTimeoutSec)"]
        }
        let joined = args.joined(separator: " ")
        return windows ? WindowsDesktop.voiceCommand(joined) : "\"$HOME/.roamtty/bin/roamtty-desktop\" voice \(joined)"
    }

    // MARK: Helpers

    static func appendU16LE(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    static func readU16LE(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset >= 0, bytes.count - offset >= 2 else { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    static func appendU32LE(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    static func readU32LE(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, bytes.count - offset >= 4 else { return nil }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    /// Strips CR/LF control characters and truncates safely at a UTF-8 scalar boundary to <= 235 bytes.
    public static func sanitizeErrMsg(_ raw: String) -> [UInt8] {
        let singleLine = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        var out: [UInt8] = []
        out.reserveCapacity(min(singleLine.utf8.count, maxErrMsgBytes))
        for scalar in singleLine.unicodeScalars {
            let encoded = Array(String(scalar).utf8)
            if out.count + encoded.count > maxErrMsgBytes { break }
            out.append(contentsOf: encoded)
        }
        return out
    }
}

/// Host-side voice backend passed via `--backend` to `roamtty-desktop voice`.
public enum VoiceBackend: String, Equatable, Sendable {
    case agy
    case codex
}

public struct VoiceHello: Equatable, Sendable {
    public let proto: Int
    public let version: String
    public let os: String
    public let mode: String
    public let micPort: Int
    public let session: String
    public let resumeToken: String
    public let udp: UdpOffer?
    public let codecs: [String]

    static func parse(_ json: [String: Any], allowZeroMicPort: Bool = false) -> VoiceHello? {
        let minPort = allowZeroMicPort ? 0 : 1
        guard let proto = JSONValue.int(json["proto"]),
              let micPort = JSONValue.int(json["mic_port"]),
              (minPort...65535).contains(micPort) else { return nil }
        let mode = JSONValue.string(json["mode"])
        guard mode.isEmpty || mode == "voice" else { return nil }
        var udp: UdpOffer?
        if let u = json["udp"] as? [String: Any],
           let port = JSONValue.int(u["port"]),
           let key = u["key"] as? String,
           let data = Data(base64Encoded: key), data.count == 16 {
            udp = UdpOffer(port: port, key: Array(data))
        }
        return VoiceHello(
            proto: proto,
            version: JSONValue.string(json["ver"]),
            os: JSONValue.string(json["os"]),
            mode: mode.isEmpty ? "voice" : mode,
            micPort: micPort,
            session: JSONValue.string(json["session"]),
            resumeToken: JSONValue.string(json["resume_token"]),
            udp: udp,
            codecs: JSONValue.strings(json["codecs"])
        )
    }
}

public enum VoiceStart: Equatable, Sendable {
    case ready(VoiceHello)
    case failed(code: String, detail: String?, min: Int? = nil, max: Int? = nil)
}

public enum VoiceServerMessage: Sendable {
    case micStart(streamId: UInt32, sampleRate: UInt32, channels: UInt8)
    case micStop(streamId: UInt32)
    case spkStart(streamId: UInt32, sampleRate: UInt32, channels: UInt8)
    case spkAudio(streamId: UInt32, pcm: [UInt8])
    case spkClear(streamId: UInt32)
    case spkClearTurn(streamId: UInt32, turn: UInt32)
    case spkStop(streamId: UInt32)
    case spkOpus(VoiceOpusPacket)
    case voiceStats(VoiceStats)
    case state(StateMessage)
    case ping(t1: Int64)
    case pong(t1: Int64, t2: Int64, t3: Int64)
}

public struct VoiceRedEntry: Equatable, Sendable {
    public let deltaSeq: UInt8
    public let data: [UInt8]
    public init(deltaSeq: UInt8, data: [UInt8]) {
        self.deltaSeq = deltaSeq
        self.data = data
    }
}

public struct VoiceOpusPacket: Equatable, Sendable {
    public let streamId: UInt32
    public let seq: UInt32
    public let tsSamples: UInt32
    public let flags: UInt8
    public let red: [VoiceRedEntry]
    public let primary: [UInt8]

    public init(streamId: UInt32, seq: UInt32, tsSamples: UInt32, flags: UInt8, red: [VoiceRedEntry], primary: [UInt8]) {
        self.streamId = streamId
        self.seq = seq
        self.tsSamples = tsSamples
        self.flags = flags
        self.red = red
        self.primary = primary
    }
}

public struct VoiceStats: Equatable, Sendable {
    public let streamId: UInt32
    public let lossPermille: UInt16
    public let jitterMs: UInt16
    public let bufferMs: UInt16
    public let maxBurstLoss: UInt8
    public let flags: UInt8

    public init(streamId: UInt32, lossPermille: UInt16, jitterMs: UInt16, bufferMs: UInt16, maxBurstLoss: UInt8, flags: UInt8 = 0) {
        self.streamId = streamId
        self.lossPermille = lossPermille
        self.jitterMs = jitterMs
        self.bufferMs = bufferMs
        self.maxBurstLoss = maxBurstLoss
        self.flags = flags
    }
}
