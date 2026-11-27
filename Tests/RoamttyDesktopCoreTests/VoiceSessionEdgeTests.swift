import Foundation
import XCTest
@testable import RoamttyDesktopCore

/// Edge-case, concurrency, timeout, fallback, and shutdown contract tests for `VoiceSession` and `UdpLink`.
final class VoiceSessionEdgeTests: XCTestCase {
    private let manifest = PluginManifest(
        version: "0.9.7",
        baseUrl: "https://example.invalid/",
        protoMin: 1,
        protoMax: 1,
        openh264: "2.6.0",
        targets: ["linux-x86_64": .init(file: "linux-x86_64.gz", sha256: "00", size: 1)]
    )

    private var fastTimings: VoiceSession.Timings {
        var t = VoiceSession.Timings()
        t.recoverLimitMs = 3_000
        t.recoverRetryMs = 40
        t.tickMs = 50
        t.exitWaitMs = 200
        t.helloTimeoutMs = 500
        t.shutdownGraceMs = 120
        return t
    }

    func testDefaultTimingsAlignRecoverLimitTo290SecondsAndHelloTimeoutTo25Seconds() {
        let defaults = VoiceSession.Timings()
        XCTAssertEqual(defaults.recoverLimitMs, 290_000)
        XCTAssertEqual(defaults.helloTimeoutMs, 25_000)
    }

    func testShutdownFrameDeliveredBeforeCloseAndEarlyEofEndsWithoutWaitingGrace() throws {
        let streamBox = Box<FakeStream?>(nil)
        let shutdownSeenBeforeClose = Box<Bool>(false)
        let cleared = Box<Bool>(false)
        let host = FakeHost(probe: FakeHost.probe("no", uname: "Linux x86_64", version: "0.9.7")) { s, _ in
            streamBox.value = s
            s.hello([
                "proto": 1, "ver": "0.9.7", "os": "linux", "mode": "voice",
                "mic_port": 24713, "session": "s_eof", "resume_token": "tok_eof", "codecs": ["pcm16"]
            ])
            // Simulate daemon reacting to CONFIG {"shutdown":true} by exiting immediately.
            if waitUntil(3, {
                s.received.contains { f in
                    f.type == DesktopProtocol.CONFIG &&
                    String(decoding: f.payload, as: UTF8.self).contains("\"shutdown\"")
                }
            }) {
                shutdownSeenBeforeClose.value = !s.wasClosed
                s.exit(0)
            }
        }
        var timings = fastTimings
        timings.shutdownGraceMs = 2_000 // Long grace to prove early EOF finishes immediately.
        let session = VoiceSession(
            config: .init(hostName: "h", address: "127.0.0.1"),
            manifest: manifest,
            timings: timings,
            login: { .host(host) },
            injectMicPort: { _, _, _ in },
            clearMicPort: { _, _ in cleared.value = true }
        )
        let ended = Box<Bool>(false)
        session.onEnded = { _ in ended.value = true }
        session.start()
        XCTAssertTrue(waitUntil(3) { if case .ready = session.phase { return true }; return false })

        let stream = try XCTUnwrap(streamBox.value)
        // Feed a benign frame concurrently with close() to verify readFrames doesn't race endStream before shutdown write.
        let start = Date()
        session.close()
        stream.feed(DesktopProtocol.frame(DesktopProtocol.PING, [0, 0, 0, 0, 0, 0, 0, 1]))

        XCTAssertTrue(waitUntil(1.0) { ended.value && cleared.value }, "daemon EOF must end session well before 2s shutdownGraceMs")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        XCTAssertTrue(shutdownSeenBeforeClose.value, "CONFIG shutdown:true must arrive before stream.close()")
    }

