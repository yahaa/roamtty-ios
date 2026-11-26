import Foundation
import XCTest
@testable import RoamttyDesktopCore

/// Unit tests for `VoiceSession` headless startup, install decoupling, audio routing, barge-in, mute, and `--resume`.
final class VoiceSessionTests: XCTestCase {
    private let manifest = PluginManifest(
        version: "0.9.7",
        baseUrl: "https://example.invalid/",
        protoMin: 1,
        protoMax: 1,
        openh264: "2.6.0",
        targets: [
            "linux-x86_64": .init(file: "linux-x86_64.gz", sha256: "00", size: 1),
            "macos-universal": .init(file: "macos-universal.zip", sha256: "00", size: 1)
        ]
    )

    private var fastTimings: VoiceSession.Timings {
        var t = VoiceSession.Timings()
        t.recoverLimitMs = 3_000
        t.recoverRetryMs = 40
        t.tickMs = 50
        t.exitWaitMs = 200
        return t
    }

    func testHeadlessHostConnectsInjectsMicPortRoutesAudioAndHandlesBargeIn() throws {
        let audio = FakeVoiceAudioIO()
        var injected: [(Int, Bool)] = []
        let lock = NSLock()
        let streamBox = Box<FakeStream?>(nil)

        // Headless server: desktop=no must STILL work for voice!
        let host = FakeHost(probe: FakeHost.probe("no", uname: "Linux x86_64", version: "0.9.7")) { s, _ in
            streamBox.value = s
            s.hello([
                "proto": 1, "ver": "0.9.7", "os": "linux", "mode": "voice",
                "mic_port": 24713, "session": "vs1", "resume_token": "tok1", "codecs": ["pcm16"]
            ])
        }
        let session = VoiceSession(
            config: .init(hostName: "headless", address: "127.0.0.1", tmuxSession: "work"),
            manifest: manifest,
            timings: fastTimings,
            login: { .host(host) },
            injectMicPort: { _, port, win in lock.withLock { injected.append((port, win)) } }
        )
        session.audioIO = audio
        defer { session.close() }
        session.start()

        XCTAssertTrue(waitUntil(3) {
            if case .ready(24713, _) = session.phase { return true }
            return false
        })
        XCTAssertEqual(lock.withLock { injected.map(\.0) }, [24713])
        let stream = try XCTUnwrap(streamBox.value)
        XCTAssertTrue(stream.command.contains("voice --proto 1 --port 24713"))

        // Concurrent MIC_START + SPK_START (/voice live).
        stream.feed(DesktopProtocol.frame(VoiceProtocol.MIC_START, [1, 0, 0, 0, 0x80, 0x3E, 0, 0, 1]))
        stream.feed(DesktopProtocol.frame(VoiceProtocol.SPK_START, [2, 0, 0, 0, 0xC0, 0x5D, 0, 0, 1]))
        XCTAssertTrue(waitUntil(2) { audio.micStartedIds == [1] && audio.spkStarted == [.init(streamId: 2, sampleRate: 24_000)] })

        // SPK_ACK(ok=1) must be sent back to plugin.
        XCTAssertTrue(waitUntil(2) {
            stream.received.contains { $0.type == VoiceProtocol.SPK_ACK && $0.payload == [2, 0, 0, 0, 1] }
        })

        // Outgoing mic PCM chunks to <=640 B (even-byte aligned), suppressed when muted.
        audio.emitMic(streamId: 1, pcm: [UInt8](repeating: 0x2A, count: 1281))
        XCTAssertTrue(waitUntil(2) {
            stream.received.filter { $0.type == VoiceProtocol.MIC_AUDIO }.count == 2
        })
        let micFrames = stream.received.filter { $0.type == VoiceProtocol.MIC_AUDIO }
        XCTAssertEqual(micFrames.map { $0.payload.count }, [644, 644]) // 4B stream_id + 640B PCM each

        session.setMuted(true)
        audio.emitMic(streamId: 1, pcm: [UInt8](repeating: 0x33, count: 640))
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(stream.received.filter { $0.type == VoiceProtocol.MIC_AUDIO }.count, 2)

        // SPK_AUDIO + SPK_CLEAR (barge-in) + stale stream_id ignored.
        stream.feed(DesktopProtocol.frame(VoiceProtocol.SPK_AUDIO, [2, 0, 0, 0, 1, 2, 3, 4]))
        stream.feed(DesktopProtocol.frame(VoiceProtocol.SPK_AUDIO, [99, 0, 0, 0, 5, 6]))
        stream.feed(DesktopProtocol.frame(VoiceProtocol.SPK_CLEAR, [2, 0, 0, 0]))
        XCTAssertTrue(waitUntil(2) { audio.spkCleared == [2] })
        XCTAssertEqual(audio.spkPlayed, [.init(streamId: 2, pcm: [1, 2, 3, 4])])

        // MIC_STOP & SPK_STOP tear down cleanly.
        stream.feed(DesktopProtocol.frame(VoiceProtocol.MIC_STOP, [1, 0, 0, 0]))
        stream.feed(DesktopProtocol.frame(VoiceProtocol.SPK_STOP, [2, 0, 0, 0]))
        XCTAssertTrue(waitUntil(2) { audio.micStoppedIds == [1] && audio.spkStoppedIds == [2] })
    }

