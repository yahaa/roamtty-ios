import Foundation
import XCTest
@testable import RoamttyDesktopCore

/// Wire contract verification against `#6 [spec]` V1 `roamtty-desktop voice`.
final class VoiceProtocolTests: XCTestCase {
    func testFrameIdsDoNotOverlapDesktopProtocol() {
        let desktopIds: Set<Int> = [
            DesktopProtocol.CONFIG, DesktopProtocol.INPUT, DesktopProtocol.ACTION, DesktopProtocol.REQ,
            DesktopProtocol.ACK, DesktopProtocol.CLIP_SET, DesktopProtocol.PING, DesktopProtocol.PONG,
            DesktopProtocol.VIDEO, DesktopProtocol.CURSOR_POS, DesktopProtocol.CURSOR_SHAPE,
            DesktopProtocol.STATE, DesktopProtocol.AUDIO
        ]
        let voiceIds: Set<Int> = [
            VoiceProtocol.MIC_AUDIO, VoiceProtocol.SPK_ACK, VoiceProtocol.MIC_START, VoiceProtocol.MIC_STOP,
            VoiceProtocol.SPK_START, VoiceProtocol.SPK_AUDIO, VoiceProtocol.SPK_CLEAR, VoiceProtocol.SPK_STOP
        ]
        XCTAssertTrue(desktopIds.isDisjoint(with: voiceIds))
        XCTAssertEqual(VoiceProtocol.MIC_AUDIO, 0x10)
        XCTAssertEqual(VoiceProtocol.SPK_ACK, 0x11)
        XCTAssertEqual(VoiceProtocol.MIC_START, 0x90)
        XCTAssertEqual(VoiceProtocol.MIC_STOP, 0x91)
        XCTAssertEqual(VoiceProtocol.SPK_START, 0x92)
        XCTAssertEqual(VoiceProtocol.SPK_AUDIO, 0x93)
        XCTAssertEqual(VoiceProtocol.SPK_CLEAR, 0x94)
        XCTAssertEqual(VoiceProtocol.SPK_STOP, 0x95)
    }

    func testClientFrameEncodingUsesLittleEndianPayloadAndBigEndianOuterHeader() throws {
        let pcm: [UInt8] = [0x01, 0x02, 0xFE, 0xFF]
        let micBytes = VoiceProtocol.micAudio(streamId: 0x0403_0201, pcm: pcm)
        XCTAssertEqual(Array(micBytes.prefix(4)), [0x10, 0x00, 0x00, 0x08])
        XCTAssertEqual(Array(micBytes.dropFirst(4)), [0x01, 0x02, 0x03, 0x04, 0x01, 0x02, 0xFE, 0xFF])

        let ackOk = VoiceProtocol.spkAck(streamId: 42, ok: true, error: "ignored on ok")
        let ackOkFrame = try XCTUnwrap(DesktopProtocol.read(ackOk))
        XCTAssertEqual(ackOkFrame.type, VoiceProtocol.SPK_ACK)
        XCTAssertEqual(ackOkFrame.payload, [42, 0, 0, 0, 1])

        let ackErr = VoiceProtocol.spkAck(streamId: 7, ok: false, error: "line1\r\nline2")
        let ackErrFrame = try XCTUnwrap(DesktopProtocol.read(ackErr))
        XCTAssertEqual(ackErrFrame.type, VoiceProtocol.SPK_ACK)
        XCTAssertEqual(Array(ackErrFrame.payload.prefix(5)), [7, 0, 0, 0, 0])
        let msg = String(decoding: ackErrFrame.payload.dropFirst(5), as: UTF8.self)
        XCTAssertEqual(msg, "line1  line2")
        XCTAssertFalse(msg.contains("\r"))
        XCTAssertFalse(msg.contains("\n"))

        // SPK_ACK(ok=false) must never emit an empty error string.
        for blank in ["", "   \r\n  "] {
            let blankErr = try XCTUnwrap(DesktopProtocol.read(VoiceProtocol.spkAck(streamId: 8, ok: false, error: blank)))
            XCTAssertEqual(Array(blankErr.payload.prefix(5)), [8, 0, 0, 0, 0])
            XCTAssertFalse(blankErr.payload.dropFirst(5).isEmpty, "SPK_ACK(ok=false) must include a fallback error string")
        }
    }

    func testSpkAckTruncatesMultiByteUtf8SafelyWithin235Bytes() throws {
        let longCjk = String(repeating: "麦", count: 100) // 300 UTF-8 bytes
        let encoded = VoiceProtocol.spkAck(streamId: 1, ok: false, error: longCjk)
        let frame = try XCTUnwrap(DesktopProtocol.read(encoded))
        let errBytes = Array(frame.payload.dropFirst(5))
        XCTAssertLessThanOrEqual(errBytes.count, VoiceProtocol.maxErrMsgBytes)
        XCTAssertEqual(errBytes.count, 234) // 78 * 3 bytes
        XCTAssertNotNil(String(bytes: errBytes, encoding: .utf8))
    }