    func testIsClosingIgnoresLateMicStartAndSpkStart() throws {
        let audio = FakeVoiceAudioIO()
        let streamBox = Box<FakeStream?>(nil)
        let host = FakeHost(probe: FakeHost.probe("no", uname: "Linux x86_64", version: "0.9.7")) { s, _ in
            streamBox.value = s
            s.hello([
                "proto": 1, "ver": "0.9.7", "os": "linux", "mode": "voice",
                "mic_port": 24713, "session": "s_late", "resume_token": "tok_late", "codecs": ["pcm16"]
            ])
        }
        var timings = fastTimings
        timings.shutdownGraceMs = 150
        let session = VoiceSession(
            config: .init(hostName: "h", address: "127.0.0.1"),
            manifest: manifest,
            timings: timings,
            login: { .host(host) },
            injectMicPort: { _, _, _ in },
            clearMicPort: { _, _ in }
        )
        session.audioIO = audio
        session.start()
        XCTAssertTrue(waitUntil(3) { if case .ready = session.phase { return true }; return false })
        let stream = try XCTUnwrap(streamBox.value)

        session.close()
        // Feed late MIC_START / SPK_START over the stream and directly via handle() while closing.
        stream.feed(DesktopProtocol.frame(VoiceProtocol.MIC_START, [11, 0, 0, 0, 0x80, 0x3E, 0, 0, 1]))
        stream.feed(DesktopProtocol.frame(VoiceProtocol.SPK_START, [12, 0, 0, 0, 0xC0, 0x5D, 0, 0, 1]))
        session.handle(.micStart(streamId: 13, sampleRate: 16_000, channels: 1))
        session.handle(.spkStart(streamId: 14, sampleRate: 24_000, channels: 1))

        XCTAssertTrue(waitUntil(2) { !session.active })
        XCTAssertTrue(audio.micStartedIds.isEmpty, "late MIC_START after close() must be ignored")
        XCTAssertTrue(audio.spkStarted.isEmpty, "late SPK_START after close() must be ignored")
        XCTAssertFalse(stream.received.contains { $0.type == VoiceProtocol.SPK_ACK }, "no SPK_ACK may be sent after close()")
    }

    func testInvalidSpkStartRepliesSpkAckErrorImmediately() throws {
        let audio = FakeVoiceAudioIO()
        let streamBox = Box<FakeStream?>(nil)
        let host = FakeHost(probe: FakeHost.probe("no", uname: "Linux x86_64", version: "0.9.7")) { s, _ in
            streamBox.value = s
            s.hello([
                "proto": 1, "ver": "0.9.7", "os": "linux", "mode": "voice",
                "mic_port": 24713, "session": "s_bad", "resume_token": "tok_bad", "codecs": ["pcm16"]
            ])
        }
        let session = VoiceSession(
            config: .init(hostName: "h", address: "127.0.0.1"),
            manifest: manifest,
            timings: fastTimings,
            login: { .host(host) },
            injectMicPort: { _, _, _ in },
            clearMicPort: { _, _ in }
        )
        session.audioIO = audio
        defer { session.close() }
        session.start()
        XCTAssertTrue(waitUntil(3) { if case .ready = session.phase { return true }; return false })
        let stream = try XCTUnwrap(streamBox.value)

        // Stereo (channels=2) and out-of-range sample rate (4000 Hz = 0x0FA0) must both reply SPK_ACK(ok=0, non-empty error).
        stream.feed(DesktopProtocol.frame(VoiceProtocol.SPK_START, [21, 0, 0, 0, 0xC0, 0x5D, 0, 0, 2]))
        stream.feed(DesktopProtocol.frame(VoiceProtocol.SPK_START, [22, 0, 0, 0, 0xA0, 0x0F, 0, 0, 1]))

        XCTAssertTrue(waitUntil(2) {
            let acks = stream.received.filter { $0.type == VoiceProtocol.SPK_ACK }
            return acks.count >= 2
        })
        let acks = stream.received.filter { $0.type == VoiceProtocol.SPK_ACK }
        for expectedId: UInt8 in [21, 22] {
            let ack = try XCTUnwrap(acks.first { $0.payload.first == expectedId })
            XCTAssertEqual(ack.payload[4], 0)
            let errText = String(decoding: ack.payload.dropFirst(5), as: UTF8.self)
            XCTAssertFalse(errText.isEmpty, "invalid SPK_START must return a non-empty SPK_ACK error")
        }
        XCTAssertTrue(audio.spkStarted.isEmpty)
    }