    func testSpeakerErrorRepliesWithSpkAckError() throws {
        let audio = FakeVoiceAudioIO()
        audio.speakerStartError = VoiceAudioError("audio device busy\nretry")
        let streamBox = Box<FakeStream?>(nil)
        let host = FakeHost(probe: FakeHost.probe("no", uname: "Linux x86_64", version: "0.9.7")) { s, _ in
            streamBox.value = s
            s.hello(["proto": 1, "ver": "0.9.7", "os": "linux", "mode": "voice", "mic_port": 24713, "session": "s1", "resume_token": "t1", "codecs": ["pcm16"]])
        }
        let session = VoiceSession(config: .init(hostName: "h", address: "127.0.0.1"), manifest: manifest, timings: fastTimings, login: { .host(host) })
        session.audioIO = audio
        defer { session.close() }
        session.start()
        XCTAssertTrue(waitUntil(2) { if case .ready = session.phase { return true }; return false })
        let stream = try XCTUnwrap(streamBox.value)
        stream.feed(DesktopProtocol.frame(VoiceProtocol.SPK_START, [7, 0, 0, 0, 0xC0, 0x5D, 0, 0, 1]))
        XCTAssertTrue(waitUntil(2) {
            stream.received.contains { f in
                guard f.type == VoiceProtocol.SPK_ACK, f.payload.count >= 5 else { return false }
                return f.payload[0] == 7 && f.payload[4] == 0 && String(decoding: f.payload.dropFirst(5), as: UTF8.self) == "audio device busy retry"
            }
        })
    }

    func testStreamDropResumesWithSessionTokenAndReinjectsMicPort() {
        var ports: [Int] = []
        let lock = NSLock()
        let host = FakeHost(probe: FakeHost.probe("no", uname: "Linux x86_64", version: "0.9.7")) { s, attempt in
            if attempt == 1 {
                s.hello(["proto": 1, "ver": "0.9.7", "os": "linux", "mode": "voice", "mic_port": 24713, "session": "sessA", "resume_token": "tokA+=", "codecs": ["pcm16"]])
                Thread.sleep(forTimeInterval: 0.08)
                s.exit(nil)
            } else {
                s.hello(["proto": 1, "ver": "0.9.7", "os": "linux", "mode": "voice", "mic_port": 24713, "session": "sessA", "resume_token": "tokA+=", "codecs": ["pcm16"]])
            }
        }
        let session = VoiceSession(
            config: .init(hostName: "h", address: "127.0.0.1"),
            manifest: manifest,
            timings: fastTimings,
            login: { .host(host) },
            injectMicPort: { _, port, _ in lock.withLock { ports.append(port) } }
        )
        defer { session.close() }
        session.start()

        XCTAssertTrue(waitUntil(3) { host.allStreams.count >= 2 && lock.withLock { ports.count >= 2 } })
        XCTAssertTrue(host.allStreams[1].command.contains("--resume sessA --token tokA+="), host.allStreams[1].command)
        XCTAssertEqual(lock.withLock { ports }, [24713, 24713])
    }

