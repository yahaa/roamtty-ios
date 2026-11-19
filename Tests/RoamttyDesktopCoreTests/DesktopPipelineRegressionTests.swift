import XCTest
@testable import RoamttyDesktopCore

final class DesktopPipelineRegressionTests: XCTestCase {
    final class Display: DesktopVideoDisplay, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int64] = []
        private var completions: [(Int64) -> Void] = []
        var renderCompletions: [(Int64) -> Void] { lock.lock(); defer { lock.unlock() }; return completions }
        var onPresent: ((Int64) -> Void)?
        var executor: ((@escaping () -> Void) -> Void)?
        var conversionExecutor: ((@escaping () -> Void) -> Void)?
        private var avccs: [Int64: [UInt8]] = [:]
        func avcc(_ frame: Int64) -> [UInt8]? { lock.lock(); defer { lock.unlock() }; return avccs[frame] }
        var isReadyForMoreVideo = true
        var readyCallback: (() -> Void)?
        func scheduleVideoWork(_ work: @escaping () -> Void) { if let executor { executor(work) } else { work() } }
        func scheduleConversionWork(_ work: @escaping () -> Void) { if let conversionExecutor { conversionExecutor(work) } else { work() } }
        func notifyWhenReadyForVideo(_ work: @escaping () -> Void) { readyCallback = work }
        func cancelVideoReadinessNotification() { readyCallback = nil }
        var frames: [Int64] { lock.lock(); defer { lock.unlock() }; return values }
        func present(frame: Int64, keyframe: Bool, width: Int, height: Int, annexB: [UInt8], offset: Int, avcc: [UInt8], rendered: @escaping (Int64) -> Void) {
            lock.lock(); completions.append(rendered); values.append(frame); avccs[frame] = avcc; lock.unlock()
            onPresent?(frame)
        }
        private var flushed = 0
        var flushes: Int { lock.lock(); defer { lock.unlock() }; return flushed }
        func flush() { lock.lock(); values.removeAll(); flushed += 1; lock.unlock() }
    }
    static func video(_ n: Int64, key: Bool = false, bytes: Int = 0) -> Video {
        var data: [UInt8] = key ? [0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xCE, 0, 0, 0, 1, 0x65] : [0, 0, 0, 1, 0x41]
        data += Array(repeating: 42, count: bytes)
        data.append(UInt8(truncatingIfNeeded: n))
        return Video(frame: n, flags: key ? DesktopProtocol.VIDEO_KEY : 0, captureUs: 1, encodedUs: 2,
                     width: 100, height: 100, data: data, offset: 0)
    }
    func blocked(bytes: Int = 0, _ body: (DesktopVideoDecoder, Display) -> Void) {
        let decoder = DesktopVideoDecoder(), display = Display()
        decoder.display = display; decoder.attach(name: "test")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        decoder.makeAvcc = { bytes, offset in
            if bytes.last == 1 { entered.signal(); _ = release.wait(timeout: .now() + 5) }
            return H264.avcc(bytes, offset: offset)
        }
        DispatchQueue.global().async { decoder.submit(Self.video(1, key: true, bytes: bytes)); done.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        body(decoder, display)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
    }
    func testConcurrentConversionPreservesSubmissionOrder() {
        var output: Display?
        blocked { decoder, display in output = display; decoder.submit(Self.video(2)) }
        XCTAssertEqual(output?.frames, [1, 2])
    }
    func testResetInvalidatesConvertingAndPendingFrames() {
        var output: Display?
        blocked { decoder, display in
            output = display; decoder.submit(Self.video(2)); decoder.reset()
            decoder.submit(Self.video(3)); decoder.submit(Self.video(4, key: true))
        }
        XCTAssertEqual(output?.frames, [4])
    }
    func testDetachInvalidatesConvertingFrame() {
        var output: Display?
        blocked { decoder, display in output = display; decoder.detach() }
        XCTAssertEqual(output?.frames, [])
    }
    func testOverloadDiscardsDependentGOPAndRecoversAtKeyframe() {
        var output: Display?
        blocked { decoder, display in
            output = display
            for n in 2...12 { decoder.submit(Self.video(Int64(n))) }
            decoder.submit(Self.video(20, key: true)); decoder.submit(Self.video(21))
        }
        XCTAssertEqual(output?.frames, [20, 21])
        XCTAssertEqual(output?.flushes, 0, "overload keeps the last picture on screen")
    }
    func testByteOverloadDiscardsGOPBeforeConversion() {
        var output: Display?
        blocked { decoder, display in
            output = display
            decoder.submit(Self.video(2, bytes: 9 * 1024 * 1024))
            decoder.submit(Self.video(3)); decoder.submit(Self.video(4, key: true))
        }
        XCTAssertEqual(output?.frames, [4])
        XCTAssertEqual(output?.flushes, 0, "overload keeps the last picture on screen")
    }
    func testDisplayCanResetReentrantly() {
        let decoder = DesktopVideoDecoder(), display = Display()
        decoder.display = display; decoder.attach(name: "test")
        display.onPresent = { _ in decoder.reset() }
        decoder.submit(Self.video(1, key: true))
        XCTAssertEqual(display.frames, [])
    }
    func testMainExecutorHasOneBoundedDrainAndWaitsForReadiness() {
        let decoder = DesktopVideoDecoder(), display = Display()
        var scheduled: [() -> Void] = []
        display.executor = { scheduled.append($0) }
        display.isReadyForMoreVideo = false
        decoder.display = display; decoder.attach(name: "test")
        for n in 1...20 { decoder.submit(Self.video(Int64(n), key: n == 1 || n == 19)) }
        XCTAssertEqual(scheduled.count, 1, "incoming frames coalesce before main execution")
        scheduled.forEach { $0() }; scheduled.removeAll()
        XCTAssertEqual(display.frames, [], "no conversion/presentation while layer refuses input")
        XCTAssertNotNil(display.readyCallback)
        display.isReadyForMoreVideo = true
        display.readyCallback?()
        XCTAssertEqual(scheduled.count, 1)
        scheduled.forEach { $0() }
        XCTAssertEqual(display.frames, [19, 20])
    }
    func testCloseInvalidatesScheduledMainWork() {
        let decoder = DesktopVideoDecoder(), display = Display()
        var scheduled: [() -> Void] = []
        display.executor = { scheduled.append($0) }
        decoder.display = display; decoder.attach(name: "test")
        decoder.submit(Self.video(1, key: true)); decoder.close()
        scheduled.forEach { $0() }
        XCTAssertEqual(display.frames, [])
    }
    func testResetWhileWaitingForReadinessFlushesAndRearms() {
        let decoder = DesktopVideoDecoder(), display = Display()
        var scheduled: [() -> Void] = []
        display.executor = { scheduled.append($0) }
        display.isReadyForMoreVideo = false
        decoder.display = display; decoder.attach(name: "test")
        decoder.submit(Self.video(1, key: true))
        scheduled.forEach { $0() }; scheduled.removeAll()
        decoder.reset(); decoder.submit(Self.video(2, key: true))
        display.isReadyForMoreVideo = true
        scheduled.forEach { $0() }
        XCTAssertEqual(display.frames, [2])
        XCTAssertNil(display.readyCallback)
    }
    func testOverloadStillAccountsForInvalidatedActiveBytes() {
        var output: Display?
        var retainedDecoder: DesktopVideoDecoder?
        blocked(bytes: 6 * 1024 * 1024) { decoder, display in
            output = display; retainedDecoder = decoder
            decoder.submit(Self.video(2, key: true, bytes: 6 * 1024 * 1024))
        }
        XCTAssertEqual(output?.frames, [], "a new key cannot exceed the byte limit alongside an invalidated conversion")
        retainedDecoder?.submit(Self.video(3, key: true))
        XCTAssertEqual(output?.frames, [3])
    }
    func testMainDrainYieldsDuringContinuousInput() {
        let decoder = DesktopVideoDecoder(), display = Display()
        var scheduled: [() -> Void] = []
        display.executor = { scheduled.append($0) }
        display.onPresent = { frame in if frame < 10 { decoder.submit(Self.video(frame + 1)) } }
        decoder.display = display; decoder.attach(name: "test")
        decoder.submit(Self.video(1, key: true))
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()
        XCTAssertEqual(display.frames, [1, 2, 3, 4], "continuous producers must yield the UI executor after a bounded batch")
        XCTAssertEqual(scheduled.count, 1)
        while !scheduled.isEmpty { scheduled.removeFirst()() }
        XCTAssertEqual(display.frames, Array(1...10).map(Int64.init))
    }
    func testConversionRunsOnItsOwnExecutorBeforePresentation() {
        let decoder = DesktopVideoDecoder(), display = Display()
        var conversions: [() -> Void] = [], presentations: [() -> Void] = []
        display.conversionExecutor = { conversions.append($0) }
        display.executor = { presentations.append($0) }
        var converted: [Int64] = []
        decoder.makeAvcc = { bytes, offset in converted.append(Int64(bytes.last!)); return H264.avcc(bytes, offset: offset) }
        decoder.display = display; decoder.attach(name: "test")
        decoder.submit(Self.video(1, key: true)); decoder.submit(Self.video(2))
        XCTAssertEqual(conversions.count, 1, "one pass converts the queue")
        XCTAssertTrue(presentations.isEmpty, "nothing is presented before it is converted")
        conversions.removeFirst()()
        XCTAssertEqual(converted, [1, 2])
        XCTAssertEqual(display.frames, [], "conversion never presents by itself")
        XCTAssertEqual(presentations.count, 1, "converted units coalesce into one drain")
        presentations.removeFirst()()
        XCTAssertEqual(display.frames, [1, 2])
        XCTAssertEqual(display.avcc(2), H264.avcc(Self.video(2).data))
    }
    func testResetDiscardsAConversionStillRunningInTheBackground() {
        let decoder = DesktopVideoDecoder(), display = Display()
        let queue = DispatchQueue(label: "test-convert"), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        display.conversionExecutor = { queue.async(execute: $0) }
        decoder.makeAvcc = { bytes, offset in
            if bytes.last == 1 { entered.signal(); _ = release.wait(timeout: .now() + 5) }
            return H264.avcc(bytes, offset: offset)
        }
        decoder.display = display; decoder.attach(name: "test")
        decoder.submit(Self.video(1, key: true))
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        decoder.reset(); decoder.submit(Self.video(2, key: true))
        release.signal()
        XCTAssertTrue(waitUntil(2) { display.frames == [2] })
        queue.sync {}
        XCTAssertEqual(display.frames, [2], "the stale conversion of 1 is never presented")
    }
    func testBackgroundConversionKeepsOrderAndContentUnderLoad() {
        let decoder = DesktopVideoDecoder(), display = Display()
        let convert = DispatchQueue(label: "test-convert"), main = DispatchQueue(label: "test-main")
        display.conversionExecutor = { convert.async(execute: $0) }
        display.executor = { main.async(execute: $0) }
        decoder.display = display; decoder.attach(name: "test")
        for n in 1...300 { decoder.submit(Self.video(Int64(n), key: n % 10 == 1, bytes: n % 7 * 300)) }
        // Overload may drop whole GOPs on the way; a keyframe after the burst must still come through.
        decoder.submit(Self.video(301, key: true))
        XCTAssertTrue(waitUntil(3) { display.frames.last == 301 })
        let frames = display.frames
        XCTAssertFalse(frames.isEmpty)
        XCTAssertEqual(frames, frames.sorted(), "units are presented in submission order")
        XCTAssertEqual(Set(frames).count, frames.count)
        for frame in frames {
            let n = Int(frame)
            XCTAssertEqual(display.avcc(frame), H264.avcc(Self.video(frame, key: n % 10 == 1, bytes: n % 7 * 300).data), "frame \(frame)")
        }
    }
    func testImmediateExecutorsDoNotAccumulateRecursiveDrains() {
        let decoder = DesktopVideoDecoder(), display = Display()
        var depth = 0, maximumDepth = 0
        display.executor = { work in
            depth += 1; maximumDepth = max(maximumDepth, depth)
            work(); depth -= 1
        }
        display.onPresent = { frame in if frame < 24 { decoder.submit(Self.video(frame + 1)) } }
        decoder.display = display; decoder.attach(name: "test")
        decoder.submit(Self.video(1, key: true))
        XCTAssertEqual(display.frames, Array(1...24).map(Int64.init))
        XCTAssertEqual(maximumDepth, 1, "synchronous compatibility executors must not grow the stack per batch")
    }
    func session(_ host: FakeHost) throws -> DesktopSession {
        var timings = DesktopSession.Timings(); timings.tickMs = 30; timings.recoverRetryMs = 20
        let config = DesktopSession.Config(hostName: "test", address: "localhost", clientWidth: 100, clientHeight: 100, clientDpi: 160)
        let session = DesktopSession(config: config, manifest: try PluginManifest.bundled(), timings: timings, login: { .host(host) })
        addTeardownBlock { session.close() }
        return session
    }
    func has(_ request: Int, _ stream: FakeStream) -> Bool {
        stream.received.contains { $0.type == DesktopProtocol.REQ && $0.payload.first == UInt8(request) }
    }
}
