import Foundation
import XCTest
@testable import RoamttyDesktopCore

final class VoiceOpusPipelineTests: XCTestCase {
    private func sineFrame(rate: UInt32, freqHz: Double, frameIdx: Int) -> [Int16] {
        let n = VoiceOpusMath.frameSamples(rate: rate)
        let start = frameIdx * n
        return (0..<n).map { i in
            let t = Double(start + i) / Double(rate)
            return Int16(sin(t * freqHz * 2.0 * Double.pi) * 14_000.0)
        }
    }

    func testVoiceOpusAndStatsWireRoundTrip() throws {
        let flags = VoiceProtocol.withTurnGen(
            VoiceProtocol.VOICE_FLAG_FEC | VoiceProtocol.VOICE_FLAG_SPEECH | VoiceProtocol.VOICE_FLAG_RESET,
            turnGen: 13
        )
        XCTAssertEqual(VoiceProtocol.turnGenOf(flags), 13)
        let pkt = VoiceOpusPacket(
            streamId: 42,
            seq: 123,
            tsSamples: 123 * 320,
            flags: flags,
            red: [
                VoiceRedEntry(deltaSeq: 1, data: [0x11, 0x22, 0x33]),
                VoiceRedEntry(deltaSeq: 2, data: [0x44, 0x55])
            ],
            primary: [0x01, 0x02, 0x03, 0x04]
        )
        let raw = VoiceProtocol.micOpus(pkt)
        XCTAssertFalse(UdpLink.reliable(raw))
        let frame = try XCTUnwrap(DesktopProtocol.read(raw))
        XCTAssertEqual(frame.type, VoiceProtocol.MIC_OPUS)
        XCTAssertEqual(VoiceProtocol.decodeVoiceOpus(frame.payload), pkt)

        let spkFrame = Frame(type: VoiceProtocol.SPK_OPUS, payload: frame.payload)
        guard case .spkOpus(let decodedSpk)? = VoiceProtocol.decode(spkFrame) else {
            return XCTFail("expected spkOpus")
        }
        XCTAssertEqual(decodedSpk, pkt)

        let st = VoiceStats(streamId: 42, lossPermille: 175, jitterMs: 38, bufferMs: 60, maxBurstLoss: 3, flags: 1)
        let rawSt = VoiceProtocol.voiceStats(st)
        XCTAssertFalse(UdpLink.reliable(rawSt))
        let stFrame = try XCTUnwrap(DesktopProtocol.read(rawSt))
        XCTAssertEqual(stFrame.type, VoiceProtocol.VOICE_STATS_C2S)
        XCTAssertEqual(stFrame.payload.count, 12)
        guard case .voiceStats(let decodedSt)? = VoiceProtocol.decode(Frame(type: VoiceProtocol.VOICE_STATS_S2C, payload: stFrame.payload)) else {
            return XCTFail("expected voiceStats")
        }
        XCTAssertEqual(decodedSt, st)
    }

