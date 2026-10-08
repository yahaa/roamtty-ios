import XCTest
@testable import RoamttyCore

final class ModelTests: XCTestCase {
    func testEndpointNormalizationAndValidation() throws {
        XCTAssertEqual(try Host(name: "test", address: "[2001:db8::1]", username: "root").validated().endpoint, "[2001:db8::1]:22")
        XCTAssertEqual(try Host(name: "test", address: "EXAMPLE.COM.", username: "root").validated().endpoint, "[example.com]:22")
        XCTAssertThrowsError(try Host(name: "test", address: "ssh://evil", username: "root").validated())
        XCTAssertThrowsError(try Host(name: "test", address: "a", port: 0, username: "root").validated())
    }
    func testSessionLimitAndIndependentTmuxNames() throws {
        var journal = SessionJournal()
        let first = try journal.create(hostID: "one", mode: .tmux)
        let second = try journal.create(hostID: "one", mode: .tmux)
        XCTAssertNotEqual(first.remoteName, second.remoteName)
        for _ in 0..<6 { _ = try journal.create(hostID: "one", mode: .shell) }
        XCTAssertThrowsError(try journal.create(hostID: "one", mode: .tmux))
        XCTAssertNoThrow(try journal.create(hostID: "two", mode: .tmux))
        journal.close(first.id)
        XCTAssertTrue(journal.records.contains { $0.id == first.id })
        journal.forget(first.id)
        XCTAssertFalse(journal.records.contains { $0.id == first.id })
    }
    func testInputNeverSurvivesReconnectAndRemainsBounded() {
        var queue = InputQueue()
        for _ in 0..<64 { XCTAssertTrue(queue.enqueue(Data([1]))) }
        XCTAssertFalse(queue.enqueue(Data([2])))
        queue.reset()
        XCTAssertNil(queue.pop())
        XCTAssertFalse(queue.enqueue(Data(repeating: 1, count: 256 * 1024 + 1)))
    }
}
