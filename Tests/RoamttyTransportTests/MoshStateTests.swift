import XCTest
import RoamttyCore
@testable import RoamttyTransport

final class MoshStateTests: XCTestCase {
    func testOldAuthenticatedPacketsCannotResetAProbeTimeout() throws {
        var state = MoshState(start: 0)
        state.heard(at: 1, timestamp: 100, reply: .max, sequence: 10)
        state.requestProbe(at: 2)
        state.heard(at: 11, timestamp: 1000, reply: .max, sequence: 9)
        state.heard(at: 12, timestamp: 1100, reply: .max, sequence: 10)
        XCTAssertEqual(state.lastHeard, 1)
        XCTAssertThrowsError(try state.checkTimeout(at: 13, firstContact: 8, silence: 100, stall: 10))
        state.heard(at: 13, timestamp: 1200, reply: .max, sequence: 11)
        XCTAssertNoThrow(try state.checkTimeout(at: 14, firstContact: 8, silence: 100, stall: 10))
    }

    func testMissingTimestampDoesNotProduceAnInventedReply() {
        var state = MoshState(start: 0)
        state.heard(at: 1, timestamp: .max, reply: .max, sequence: 0)
        XCTAssertEqual(state.timestampReply(at: 1.5), .max)
        XCTAssertNotEqual(MoshState.timestamp(65.535), .max)
    }

    func testInputIsRetransmittedFromAcknowledgedStateAndRemovedOnlyAfterAck() throws {
        var state = MoshState(start: 1)
        state.enqueue(.keys(Data("a".utf8)), at: 1)
        let first = try state.instruction(at: 1)
        XCTAssertEqual(first.oldNum, 0)
        XCTAssertEqual(first.newNum, 1)
        XCTAssertFalse(first.diff.isEmpty)
        XCTAssertEqual(state.nextSendAt(1.1), 2, accuracy: 0.001)
        let resend = try state.instruction(at: 2)
        XCTAssertEqual(resend.oldNum, 0)
        XCTAssertEqual(resend.diff, first.diff)
        state.enqueue(.keys(Data("b".utf8)), at: 2.1)
        let accepted = try state.receive(Mosh.Instruction(oldNum: 0, newNum: 1, ackNum: 1, throwawayNum: 0), at: 2.2)
        XCTAssertEqual(accepted.releasedBytes, 1)
        XCTAssertEqual(accepted.releasedWrites, 1)
        let second = try state.instruction(at: 2.3)
        XCTAssertEqual(second.oldNum, 1)
        XCTAssertEqual(Array(second.diff), [0x0a, 0x05, 0x12, 0x03, 0x22, 0x01, 0x62])
    }

    func testOnlyApplicableRemoteStateProducesOutputAndShutdownIsAcknowledged() throws {
        var state = MoshState(start: 0)
        let diff = Data([0x0a, 0x06, 0x12, 0x04, 0x22, 0x02, 0x68, 0x69])
        let first = Mosh.Instruction(oldNum: 0, newNum: 1, ackNum: 0, throwawayNum: 0, diff: diff)
        XCTAssertEqual(try state.receive(first, at: 1).output, [Data("hi".utf8)])
        XCTAssertTrue(try state.receive(first, at: 2).output.isEmpty)
        XCTAssertTrue(try state.receive(Mosh.Instruction(oldNum: 9, newNum: 10, ackNum: 0, throwawayNum: 0, diff: diff), at: 3).output.isEmpty)
        let ack = try state.instruction(at: 3)
        XCTAssertEqual(ack.ackNum, 1)
        let shutdown = try state.receive(Mosh.Instruction(oldNum: 1, newNum: .max, ackNum: 0, throwawayNum: 0), at: 4)
        XCTAssertTrue(shutdown.serverShutdown)
        XCTAssertEqual(try state.instruction(at: 4, shutdown: true).ackNum, .max)
    }

    func testFirstContactTimeoutAndSleepPastSilenceLimitTriggerFallback() throws {
        var state = MoshState(start: 1)
        XCTAssertNoThrow(try state.checkTimeout(at: 8.9, firstContact: 8, silence: 840, stall: 10))
        XCTAssertThrowsError(try state.checkTimeout(at: 9.1, firstContact: 8, silence: 840, stall: 10))
        state.heard(at: 10, timestamp: 0, reply: 0xffff, sequence: 0)
        XCTAssertNoThrow(try state.checkTimeout(at: 20, firstContact: 8, silence: 840, stall: 10))
        XCTAssertThrowsError(try state.checkTimeout(at: 8 * 3600, firstContact: 8, silence: 840, stall: 10))
    }

