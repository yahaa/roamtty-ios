import XCTest
@testable import RoamttyDesktopCore

/// The session's side of the pipeline: pausing, recovery and what the decoder reports.
extension DesktopPipelineRegressionTests {
    func testPauseWhileConnectingSuppressesMediaAndResumeRequestsKeyframe() throws {
        let gate = DispatchSemaphore(value: 0)
        let host = FakeHost(probe: FakeHost.probe()) { stream, _ in
            _ = gate.wait(timeout: .now() + 3)
            stream.hello(PluginFrames.hello(audio: ["opus"]))
            stream.feed(PluginFrames.video(1) + PluginFrames.audio(1))
        }
        let s = try session(host), video = InstantDecoder(), audio = RecordingAudio()
        s.video = video; video.session = s; s.audio = audio
        s.start(); XCTAssertTrue(waitUntil(2) { host.allStreams.count == 1 })
        s.pause(); gate.signal()
        let stream = try XCTUnwrap(host.allStreams.first)
        XCTAssertTrue(waitUntil(1) { self.has(DesktopProtocol.REQ_PAUSE, stream) })
        // A PING proves the reader passed the media packets without relying on a sleep.
        stream.feed(DesktopProtocol.ping(99))
        XCTAssertTrue(waitUntil(1) { stream.received.contains { $0.type == DesktopProtocol.PONG } })
        XCTAssertEqual(video.all, []); XCTAssertEqual(audio.all, [])
        s.resume()
        XCTAssertTrue(waitUntil(1) { self.has(DesktopProtocol.REQ_KEYFRAME, stream) })
        stream.feed(PluginFrames.video(2) + PluginFrames.audio(2))
        XCTAssertTrue(waitUntil(1) { video.all == [2] && audio.all == [2] })
    }
    func testPauseSurvivesRecovery() throws {
        let host = FakeHost(probe: FakeHost.probe()) { stream, n in
            stream.hello(PluginFrames.hello(audio: ["opus"]))
            stream.feed(PluginFrames.video(1))
            if n > 1 { stream.feed(PluginFrames.audio(2)) }
        }
        let s = try session(host), video = InstantDecoder(), audio = RecordingAudio()
        s.video = video; video.session = s; s.audio = audio
        s.start(); XCTAssertTrue(waitUntil(2) { video.all == [1] })
        s.pause(); let first = try XCTUnwrap(host.allStreams.first)
        XCTAssertTrue(waitUntil(1) { self.has(DesktopProtocol.REQ_PAUSE, first) })
        first.exit(0)
        XCTAssertTrue(waitUntil(2) { host.allStreams.count == 2 })
        let second = host.allStreams[1]
        XCTAssertTrue(waitUntil(1) { self.has(DesktopProtocol.REQ_PAUSE, second) })
        second.feed(DesktopProtocol.ping(99))
        XCTAssertTrue(waitUntil(1) { second.received.contains { $0.type == DesktopProtocol.PONG } })
        XCTAssertEqual(video.all, [1]); XCTAssertEqual(audio.all, [])
    }
    func testNewestPauseIntentWinsWhileStreamIsOpening() throws {
        for finalPause in [true, false] {
            let opening = DispatchSemaphore(value: 0), finishOpen = DispatchSemaphore(value: 0)
            let host = FakeHost(probe: FakeHost.probe()) { stream, _ in
                stream.hello(PluginFrames.hello(udp: (30000, Array(repeating: 1, count: 16)), audio: ["opus"]))
                stream.feed(PluginFrames.video(1) + PluginFrames.audio(1))
            }
            var timing = DesktopSession.Timings(); timing.tickMs = 30
            let s = DesktopSession(config: .init(hostName: "test", address: "localhost", clientWidth: 100, clientHeight: 100, clientDpi: 160),
                manifest: try PluginManifest.bundled(), timings: timing, login: { .host(host) }, makeUdp: { _, _ in
                    opening.signal(); _ = finishOpen.wait(timeout: .now() + 3)
                    throw URLError(.cannotConnectToHost)
                })
            let video = InstantDecoder(), audio = RecordingAudio()
            s.video = video; video.session = s; s.audio = audio
            addTeardownBlock { finishOpen.signal(); s.close() }
            s.start(); XCTAssertEqual(opening.wait(timeout: .now() + 2), .success)
            // Opening runs concurrently on the worker; publish several intents before it finishes.
            s.pause(); s.resume()
            if finalPause { s.pause() }
            finishOpen.signal()
            let stream = try XCTUnwrap(host.allStreams.first)
            stream.feed(DesktopProtocol.ping(99))
            XCTAssertTrue(waitUntil(1) { stream.received.contains { $0.type == DesktopProtocol.PONG } })
            let requests = stream.received.filter { frame in
                guard frame.type == DesktopProtocol.REQ, let request = frame.payload.first else { return false }
                return request == UInt8(DesktopProtocol.REQ_PAUSE) || request == UInt8(DesktopProtocol.REQ_RESUME)
            }
            XCTAssertEqual(requests.last?.payload.first, UInt8(finalPause ? DesktopProtocol.REQ_PAUSE : DesktopProtocol.REQ_RESUME))
            XCTAssertEqual(video.all, finalPause ? [] : [1]); XCTAssertEqual(audio.all, finalPause ? [] : [1])
            s.close()
        }
    }
    // Removing completion generation identity lets the old callback consume the reused frame.
    func testOldRenderCompletionCannotConsumeReusedFrameAfterReset() throws {
        let host = FakeHost(probe: FakeHost.probe()) { stream, _ in stream.hello(PluginFrames.hello()) }
        let s = try session(host), decoder = DesktopVideoDecoder(), display = Display()
        s.video = decoder; decoder.session = s; decoder.display = display; decoder.attach(name: "test")
        s.start(); XCTAssertTrue(waitUntil(2) { s.hello != nil })
        let stream = try XCTUnwrap(host.allStreams.first)
        let v = Self.video(1, key: true)
        var b = ByteWriter(); b.u32(1); b.u8(DesktopProtocol.VIDEO_KEY); b.i64(1); b.i64(2); b.u16(100); b.u16(100); b.append(v.data)
        let packet = DesktopProtocol.frame(DesktopProtocol.VIDEO, b.bytes)
        // Seed the prior decoder generation directly: the session correctly rejects reused
        // numbers within one transport stream, independently of decoder completion identity.
        decoder.submit(v)
        XCTAssertTrue(waitUntil(1) { display.renderCompletions.count == 1 })
        let oldCompletion = try XCTUnwrap(display.renderCompletions.first)
        decoder.reset()
        stream.feed(packet)
        XCTAssertTrue(waitUntil(1) { display.renderCompletions.count == 2 })
        let currentCompletion = try XCTUnwrap(display.renderCompletions.last)
        let now = UdpLink.monotonicUs()
        oldCompletion(now + 900_000)
        currentCompletion(now + 150_000)
        XCTAssertTrue(waitUntil(2) { s.stats.latency?.renderMs != nil })
        let renderMs = try XCTUnwrap(s.stats.latency?.renderMs)
        XCTAssertGreaterThanOrEqual(renderMs, 150, "The current completion must still report enqueue latency")
        XCTAssertLessThan(renderMs, 300, "The old completion must not consume the new generation's reused frame")
    }
    func testDelayedDisplayCallbackMeasuresEnqueueWaitAndDecodedPrecedesCallback() throws {
        let host = FakeHost(probe: FakeHost.probe()) { stream, _ in stream.hello(PluginFrames.hello()) }
        let s = try session(host), decoder = DesktopVideoDecoder(), display = Display()
        s.video = decoder; decoder.session = s; decoder.display = display; decoder.attach(name: "test")
        display.onPresent = { _ in XCTAssertEqual(decoder.decodedFrames, 1) }
        s.start(); XCTAssertTrue(waitUntil(2) { s.hello != nil })
        let stream = try XCTUnwrap(host.allStreams.first)
        let v = Self.video(1, key: true)
        var b = ByteWriter(); b.u32(1); b.u8(DesktopProtocol.VIDEO_KEY); b.i64(1); b.i64(2); b.u16(100); b.u16(100); b.append(v.data)
        stream.feed(DesktopProtocol.frame(DesktopProtocol.VIDEO, b.bytes))
        XCTAssertTrue(waitUntil(1) { display.renderCompletions.count == 1 })
        XCTAssertNil(s.stats.latency?.renderMs)
        let rendered = try XCTUnwrap(display.renderCompletions.first)
        rendered(UdpLink.monotonicUs() + 150_000)
        XCTAssertTrue(waitUntil(2) { (s.stats.latency?.renderMs ?? 0) >= 150 })
    }
}