    func testReadHelloTimeoutFailsWithVoiceSpecificError() {
        let host = FakeHost(probe: FakeHost.probe("no", uname: "Linux x86_64", version: "0.9.7")) { _, _ in
            // Intentionally send nothing: readHello must time out instead of hanging forever.
        }
        var timings = fastTimings
        timings.helloTimeoutMs = 80
        var cfg = VoiceSession.Config(hostName: "silent", address: "127.0.0.1")
        cfg.english = true
        let session = VoiceSession(config: cfg, manifest: manifest, timings: timings, login: { .host(host) })
        defer { session.close() }
        session.start()

        XCTAssertTrue(waitUntil(2) {
            if case .failed = session.phase { return true }
            return false
        }, "readHello must time out promptly, got \(session.phase)")
        if case .failed(let msg) = session.phase {
            XCTAssertEqual(msg, DesktopText.voiceHelloTimeout.text(english: true))
            XCTAssertFalse(msg.lowercased().contains("desktop"))
        }
    }

    func testEmptyResumeTokenFromResumedHelloPreservesPreviousCredentials() {
        let host = FakeHost(probe: FakeHost.probe("no", uname: "Linux x86_64", version: "0.9.7")) { s, attempt in
            switch attempt {
            case 1:
                s.hello([
                    "proto": 1, "ver": "0.9.7", "os": "linux", "mode": "voice",
                    "mic_port": 24713, "session": "sessKeep", "resume_token": "tokKeep+=", "codecs": ["pcm16"]
                ])
                Thread.sleep(forTimeInterval: 0.05)
                s.exit(nil)
            case 2:
                // Resumed hello omits / empties session & resume_token.
                s.hello([
                    "proto": 1, "ver": "0.9.7", "os": "linux", "mode": "voice",
                    "mic_port": 24713, "session": "", "resume_token": "", "codecs": ["pcm16"]
                ])
                Thread.sleep(forTimeInterval: 0.05)
                s.exit(nil)
            default:
                s.hello([
                    "proto": 1, "ver": "0.9.7", "os": "linux", "mode": "voice",
                    "mic_port": 24713, "session": "", "resume_token": "", "codecs": ["pcm16"]
                ])
            }
        }
        let session = VoiceSession(
            config: .init(hostName: "h", address: "127.0.0.1"),
            manifest: manifest,
            timings: fastTimings,
            login: { .host(host) },
            injectMicPort: { _, _, _ in },
            clearMicPort: { _, _ in }
        )
        defer { session.close() }
        session.start()

        XCTAssertTrue(waitUntil(4) { host.allStreams.count >= 3 })
        XCTAssertTrue(host.allStreams[1].command.contains("--resume sessKeep --token tokKeep+="), host.allStreams[1].command)
        XCTAssertTrue(host.allStreams[2].command.contains("--resume sessKeep --token tokKeep+="), host.allStreams[2].command)
    }

    func testUdpLinkOnGiveUpInvokesCallbackAfterTenRetriesAndFallsBackToSshInVoiceSession() throws {
        let key = (0..<16).map { UInt8($0) }
        // 1. Direct UdpLink unit test with manual clock.
        final class BlackholeUdp: UdpTransport, @unchecked Sendable {
            var onReceive: (([UInt8]) -> Void)?
            var localPort: Int { 41000 }
            func send(_ datagram: [UInt8]) {}
            func rebind() throws {}
            func close() {}
        }
        var now: Int64 = 1_000_000
        let gaveUp = Box<[[UInt8]]>([])
        let link = UdpLink(
            key: key,
            transport: BlackholeUdp(),
            clock: { now },
            onFrame: { _ in },
            onVideoLost: {},
            onGiveUp: { frame in gaveUp.value.append(frame) }
        )
        let ackFrame = VoiceProtocol.spkAck(streamId: 5, ok: true)
        link.send(ackFrame, reliable: true, fecRatio: 1.0)
        for _ in 0..<10 {
            now += 120_000
            link.tick()
            XCTAssertTrue(gaveUp.value.isEmpty, "must retry 10 times before giving up")
        }
        now += 120_000
        link.tick()
        XCTAssertEqual(gaveUp.value, [ackFrame])
        link.close()

        // 2. End-to-end VoiceSession fallback: UDP heartbeats succeed (link.alive == true),
        //    but data fragments are dropped so SPK_ACK falls back to SSH outgoing queue.
        let heartbeatOnlyUdp = HeartbeatOnlyUdpTransport(key: key)
        let streamBox = Box<FakeStream?>(nil)
        let host = FakeHost(probe: FakeHost.probe("no", uname: "Linux x86_64", version: "0.9.7")) { s, _ in
            streamBox.value = s
            s.hello([
                "proto": 1, "ver": "0.9.7", "os": "linux", "mode": "voice",
                "mic_port": 24713, "session": "u_fb", "resume_token": "t_fb",
                "udp": ["port": 60123, "key": Data(key).base64EncodedString()],
                "codecs": ["pcm16"]
            ])
        }
        let session = VoiceSession(
            config: .init(hostName: "h", address: "127.0.0.1"),
            manifest: manifest,
            timings: fastTimings,
            login: { .host(host) },
            makeUdp: { _, _ in heartbeatOnlyUdp },
            injectMicPort: { _, _, _ in },
            clearMicPort: { _, _ in }
        )
        session.audioIO = FakeVoiceAudioIO()
        defer { session.close() }
        session.start()

        XCTAssertTrue(waitUntil(3) { session.onUdp })
        let stream = try XCTUnwrap(streamBox.value)
        stream.feed(DesktopProtocol.frame(VoiceProtocol.SPK_START, [33, 0, 0, 0, 0xC0, 0x5D, 0, 0, 1]))
        XCTAssertTrue(waitUntil(4) {
            stream.received.contains { $0.type == VoiceProtocol.SPK_ACK && $0.payload == [33, 0, 0, 0, 1] }
        }, "unacked UDP SPK_ACK must fall back to SSH via onGiveUp")
    }