    func testServerMessagesDecodeLittleEndianPayloads() throws {
        let micStart = DesktopProtocol.frame(VoiceProtocol.MIC_START, [0x05, 0x00, 0x00, 0x00, 0x80, 0x3E, 0x00, 0x00, 0x01])
        guard case .micStart(let id, let rate, let ch)? = VoiceProtocol.decode(try XCTUnwrap(DesktopProtocol.read(micStart))) else {
            return XCTFail("expected micStart")
        }
        XCTAssertEqual(id, 5); XCTAssertEqual(rate, 16_000); XCTAssertEqual(ch, 1)

        let micStop = DesktopProtocol.frame(VoiceProtocol.MIC_STOP, [0x05, 0x00, 0x00, 0x00])
        guard case .micStop(let stopId)? = VoiceProtocol.decode(try XCTUnwrap(DesktopProtocol.read(micStop))) else {
            return XCTFail("expected micStop")
        }
        XCTAssertEqual(stopId, 5)

        let spkStart = DesktopProtocol.frame(VoiceProtocol.SPK_START, [0x09, 0x00, 0x00, 0x00, 0xC0, 0x5D, 0x00, 0x00, 0x01])
        guard case .spkStart(let sId, let sRate, let sCh)? = VoiceProtocol.decode(try XCTUnwrap(DesktopProtocol.read(spkStart))) else {
            return XCTFail("expected spkStart")
        }
        XCTAssertEqual(sId, 9); XCTAssertEqual(sRate, 24_000); XCTAssertEqual(sCh, 1)

        // Out-of-range speaker sample rate or stereo channels STILL decode as .spkStart so VoiceSession replies SPK_ACK(ok=false).
        let badRate = DesktopProtocol.frame(VoiceProtocol.SPK_START, [0x09, 0x00, 0x00, 0x00, 0x40, 0x1F, 0x00, 0x00, 0x02])
        guard case .spkStart(let bId, let bRate, let bCh)? = VoiceProtocol.decode(try XCTUnwrap(DesktopProtocol.read(badRate))) else {
            return XCTFail("expected spkStart so session can send SPK_ACK(ok=false)")
        }
        XCTAssertEqual(bId, 9); XCTAssertEqual(bRate, 8_000); XCTAssertEqual(bCh, 2)

        let spkAudio = DesktopProtocol.frame(VoiceProtocol.SPK_AUDIO, [0x09, 0x00, 0x00, 0x00, 0x10, 0x20])
        guard case .spkAudio(let aId, let pcm)? = VoiceProtocol.decode(try XCTUnwrap(DesktopProtocol.read(spkAudio))) else {
            return XCTFail("expected spkAudio")
        }
        XCTAssertEqual(aId, 9); XCTAssertEqual(pcm, [0x10, 0x20])

        let spkClear = DesktopProtocol.frame(VoiceProtocol.SPK_CLEAR, [0x09, 0x00, 0x00, 0x00])
        guard case .spkClear(let cId)? = VoiceProtocol.decode(try XCTUnwrap(DesktopProtocol.read(spkClear))) else {
            return XCTFail("expected spkClear")
        }
        XCTAssertEqual(cId, 9)

        let spkStop = DesktopProtocol.frame(VoiceProtocol.SPK_STOP, [0x09, 0x00, 0x00, 0x00])
        guard case .spkStop(let stId)? = VoiceProtocol.decode(try XCTUnwrap(DesktopProtocol.read(spkStop))) else {
            return XCTFail("expected spkStop")
        }
        XCTAssertEqual(stId, 9)
    }

    func testHelloParsesSpecSchemaAndErrors() {
        let key = Data((0..<16).map { UInt8($0) }).base64EncodedString()
        let line = """
        {"proto":1,"ver":"0.9.7","os":"macos","mode":"voice","mic_port":24713,"session":"abc123","resume_token":"tok==","udp":{"port":60123,"key":"\(key)"},"codecs":["pcm16"]}
        """
        guard case .ready(let hello) = VoiceProtocol.parseStart(line) else { return XCTFail("expected ready hello") }
        XCTAssertEqual(hello.proto, 1)
        XCTAssertEqual(hello.version, "0.9.7")
        XCTAssertEqual(hello.os, "macos")
        XCTAssertEqual(hello.mode, "voice")
        XCTAssertEqual(hello.micPort, 24713)
        XCTAssertEqual(hello.session, "abc123")
        XCTAssertEqual(hello.resumeToken, "tok==")
        XCTAssertEqual(hello.udp, UdpOffer(port: 60123, key: (0..<16).map { UInt8($0) }))
        XCTAssertEqual(hello.codecs, ["pcm16"])

        // SSH fallback hello without udp object.
        let sshOnly = #"{"proto":1,"ver":"0.9.7","os":"linux","mode":"voice","mic_port":39112,"session":"s2","resume_token":"r2","codecs":["pcm16"]}"#
        guard case .ready(let fallback) = VoiceProtocol.parseStart(sshOnly) else { return XCTFail("expected fallback hello") }
        XCTAssertNil(fallback.udp)
        XCTAssertEqual(fallback.micPort, 39112)

        XCTAssertEqual(
            VoiceProtocol.parseStart(#"{"error":"bind_failed","detail":"port busy"}"#),
            .failed(code: "bind_failed", detail: "port busy")
        )
    }

    func testVoiceCommandAndUdpReliabilityClassification() {
        let posix = VoiceProtocol.voiceCommand(windows: false, port: 24713, resumeSession: "s1", resumeToken: "tok+/=", idleTimeoutSec: 300)
        XCTAssertEqual(posix, "\"$HOME/.roamtty/bin/roamtty-desktop\" voice --proto 1 --port 24713 --resume s1 --token tok+/= --idle-timeout 300")

        let win = VoiceProtocol.voiceCommand(windows: true, port: 24713, idleTimeoutSec: 300)
        XCTAssertEqual(win, #"cmd /c ""%USERPROFILE%\.roamtty\bin\roamtty-desktop.exe" voice --proto 1 --port 24713 --idle-timeout 300""#)

        XCTAssertFalse(UdpLink.reliable(VoiceProtocol.micAudio(streamId: 1, pcm: [0, 0])))
        XCTAssertTrue(UdpLink.reliable(VoiceProtocol.spkAck(streamId: 1, ok: true)))
    }
}