    func testHeadlessInstallSkipsOpenH264AndRegisterSteps() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("voice-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let local = LocalShellHost(home: home)
        let binary = Data("#!/bin/sh\necho 'roamtty-desktop 0.9.7 proto 1'\n".utf8)
        let src = home.appendingPathComponent("src")
        try binary.write(to: src)
        XCTAssertEqual(local.run("gzip -c src > release.gz", timeout: 5) { _ in }, 0)
        let packed = try Data(contentsOf: home.appendingPathComponent("release.gz"))
        let steps = Box<[DesktopPluginInstaller.Step]>([])
        let installer = DesktopPluginInstaller(remote: local, fetch: { _ in packed }, onStep: { steps.value.append($0) })
        let build = DesktopPluginInstaller.Build(
            version: "0.9.7",
            url: "http://127.0.0.1:9/linux-x86_64.gz",
            sha256: PluginManifest.sha256Hex(binary),
            openh264Url: "http://127.0.0.1:9/openh264.bz2"
        )
        XCTAssertEqual(installer.install(build, headless: true), .installed)
        XCTAssertFalse(steps.value.contains(.encoderHost))
        XCTAssertFalse(steps.value.contains(.encoderPhone))
        XCTAssertFalse(steps.value.contains(.register))
        XCTAssertEqual(steps.value.last, .done)
    }

    func testUdpTransportCarriesVoiceFrames() throws {
        let key = (0..<16).map { UInt8($0) }
        let udpHost = UdpHostStandIn(key: key)
        let audio = FakeVoiceAudioIO()
        let streamBox = Box<FakeStream?>(nil)
        let host = FakeHost(probe: FakeHost.probe("no", uname: "Linux x86_64", version: "0.9.7")) { s, _ in
            streamBox.value = s
            s.hello([
                "proto": 1, "ver": "0.9.7", "os": "linux", "mode": "voice",
                "mic_port": 24713, "session": "u1", "resume_token": "t1",
                "udp": ["port": 60123, "key": Data(key).base64EncodedString()],
                "codecs": ["pcm16"]
            ])
        }
        let session = VoiceSession(
            config: .init(hostName: "h", address: "127.0.0.1"),
            manifest: manifest,
            timings: fastTimings,
            login: { .host(host) },
            makeUdp: { _, _ in udpHost }
        )
        session.audioIO = audio
        defer { session.close() }
        session.start()

        XCTAssertTrue(waitUntil(3) { session.onUdp })
        let stream = try XCTUnwrap(streamBox.value)
        stream.feed(DesktopProtocol.frame(VoiceProtocol.MIC_START, [3, 0, 0, 0, 0x80, 0x3E, 0, 0, 1]))
        XCTAssertTrue(waitUntil(2) { audio.micStartedIds == [3] })
        audio.emitMic(streamId: 3, pcm: [UInt8](repeating: 0x11, count: 640))
        XCTAssertTrue(waitUntil(2) { udpHost.frames.contains { $0.type == VoiceProtocol.MIC_AUDIO } })
    }
}

private final class FakeVoiceAudioIO: VoiceAudioIO, @unchecked Sendable {
    struct StartedSpeaker: Equatable { let streamId: UInt32; let sampleRate: UInt32 }
    struct PlayedChunk: Equatable { let streamId: UInt32; let pcm: [UInt8] }

    private let lock = NSLock()
    var micStartedIds: [UInt32] = []
    var micStoppedIds: [UInt32] = []
    var spkStarted: [StartedSpeaker] = []
    var spkPlayed: [PlayedChunk] = []
    var spkCleared: [UInt32] = []
    var spkStoppedIds: [UInt32] = []
    var speakerStartError: VoiceAudioError?
    private var onPcm: (@Sendable (UInt32, [UInt8]) -> Void)?

    func startMic(streamId: UInt32, sampleRate: UInt32, channels: UInt8, onPcm: @escaping @Sendable (UInt32, [UInt8]) -> Void) {
        lock.withLock { micStartedIds.append(streamId); self.onPcm = onPcm }
    }
    func stopMic(streamId: UInt32) { lock.withLock { micStoppedIds.append(streamId); onPcm = nil } }
    func startSpeaker(streamId: UInt32, sampleRate: UInt32, channels: UInt8) -> Result<Void, VoiceAudioError> {
        lock.withLock {
            if let err = speakerStartError { return .failure(err) }
            spkStarted.append(.init(streamId: streamId, sampleRate: sampleRate))
            return .success(())
        }
    }
    func playSpeaker(streamId: UInt32, pcm: [UInt8]) { lock.withLock { spkPlayed.append(.init(streamId: streamId, pcm: pcm)) } }
    func clearSpeaker(streamId: UInt32) { lock.withLock { spkCleared.append(streamId) } }
    func stopSpeaker(streamId: UInt32) { lock.withLock { spkStoppedIds.append(streamId) } }
    func stopAll() { lock.withLock { onPcm = nil } }

    func emitMic(streamId: UInt32, pcm: [UInt8]) {
        let cb = lock.withLock { onPcm }
        cb?(streamId, pcm)
    }
}
