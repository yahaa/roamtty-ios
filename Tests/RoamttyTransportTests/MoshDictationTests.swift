#if os(Linux) || os(macOS)
import XCTest
import RoamttyCore
@testable import RoamttyTransport

/// Dictation revises its hypothesis through SwiftTerm's `replace(_:withText:)`, which sends one write per deleted
/// character and then one for the new text. Issue #108: over mosh that burst ran past the unacknowledged write budget
/// and the app showed "输入未发送 / Input was not sent".
final class MoshDictationTests: XCTestCase {
    func testDictationRevisionsAreAllAcceptedAndArriveInOrder() throws {
        let serverPath = ProcessInfo.processInfo.environment["ROAMTTY_MOSH_SERVER"] ?? "/usr/bin/mosh-server"
        guard FileManager.default.isExecutableFile(atPath: serverPath) else { throw XCTSkip("mosh-server is required") }
        let writes = Self.dictationWrites(["我想看一下这个仓库", "我想看一下这个仓库最近有没有新的", "我想看一下这个仓库最近有没有新的问题",
                                           "我想看一下这个仓库最近有没有新的问题需要处理一下", "我想看一下这个仓库最近有没有新的问题需要处理一下吧"])
        XCTAssertGreaterThan(writes.count, 64, "The burst must be longer than the old budget")
        let expected = writes.reduce(Data(), +)
        let capture = FileManager.default.temporaryDirectory.appendingPathComponent("roamtty-dictation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: capture) }
        // Raw and silent, so the shell's line editing leaves every byte as sent and nothing echoes back.
        let script = "stty raw -echo; printf READY; head -c \(expected.count) > " + RemoteCommands.shellQuote(capture.path) + "; printf DONE; sleep 5"
        let server = Process(); server.executableURL = URL(fileURLWithPath: serverPath)
        server.arguments = ["new", "-i", "127.0.0.1", "-p", "60001:60999", "--", "/bin/sh", "-c", script]
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "C.UTF-8"; environment["LC_ALL"] = "C.UTF-8"; environment["MOSH_SERVER_NETWORK_TMOUT"] = "20"
        server.environment = environment
        let announcement = Pipe(); server.standardOutput = announcement; server.standardError = announcement
        try server.run()
        var bytes = Data(); var connection: Mosh.Connect?
        while connection == nil {
            let chunk = announcement.fileHandleForReading.availableData
            if chunk.isEmpty { break }; bytes.append(chunk)
            connection = Mosh.parseConnect(String(decoding: bytes, as: UTF8.self))
        }
        let connect = try XCTUnwrap(connection)
        let transport = try MoshTransport(host: "127.0.0.1", port: connect.port, key: connect.key)
        let ready = XCTestExpectation(description: "shell ready"), done = XCTestExpectation(description: "all bytes read")
        let finished = expectation(description: "transport worker finished")
        defer { transport.close(); wait(for: [finished], timeout: 3) }
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            var text = "", sawReady = false, sawDone = false
            do {
                try transport.run(columns: 80, rows: 24, firstContactTimeout: 5, silenceTimeout: 15) { data in
                    text += String(decoding: data, as: UTF8.self)
                    if !sawReady && text.contains("READY") { sawReady = true; ready.fulfill() }
                    if !sawDone && text.contains("DONE") { sawDone = true; done.fulfill() }
                }
            } catch { if error as? RoamError != .cancelled { XCTFail("Mosh worker failed: \(error)") } }
        }
        guard XCTWaiter.wait(for: [ready], timeout: 6) == .completed else { XCTFail("The shell never started"); return }
        // As SwiftTerm sends them: back to back on one thread, before mosh-server has acknowledged any.
        let rejected = writes.indices.filter { !transport.write(writes[$0]) }
        XCTAssertEqual(rejected, [], "Writes refused out of \(writes.count)")
        guard rejected.isEmpty else { return }
        guard XCTWaiter.wait(for: [done], timeout: 8) == .completed else { XCTFail("Not every byte reached the host"); return }
        XCTAssertEqual(try Data(contentsOf: capture), expected)
    }

    /// The writes SwiftTerm makes while dictation types and then revises its hypothesis.
    static func dictationWrites(_ hypotheses: [String]) -> [Data] {
        var writes = [Data](), previous = ""
        for hypothesis in hypotheses {
            writes += Array(repeating: Data([0x7f]), count: previous.count)
            writes.append(Data(hypothesis.utf8))
            previous = hypothesis
        }
        return writes
    }
}
#endif
