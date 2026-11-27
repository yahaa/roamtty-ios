import Foundation
import XCTest
@testable import RoamttyDesktopCore

/// Unit tests for `VoiceRemoteStreamTracker` remote hangup / early abort detection.
final class VoiceRemoteStreamTrackerTests: XCTestCase {
    func testLiveCallEarlyAbortWhenBothStreamsCloseWithoutAudio() {
        var tracker = VoiceRemoteStreamTracker(mode: .live)
        XCTAssertEqual(tracker.handle(.speakerStarted(streamId: 1, sampleRate: 24_000), at: 100.0), .streamActive)
        XCTAssertEqual(tracker.handle(.micStarted(streamId: 2, sampleRate: 16_000), at: 100.05), .streamActive)
        XCTAssertTrue(tracker.hadAnyStream)

        // Closing only speaker keeps call alive until mic also stops.
        XCTAssertEqual(tracker.handle(.speakerStopped(streamId: 1), at: 101.45), .none)
        // Closing mic 1.46s after start with zero speaker audio classifies as early abort (e.g. Access denied).
        XCTAssertEqual(tracker.handle(.micStopped(streamId: 2), at: 101.46), .scheduleRemoteEnd(.abortedEarly))
        XCTAssertNil(tracker.activeMicStreamId)
        XCTAssertNil(tracker.activeSpkStreamId)
    }

    func testLiveCallEarlyAbortIsOrderIndependentAndHandlesSingleStreamAbort() {
        // Mic closes before speaker.
        var reversed = VoiceRemoteStreamTracker(mode: .live)
        XCTAssertEqual(reversed.handle(.speakerStarted(streamId: 1, sampleRate: 24_000), at: 10.0), .streamActive)
        XCTAssertEqual(reversed.handle(.micStarted(streamId: 2, sampleRate: 16_000), at: 10.02), .streamActive)
        XCTAssertEqual(reversed.handle(.micStopped(streamId: 2), at: 10.29), .none)
        XCTAssertEqual(reversed.handle(.speakerStopped(streamId: 1), at: 10.30), .scheduleRemoteEnd(.abortedEarly))

        // Speaker opens and closes before mic ever connects.
        var speakerOnly = VoiceRemoteStreamTracker(mode: .live)
        XCTAssertEqual(speakerOnly.handle(.speakerStarted(streamId: 1, sampleRate: 24_000), at: 20.0), .streamActive)
        XCTAssertEqual(speakerOnly.handle(.speakerStopped(streamId: 1), at: 20.3), .scheduleRemoteEnd(.abortedEarly))
    }

    func testLiveCallCleanEndAfterSpeakerAudioOrPastEarlyWindow() {
        // Short call that already played speaker audio -> clean `.ended`, not `.abortedEarly`.
        var spoke = VoiceRemoteStreamTracker(mode: .live)
        _ = spoke.handle(.speakerStarted(streamId: 1, sampleRate: 24_000), at: 50.0)
        _ = spoke.handle(.micStarted(streamId: 2, sampleRate: 16_000), at: 50.05)
        XCTAssertEqual(spoke.handle(.speakerAudio(streamId: 1, bytes: 960), at: 51.0), .none)
        XCTAssertTrue(spoke.receivedSpeakerAudio)
        XCTAssertEqual(spoke.handle(.speakerCleared(streamId: 1), at: 51.5), .none)
        XCTAssertEqual(spoke.handle(.micStopped(streamId: 2), at: 52.0), .none)
        XCTAssertEqual(spoke.handle(.speakerStopped(streamId: 1), at: 52.01), .scheduleRemoteEnd(.ended))

        // Longer call (>5s) without speaker audio -> clean `.ended`.
        var silent = VoiceRemoteStreamTracker(mode: .live)
        _ = silent.handle(.speakerStarted(streamId: 1, sampleRate: 24_000), at: 100.0)
        _ = silent.handle(.micStarted(streamId: 2, sampleRate: 16_000), at: 100.1)
        _ = silent.handle(.micStopped(streamId: 2), at: 106.0)
        XCTAssertEqual(silent.handle(.speakerStopped(streamId: 1), at: 106.01), .scheduleRemoteEnd(.ended))
    }

    func testLiveMuteOrStaleStopNeverTriggersRemoteEnd() {
        var tracker = VoiceRemoteStreamTracker(mode: .live)
        _ = tracker.handle(.speakerStarted(streamId: 1, sampleRate: 24_000), at: 1.0)
        _ = tracker.handle(.micStarted(streamId: 2, sampleRate: 16_000), at: 1.01)

        // Even if remote closed mic on mute, speaker remains open -> no remote end.
        XCTAssertEqual(tracker.handle(.micStopped(streamId: 2), at: 2.0), .none)
        XCTAssertEqual(tracker.handle(.micStarted(streamId: 3, sampleRate: 16_000), at: 3.0), .streamActive)
        // Stale micStopped for old id=2 must be ignored.
        XCTAssertEqual(tracker.handle(.micStopped(streamId: 2), at: 3.1), .none)
        XCTAssertEqual(tracker.activeMicStreamId, 3)

        // Duplicate stop after already closed must not re-fire.
        _ = tracker.handle(.micStopped(streamId: 3), at: 10.0)
        XCTAssertEqual(tracker.handle(.speakerStopped(streamId: 1), at: 10.01), .scheduleRemoteEnd(.ended))
        XCTAssertEqual(tracker.handle(.speakerStopped(streamId: 1), at: 10.02), .none)
    }

    func testRecoveryClearsInFlightIdsAndAllowsReannouncedStreamsToEndCleanly() {
        var tracker = VoiceRemoteStreamTracker(mode: .live)
        _ = tracker.handle(.speakerStarted(streamId: 1, sampleRate: 24_000), at: 10.0)
        _ = tracker.handle(.micStarted(streamId: 2, sampleRate: 16_000), at: 10.05)
        _ = tracker.handle(.speakerAudio(streamId: 1, bytes: 960), at: 12.0)

        tracker.beginRecovery()
        XCTAssertNil(tracker.activeMicStreamId)
        XCTAssertNil(tracker.activeSpkStreamId)
        XCTAssertTrue(tracker.hadAnyStream)
        XCTAssertTrue(tracker.receivedSpeakerAudio)

        // Late stop during/after recovery must not end the call.
        XCTAssertEqual(tracker.handle(.micStopped(streamId: 2), at: 13.0), .none)
        XCTAssertEqual(tracker.handle(.speakerStopped(streamId: 1), at: 13.01), .none)

        // Re-announced streams after `--resume` track normally and end cleanly later.
        XCTAssertEqual(tracker.handle(.speakerStarted(streamId: 1, sampleRate: 24_000), at: 14.0), .streamActive)
        XCTAssertEqual(tracker.handle(.micStarted(streamId: 2, sampleRate: 16_000), at: 14.01), .streamActive)
        XCTAssertEqual(tracker.handle(.micStopped(streamId: 2), at: 20.0), .none)
        XCTAssertEqual(tracker.handle(.speakerStopped(streamId: 1), at: 20.01), .scheduleRemoteEnd(.ended))
    }
}