    func testOpusRedAndJitterBufferSurvive30PercentLossAnd60msBurst() throws {
        let rate: UInt32 = 24_000
        let sender = try XCTUnwrap(VoiceRedSender(streamId: 7, sampleRate: rate, enableDtx: false))
        sender.onPeerStats(VoiceStats(streamId: 7, lossPermille: 180, jitterMs: 55, bufferMs: 80, maxBurstLoss: 3), nowMs: 1_000)
        XCTAssertGreaterThanOrEqual(sender.controller.profile().redCount, 2)

        let jb = try XCTUnwrap(VoiceJitterBuffer(streamId: 7, sampleRate: rate))
        let pkts: [VoiceOpusPacket] = (0..<60).compactMap { sender.encodeSamples20ms(sineFrame(rate: rate, freqHz: 440, frameIdx: $0)) }
        XCTAssertEqual(pkts.count, 60)
        XCTAssertLessThan(pkts[10].primary.count, 140)

        let dropped: Set<UInt32> = [5, 10, 11, 12, 18, 21, 29, 33, 37, 41, 45, 50, 54]
        let delivered = pkts
            .filter { !dropped.contains($0.seq) }
            .map { pkt in (Int64(pkt.seq) * 20 + (pkt.seq == 24 ? 25 : 0), pkt) }
            .sorted { $0.0 < $1.0 }

        var idx = 0
        var played = 0
        var audible = 0
        for tick in 0..<65 {
            let now = Int64(tick) * 20
            while idx < delivered.count && delivered[idx].0 <= now {
                jb.push(delivered[idx].1, nowMs: now)
                idx += 1
            }
            if let pcm = jb.popFrame(nowMs: now) {
                played += 1
                if VoiceOpusMath.pcmRms(pcm) > 0.05 { audible += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(played, 55)
        XCTAssertGreaterThanOrEqual(audible, 50)
        XCTAssertGreaterThanOrEqual(jb.redRecovered, 8)
    }

    func testDtxSuppressesSilenceAndTurnGenDropsStalePackets() throws {
        let sender = try XCTUnwrap(VoiceRedSender(streamId: 1, sampleRate: 16_000, enableDtx: true))
        let speechCount = (0..<5).compactMap { sender.encodeSamples20ms(sineFrame(rate: 16_000, freqHz: 350, frameIdx: $0)) }.count
        XCTAssertEqual(speechCount, 5)
        let silence = [Int16](repeating: 0, count: 320)
        let silentPkts = (0..<50).compactMap { _ in sender.encodeSamples20ms(silence) }
        XCTAssertLessThanOrEqual(silentPkts.count, 16)
        XCTAssertTrue(silentPkts.contains { ($0.flags & VoiceProtocol.VOICE_FLAG_DTX) != 0 })

        let enc = try XCTUnwrap(VoiceOpusEncoder(sampleRate: 24_000, bitrate: 32_000, dtx: false))
        let frame = try XCTUnwrap(enc.encode(sineFrame(rate: 24_000, freqHz: 440, frameIdx: 0)))
        let jb = try XCTUnwrap(VoiceJitterBuffer(streamId: 9, sampleRate: 24_000))
        jb.push(VoiceOpusPacket(streamId: 9, seq: 1, tsSamples: 480, flags: VoiceProtocol.withTurnGen(VoiceProtocol.VOICE_FLAG_SPEECH, turnGen: 1), red: [], primary: frame), nowMs: 0)
        XCTAssertNotNil(jb.popFrame(nowMs: 20))

        jb.clearForBargeIn()
        jb.push(VoiceOpusPacket(streamId: 9, seq: 2, tsSamples: 960, flags: VoiceProtocol.withTurnGen(VoiceProtocol.VOICE_FLAG_SPEECH, turnGen: 1), red: [], primary: frame), nowMs: 40)
        XCTAssertNil(jb.popFrame(nowMs: 60))

        let gen2Flags = VoiceProtocol.withTurnGen(
            VoiceProtocol.VOICE_FLAG_SPEECH | VoiceProtocol.VOICE_FLAG_RESET,
            turnGen: 2
        )
        jb.push(VoiceOpusPacket(streamId: 9, seq: 3, tsSamples: 1440, flags: gen2Flags, red: [], primary: frame), nowMs: 80)
        XCTAssertNotNil(jb.popFrame(nowMs: 100))
    }

    func testWsolaAndPreprocessor() {
        let pcm = sineFrame(rate: 24_000, freqHz: 300, frameIdx: 0)
        let compressed = VoiceOpusMath.wsolaCompress(pcm, targetLen: 420)
        XCTAssertGreaterThanOrEqual(compressed.count, 380)
        XCTAssertLessThan(compressed.count, 480)
        XCTAssertGreaterThan(VoiceOpusMath.pcmRms(compressed), 0.2)

        let pp = VoiceAudioPreprocessor(sampleRate: 16_000, startupMuteMs: 0, fadeInMs: 0)
        var dc = [Int16](repeating: 20_000, count: 320)
        dc.withUnsafeMutableBufferPointer { pp.processInPlace($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(dc.first, 0)
        XCTAssertEqual(dc.last, 0)

        // Default startup mute suppresses 180 ms cold-start clicks, then passes speech cleanly after 20 ms fade-in.
        let startupPp = VoiceAudioPreprocessor(sampleRate: 16_000)
        var click = sineFrame(rate: 16_000, freqHz: 400, frameIdx: 0)
        click.withUnsafeMutableBufferPointer { startupPp.processInPlace($0.baseAddress!, count: $0.count) }
        XCTAssertTrue(click.allSatisfy { $0 == 0 })
        for idx in 1..<10 {
            var warmup = sineFrame(rate: 16_000, freqHz: 400, frameIdx: idx)
            warmup.withUnsafeMutableBufferPointer { startupPp.processInPlace($0.baseAddress!, count: $0.count) }
        }
        var speech = sineFrame(rate: 16_000, freqHz: 400, frameIdx: 10)
        speech.withUnsafeMutableBufferPointer { startupPp.processInPlace($0.baseAddress!, count: $0.count) }
        XCTAssertGreaterThan(VoiceOpusMath.pcmRms(speech), 0.25)

        // Speakerphone residual echo gate: suppresses leaked echo during speaker playback,
        // passes quiet speech after tail, and allows loud user barge-in.
        let gate = VoiceSpeakerEchoGate()
        gate.observeSpeaker(rms: 0.16, nowMs: 1_000)
        var echo = [Int16](repeating: 0, count: 320)
        for i in 0..<320 { echo[i] = Int16(sin(Double(i) * 0.15) * 900.0) } // ~0.02 rms leaked echo
        echo.withUnsafeMutableBufferPointer { gate.filterMicInPlace($0.baseAddress!, count: $0.count, nowMs: 1_020) }
        XCTAssertLessThan(VoiceOpusMath.pcmRms(echo), 0.008)
        var echo2 = [Int16](repeating: 0, count: 320)
        for i in 0..<320 { echo2[i] = Int16(sin(Double(i) * 0.15) * 900.0) }
        echo2.withUnsafeMutableBufferPointer { gate.filterMicInPlace($0.baseAddress!, count: $0.count, nowMs: 1_040) }
        XCTAssertEqual(VoiceOpusMath.pcmRms(echo2), 0.0)

        // After 280 ms tail clears, quiet user speech (~0.015 rms) passes cleanly.
        var quiet = [Int16](repeating: 0, count: 320)
        for i in 0..<320 { quiet[i] = Int16(sin(Double(i) * 0.15) * 700.0) }
        quiet.withUnsafeMutableBufferPointer { gate.filterMicInPlace($0.baseAddress!, count: $0.count, nowMs: 1_350) }
        var quiet2 = [Int16](repeating: 0, count: 320)
        for i in 0..<320 { quiet2[i] = Int16(sin(Double(i) * 0.15) * 700.0) }
        quiet2.withUnsafeMutableBufferPointer { gate.filterMicInPlace($0.baseAddress!, count: $0.count, nowMs: 1_370) }
        XCTAssertGreaterThan(VoiceOpusMath.pcmRms(quiet2), 0.012)
    }

    func testClockDriftPauseAndTtsBurstNeverDropSpeech() throws {
        let rate: UInt32 = 24_000
        let sender = try XCTUnwrap(VoiceRedSender(streamId: 3, sampleRate: rate, enableDtx: false))
        let jb = try XCTUnwrap(VoiceJitterBuffer(streamId: 3, sampleRate: rate))

        // 1. 600 ms TTS burst (30 frames arriving at once) must NOT be fast-forward-dropped.
        for i in 0..<30 {
            let pkt = try XCTUnwrap(sender.encodeSamples20ms(sineFrame(rate: rate, freqHz: 440, frameIdx: i)))
            jb.push(pkt, nowMs: 0)
        }
        var burstPlayed = 0
        for tick in 0..<35 {
            if let pcm = jb.popFrame(nowMs: Int64(tick) * 20), VoiceOpusMath.pcmRms(pcm) > 0.05 { burstPlayed += 1 }
        }
        XCTAssertGreaterThanOrEqual(burstPlayed, 28)

        // 2. 400 ms pause then sender resumes at seq 30.
        for tick in 35..<55 { _ = jb.popFrame(nowMs: Int64(tick) * 20) }
        var resumedAudible = 0
        for i in 0..<15 {
            let now = Int64(55 + i) * 20
            let pkt = try XCTUnwrap(sender.encodeSamples20ms(sineFrame(rate: rate, freqHz: 440, frameIdx: 30 + i)))
            jb.push(pkt, nowMs: now)
            if let pcm = jb.popFrame(nowMs: now), VoiceOpusMath.pcmRms(pcm) > 0.05 { resumedAudible += 1 }
        }
        XCTAssertGreaterThanOrEqual(resumedAudible, 13)
        XCTAssertEqual(jb.statsSnapshot(nowMs: 70 * 20).lossPermille, 0)
    }

    private func makeOpusSession(
        audio: FakeVoiceAudioIO,
        streamBox: Box<FakeStream?>
    ) -> VoiceSession {
        let manifest = PluginManifest(
            version: "0.9.7", baseUrl: "https://example.invalid/", protoMin: 1, protoMax: 1, openh264: "2.6.0",
            targets: ["linux-x86_64": .init(file: "linux-x86_64.gz", sha256: "00", size: 1)]
        )
        var timings = VoiceSession.Timings()
        timings.tickMs = 50; timings.shutdownGraceMs = 20
        let host = FakeHost(probe: FakeHost.probe("no", uname: "Linux x86_64", version: "0.9.7")) { s, _ in
            streamBox.value = s
            s.hello([
                "proto": 1, "ver": "0.9.7", "os": "linux", "mode": "voice",
                "mic_port": 24713, "session": "vs_opus", "resume_token": "tok_opus", "codecs": ["opus", "pcm16"]
            ])
        }
        let session = VoiceSession(
            config: .init(hostName: "headless", address: "127.0.0.1"),
            manifest: manifest, timings: timings, login: { .host(host) }
        )
        session.audioIO = audio
        return session
    }

    func testVoiceSessionOpusNegotiationStreamsMicOpusSpkOpusAndVoiceStats() throws {
        let audio = FakeVoiceAudioIO()
        audio.mockStats = VoiceStats(streamId: 2, lossPermille: 40, jitterMs: 18, bufferMs: 40, maxBurstLoss: 1)
        let streamBox = Box<FakeStream?>(nil)
        let session = makeOpusSession(audio: audio, streamBox: streamBox)
        defer { session.close() }
        session.start()

        XCTAssertTrue(waitUntil(3) { if case .ready(24713, _) = session.phase { return true }; return false })
        let stream = try XCTUnwrap(streamBox.value)
        XCTAssertTrue(waitUntil(2) {
            stream.received.contains { f in
                f.type == DesktopProtocol.CONFIG && String(decoding: f.payload, as: UTF8.self).contains("\"voice_codec\":\"opus\"")
            }
        })

        stream.feed(DesktopProtocol.frame(VoiceProtocol.MIC_START, [1, 0, 0, 0, 0x80, 0x3E, 0, 0, 1]))
        stream.feed(DesktopProtocol.frame(VoiceProtocol.SPK_START, [2, 0, 0, 0, 0xC0, 0x5D, 0, 0, 1]))
        XCTAssertTrue(waitUntil(2) { audio.micStartedIds == [1] && audio.spkStarted == [.init(streamId: 2, sampleRate: 24_000)] })

        let badStats = VoiceStats(streamId: 1, lossPermille: 200, jitterMs: 60, bufferMs: 80, maxBurstLoss: 3)
        let stFrame = try XCTUnwrap(DesktopProtocol.read(VoiceProtocol.voiceStats(badStats)))
        stream.feed(DesktopProtocol.frame(VoiceProtocol.VOICE_STATS_S2C, stFrame.payload))
        Thread.sleep(forTimeInterval: 0.04)

        let speechBytes = VoiceOpusMath.int16ToBytes(sineFrame(rate: 16_000, freqHz: 440, frameIdx: 0))
        audio.emitMic(streamId: 1, pcm: speechBytes)
        audio.emitMic(streamId: 1, pcm: speechBytes)
        XCTAssertTrue(waitUntil(2) { stream.received.filter { $0.type == VoiceProtocol.MIC_OPUS }.count >= 2 })
        XCTAssertTrue(stream.received.filter { $0.type == VoiceProtocol.MIC_AUDIO }.isEmpty)
        let secondPkt = try XCTUnwrap(VoiceProtocol.decodeVoiceOpus(stream.received.filter { $0.type == VoiceProtocol.MIC_OPUS }[1].payload))
        XCTAssertFalse(secondPkt.red.isEmpty)

        let spkPkt = VoiceOpusPacket(streamId: 2, seq: 1, tsSamples: 480, flags: VoiceProtocol.VOICE_FLAG_SPEECH, red: [], primary: [0xAB, 0xCD])
        let spkWire = try XCTUnwrap(DesktopProtocol.read(VoiceProtocol.micOpus(spkPkt)))
        stream.feed(DesktopProtocol.frame(VoiceProtocol.SPK_OPUS, spkWire.payload))
        XCTAssertTrue(waitUntil(2) { audio.spkOpusPackets.count == 1 && audio.spkOpusPackets[0].seq == 1 })
        XCTAssertTrue(waitUntil(2) { stream.received.contains { $0.type == VoiceProtocol.VOICE_STATS_C2S } })

        // Negotiated 24 kHz MIC_START frames 960-byte Opus chunks instead of hardcoded 640 B.
        stream.feed(DesktopProtocol.frame(VoiceProtocol.MIC_START, [3, 0, 0, 0, 0xC0, 0x5D, 0, 0, 1]))
        XCTAssertTrue(waitUntil(2) { audio.micStartedIds.contains(3) })
        let speech24 = VoiceOpusMath.int16ToBytes(sineFrame(rate: 24_000, freqHz: 440, frameIdx: 0))
        XCTAssertEqual(speech24.count, 960)
        audio.emitMic(streamId: 3, pcm: Array(speech24.prefix(640)))
        audio.emitMic(streamId: 3, pcm: Array(speech24.dropFirst(640)))
        XCTAssertTrue(waitUntil(2) {
            stream.received.contains { f in
                f.type == VoiceProtocol.MIC_OPUS && VoiceProtocol.decodeVoiceOpus(f.payload)?.streamId == 3
            }
        })
    }

    func testDuplicateClearCannotSilenceTheRestOfTheCurrentTurn() throws {
        let sender = try XCTUnwrap(VoiceRedSender(streamId: 1, sampleRate: 24_000, enableDtx: false))
        let jb = try XCTUnwrap(VoiceJitterBuffer(streamId: 1, sampleRate: 24_000))
        func push(_ i: Int, generation: UInt8) throws {
            let packet = try XCTUnwrap(sender.encodeSamples20ms(sineFrame(rate: 24_000, freqHz: 440, frameIdx: i)))
            jb.push(.init(streamId: 1, seq: UInt32(i), tsSamples: UInt32(i * 480),
                          flags: VoiceProtocol.withTurnGen(packet.flags, turnGen: generation), red: [], primary: packet.primary),
                    nowMs: Int64(i * 20))
        }
        try push(0, generation: 0)
        _ = jb.clearForBargeIn(nowMs: 10)
        try push(1, generation: 1)
        _ = jb.clearForBargeIn(nowMs: 500)
        for i in 26...50 { try push(i, generation: 1) }
        XCTAssertNotNil(jb.popFrame(nowMs: 1_000))
    }

    func testLateSpkClearAfterNewTurnPacketDoesNotDoubleAdvanceTurnGen() throws {
        let enc = try XCTUnwrap(VoiceOpusEncoder(sampleRate: 24_000, bitrate: 32_000, dtx: false))
        let frame = try XCTUnwrap(enc.encode(sineFrame(rate: 24_000, freqHz: 440, frameIdx: 0)))
        let jb = try XCTUnwrap(VoiceJitterBuffer(streamId: 9, sampleRate: 24_000))

        jb.push(VoiceOpusPacket(streamId: 9, seq: 1, tsSamples: 480, flags: VoiceProtocol.withTurnGen(VoiceProtocol.VOICE_FLAG_SPEECH, turnGen: 1), red: [], primary: frame), nowMs: 100)
        XCTAssertNotNil(jb.popFrame(nowMs: 120))

        // New-turn gen=2 packet arrives over UDP before delayed SPK_CLEAR arrives over SSH.
        let gen2Reset = VoiceProtocol.withTurnGen(VoiceProtocol.VOICE_FLAG_SPEECH | VoiceProtocol.VOICE_FLAG_RESET, turnGen: 2)
        jb.push(VoiceOpusPacket(streamId: 9, seq: 2, tsSamples: 960, flags: gen2Reset, red: [], primary: frame), nowMs: 140)
        XCTAssertFalse(jb.clearForBargeIn(nowMs: 160))

        jb.push(VoiceOpusPacket(streamId: 9, seq: 3, tsSamples: 1440, flags: VoiceProtocol.withTurnGen(VoiceProtocol.VOICE_FLAG_SPEECH, turnGen: 2), red: [], primary: frame), nowMs: 180)
        XCTAssertNotNil(jb.popFrame(nowMs: 180))
        XCTAssertNotNil(jb.popFrame(nowMs: 200))

        // Next genuine SPK_CLEAR still advances turnGen 2 -> 3 and drops stale gen=2 packets.
        XCTAssertTrue(jb.clearForBargeIn(nowMs: 220))
        jb.push(VoiceOpusPacket(streamId: 9, seq: 4, tsSamples: 1920, flags: VoiceProtocol.withTurnGen(VoiceProtocol.VOICE_FLAG_SPEECH, turnGen: 2), red: [], primary: frame), nowMs: 240)
        XCTAssertNil(jb.popFrame(nowMs: 260))
    }
}
