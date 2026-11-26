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

    // Server -> Client
    public static let MIC_START = 0x90
    public static let MIC_STOP = 0x91
    public static let SPK_START = 0x92
    public static let SPK_AUDIO = 0x93
    public static let SPK_CLEAR = 0x94
    public static let SPK_STOP = 0x95

    public static func parseStart(_ line: String) -> VoiceStart {
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
        guard let hello = VoiceHello.parse(json) else {
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
            guard p.count >= 4, let id = readU32LE(p, at: 0) else { return nil }
            return .spkClear(streamId: id)
        case SPK_STOP:
            guard p.count >= 4, let id = readU32LE(p, at: 0) else { return nil }
            return .spkStop(streamId: id)
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

    // MARK: CLI builder

    public static func voiceCommand(
        windows: Bool,
        port: Int? = nil,
        resumeSession: String? = nil,
        resumeToken: String? = nil,
        idleTimeoutSec: Int? = nil
    ) -> String {
        var args = ["--proto", "\(supportedProto)"]
        if let port, (1...65535).contains(port) {
            args += ["--port", "\(port)"]
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

    static func parse(_ json: [String: Any]) -> VoiceHello? {
        guard let proto = JSONValue.int(json["proto"]),
              let micPort = JSONValue.int(json["mic_port"]),
              (1...65535).contains(micPort) else { return nil }
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
    case spkStop(streamId: UInt32)
    case state(StateMessage)
    case ping(t1: Int64)
    case pong(t1: Int64, t2: Int64, t3: Int64)
}