    func testDesktopOutQueueBoundsMicAudioWhilePreservingControlFrames() throws {
        let q = DesktopOutQueue()
        let ack = VoiceProtocol.spkAck(streamId: 1, ok: true)
        q.send(ack)
        for i: UInt32 in 1...30 {
            q.send(VoiceProtocol.micAudio(streamId: i, pcm: [0x01, 0x02]))
        }
        let taken = try XCTUnwrap(q.take())
        XCTAssertTrue(taken.contains(ack), "control frames must never be evicted by MIC_AUDIO backpressure")
        let micFrames = taken.filter { $0.first == UInt8(VoiceProtocol.MIC_AUDIO) }
        XCTAssertEqual(micFrames.count, DesktopOutQueue.maxQueuedMicFrames)
        let firstKept = try XCTUnwrap(DesktopProtocol.read(micFrames.first!))
        let lastKept = try XCTUnwrap(DesktopProtocol.read(micFrames.last!))
        XCTAssertEqual(VoiceProtocol.readU32LE(firstKept.payload, at: 0), 11)
        XCTAssertEqual(VoiceProtocol.readU32LE(lastKept.payload, at: 0), 30)
    }

    func testVoiceErrorsUseVoiceCopyInsteadOfDesktopCopy() {
        let voiceCases: [DesktopText] = [
            .voiceOpenedElsewhere, .voiceCannotConnect, .voiceConnectionLost, .voiceCannotProbe,
            .voiceHelloTimeout, .voicePluginStartFailed, .voicePluginStartFailedCode(1),
            .voicePluginError("boom"), .voiceDownloadFailed, .voiceChecksumFailed,
            .voiceInstalling(version: "0.9.9", target: "linux-x86_64")
        ]
        for item in voiceCases {
            XCTAssertFalse(item.text(english: false).contains("桌面"), "unexpected desktop copy: \(item.text(english: false))")
            XCTAssertFalse(item.text(english: true).lowercased().contains("desktop"), "unexpected desktop copy: \(item.text(english: true))")
        }
    }
}

/// UDP transport stand-in that replies to heartbeats (keeping `UdpLink.alive == true`) while dropping all data fragments.
private final class HeartbeatOnlyUdpTransport: UdpTransport, @unchecked Sendable {
    var onReceive: (([UInt8]) -> Void)?
    private let crypto: UdpCrypto
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "hb-only-udp")
    private var seq: UInt64 = 1
    var localPort: Int { 40123 }

    init(key: [UInt8]) { crypto = UdpCrypto(key: key) }

    func send(_ datagram: [UInt8]) {
        lock.lock()
        guard let (_, _, plain) = crypto.open(datagram),
              case .heartbeat(let t, _)? = Packet.decode(plain) else { lock.unlock(); return }
        let reply = crypto.seal(dir: UdpWire.DIR_S2C, seq: seq, Packet.heartbeat(t: UdpLink.monotonicUs(), echo: t).encode())
        seq += 1
        lock.unlock()
        queue.async { self.onReceive?(reply) }
    }
    func rebind() throws {}
    func close() {}
}