    func testUnansweredInputOrProbeTriggersStallButPlainShellMayKeepWaiting() throws {
        for probe in [true, false] {
            var state = MoshState(start: 0)
            state.heard(at: 1, timestamp: 0, reply: 0xffff, sequence: 0)
            if probe { state.requestProbe(at: 2) } else { state.enqueue(.keys(Data("a".utf8)), at: 2) }
            XCTAssertNoThrow(try state.checkTimeout(at: 11, firstContact: 8, silence: 840, stall: 10))
            XCTAssertThrowsError(try state.checkTimeout(at: 13, firstContact: 8, silence: 840, stall: 10))
            XCTAssertNoThrow(try state.checkTimeout(at: 13, firstContact: 8, silence: 840, stall: nil))
            state.heard(at: 13, timestamp: 0, reply: 0xffff, sequence: 1)
            XCTAssertNoThrow(try state.checkTimeout(at: 14, firstContact: 8, silence: 840, stall: 10))
        }
    }

    func testThawGivesWaitingInputAWholeStallLimit() throws {
        var state = MoshState(start: 0)
        state.heard(at: 1, timestamp: 0, reply: 0xffff, sequence: 0)
        state.enqueue(.keys(Data("a".utf8)), at: 2)
        XCTAssertNotNil(state.timeoutReason(at: 600, firstContact: 8, silence: 840, stall: 10))
        state.thawed(at: 600)
        XCTAssertNil(state.timeoutReason(at: 609, firstContact: 8, silence: 840, stall: 10))
        XCTAssertEqual(state.timeoutReason(at: 611, firstContact: 8, silence: 840, stall: 10), "stalled: probe=- input=11.0s heard=610.0s")
        XCTAssertEqual(state.timeoutReason(at: 900, firstContact: 8, silence: 840, stall: nil), "silent for 899.0s")
    }

    func testFreezeDoesNotBecomeDesyncUntilInapplicablePacketsPersist() throws {
        var state = MoshState(start: 0)
        state.heard(at: 1, timestamp: 0, reply: 0xffff, sequence: 0)
        _ = try state.receive(Mosh.Instruction(oldNum: 0, newNum: 1, ackNum: 0, throwawayNum: 0), at: 1)
        state.heard(at: 43, timestamp: 0, reply: 0xffff, sequence: 1)
        _ = try state.receive(Mosh.Instruction(oldNum: 999, newNum: 2, ackNum: 0, throwawayNum: 0), at: 43)
        XCTAssertNoThrow(try state.checkTimeout(at: 43, firstContact: 8, silence: 840, stall: 10))
        state.heard(at: 74, timestamp: 0, reply: 0xffff, sequence: 2)
        _ = try state.receive(Mosh.Instruction(oldNum: 999, newNum: 3, ackNum: 0, throwawayNum: 0), at: 74)
        XCTAssertThrowsError(try state.checkTimeout(at: 74, firstContact: 8, silence: 840, stall: 10))
    }

    func testTimestampReplyAccountsForLocalDelayAndExpiresAfterOneSecond() {
        var state = MoshState(start: 0)
        state.heard(at: 1, timestamp: 100, reply: 0xffff, sequence: 0)
        XCTAssertEqual(state.timestampReply(at: 1.25), 350)
        XCTAssertEqual(state.timestampReply(at: 1.26), 0xffff)
        state.heard(at: 2, timestamp: 100, reply: 0xffff, sequence: 1)
        XCTAssertEqual(state.timestampReply(at: 3.01), 0xffff)
    }

    func testImpossibleAcknowledgmentDoesNotLoseInput() throws {
        var state = MoshState(start: 0)
        state.enqueue(.keys(Data("a".utf8)), at: 0)
        let first = try state.instruction(at: 0)
        let response = try state.receive(Mosh.Instruction(oldNum: 0, newNum: 1, ackNum: 100, throwawayNum: 0), at: 1)
        XCTAssertEqual(response.releasedWrites, 0)
        XCTAssertEqual(try state.instruction(at: 1).diff, first.diff)
    }

    func testProtocolVersionMismatchSurfacesForFallback() {
        var state = MoshState(start: 0)
        XCTAssertThrowsError(try state.receive(Mosh.Instruction(oldNum: 0, newNum: 1, ackNum: 0, throwawayNum: 0, protocolVersion: 3), at: 1))
    }
}
