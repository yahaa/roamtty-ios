import XCTest
@testable import RoamttyCore

final class HostMonitorRetryTests: XCTestCase {
    func testNetworkFailuresBackOffFiveTimesThenStop() {
        let failure = RoamError.transport("Connection closed")
        XCTAssertEqual((1...6).map { HostMonitorRetry.delay(after: failure, attempt: $0, interactive: false) }, [2, 4, 8, 16, 30, nil])
        XCTAssertEqual(HostMonitorRetry.delay(after: RoamError.timeout, attempt: 1, interactive: false), 2)
        XCTAssertNil(HostMonitorRetry.delay(after: failure, attempt: 0, interactive: false))
    }
    func testRejectedCancelledAndInteractiveLoginsNeverRetry() {
        let errors: [RoamError] = [.authentication, .hostKeyChanged("a", "b"), .rejected, .cancelled, .invalid("Unreadable key")]
        for error in errors { XCTAssertNil(HostMonitorRetry.delay(after: error, attempt: 1, interactive: false)) }
        XCTAssertNil(HostMonitorRetry.delay(after: RoamError.transport("Network failed"), attempt: 1, interactive: true))
        XCTAssertEqual(HostMonitorRetry.phase(after: RoamError.authentication), .authFailed)
        XCTAssertEqual(HostMonitorRetry.phase(after: RoamError.hostKeyChanged("a", "b")), .hostKeyChanged)
        XCTAssertEqual(HostMonitorRetry.phase(after: RoamError.rejected), .disconnected)
    }
}
