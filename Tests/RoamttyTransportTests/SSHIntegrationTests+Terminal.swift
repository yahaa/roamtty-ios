import XCTest
import RoamttyCore
@testable import RoamttyTransport

/// The terminal beside other work, held SFTP sessions and the PTY.
extension SSHIntegrationTests {
    func testTerminalRemainsUsableDuringSFTP() throws {
        let client = try connect(); defer { client.disconnect() }
        try client.openTerminal(mode: .shell, remoteName: "", columns: 80, rows: 24)
        let received = expectation(description: "concurrent terminal input")
        let output = LockedOutput()
        DispatchQueue.global().async {
            var matched = false
            try? client.runTerminal { data in
                output.append(data)
                if !matched && output.text.contains("CONCURRENT-OK") { matched = true; received.fulfill() }
            }
        }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let remote = "/tmp/roamtty-ios-" + UUID().uuidString
        try Data(repeating: 37, count: 2_000_000).write(to: local)
        defer { try? FileManager.default.removeItem(at: local); _ = try? client.exec("rm -f " + remote) }
        var sent = false
        try client.upload(local, to: remote) { count, _ in
            if !sent && count > 0 { sent = true; XCTAssertTrue(client.write(Data("printf 'CONCURRENT-%s\\n' OK\r".utf8))) }
        }
        wait(for: [received], timeout: 8)
        XCTAssertEqual(try client.exec("wc -c < " + remote).status, 0)
    }
    /// A loop parks on the socket for long only while nothing else can take its packets off it.
    func testLoopWaitsLongOnlyWhileItIsTheConnectionsSoleUser() throws {
        let store = try AppStore(url: URL(fileURLWithPath: ":memory:"))
        let host = Host(name: "Unused", address: "127.0.0.1", port: 22, username: "nobody", auth: .password)
        let client = SSHConnection(host: host, credentials: Credentials(password: nil, privateKey: nil, passphrase: nil), pinStore: store) { _ in nil }
        let terminal = try XCTUnwrap(WorkerWake()), stream = try XCTUnwrap(WorkerWake())
        client.asWaitingLoop(terminal) {
            XCTAssertEqual(client.waitMilliseconds(for: terminal), SSHConnection.idleWaitMs)
            client.asOtherWork {
                XCTAssertEqual(client.waitMilliseconds(for: terminal), SSHConnection.sharedWaitMs, "an exec or SFTP request in flight")
                client.asOtherWork { XCTAssertEqual(client.waitMilliseconds(for: terminal), SSHConnection.sharedWaitMs) }
                XCTAssertEqual(client.waitMilliseconds(for: terminal), SSHConnection.sharedWaitMs, "the outer request still runs")
            }
            XCTAssertEqual(client.waitMilliseconds(for: terminal), SSHConnection.idleWaitMs)
            client.asWaitingLoop(stream) {
                XCTAssertEqual(client.waitMilliseconds(for: terminal), SSHConnection.sharedWaitMs, "two loops share the socket")
                XCTAssertEqual(client.waitMilliseconds(for: stream), SSHConnection.sharedWaitMs)
            }
            XCTAssertEqual(client.waitMilliseconds(for: terminal), SSHConnection.idleWaitMs)
        }
    }
    /// An idle terminal waits up to a second at a time; typed input and remote output still end the wait at once.
    func testIdleTerminalAnswersInputAndLateOutputPromptly() throws {
        let client = try connect(); defer { client.disconnect() }
        try client.openTerminal(mode: .shell, remoteName: "", columns: 80, rows: 24)
        let output = LockedOutput()
        let echoed = expectation(description: "input echo"), late = expectation(description: "output with no input")
        DispatchQueue.global().async {
            var sawEcho = false, sawLate = false
            try? client.runTerminal { data in
                output.append(data)
                if !sawEcho && output.text.contains("IDLE-ECHO-OK") { sawEcho = true; echoed.fulfill() }
                if !sawLate && output.text.contains("IDLE-LATE-OK") { sawLate = true; late.fulfill() }
            }
        }
        Thread.sleep(forTimeInterval: 1.5) // Let the loop settle into its long waits.
        let typed = Date()
        XCTAssertTrue(client.write(Data("printf 'IDLE-ECHO-%s\\n' OK\r".utf8)))
        wait(for: [echoed], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(typed), 0.8, "input wakes the wait")
        XCTAssertTrue(client.write(Data("sleep 1.5; printf 'IDLE-LATE-%s\\n' OK\r".utf8)))
        let asked = Date()
        wait(for: [late], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(asked), 2.3, "readable socket wakes the wait")
        // A side command reads the socket meanwhile: the terminal still gets its own output.
        XCTAssertTrue(client.write(Data("sleep 0.3; printf 'IDLE-SIDE-%s\\n' OK\r".utf8)))
        let side = Date()
        XCTAssertEqual(try client.exec("sleep 1.2; printf done").output, Data("done".utf8))
        XCTAssertTrue(output.text.contains("IDLE-SIDE-OK"), "terminal output arrived while the exec ran")
        XCTAssertLessThan(Date().timeIntervalSince(side), 3)
    }
    /// A folder transfer on one SFTP session: create, upload, list, download, then a recursive delete.
    func testSharedSFTPSessionTransfersATreeAndRecursiveDeleteReusesIt() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-tree-" + UUID().uuidString
        defer { _ = try? client.exec("rm -rf -- " + remote) }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("one".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let back = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: back) }
        let names: [String] = try client.withSFTPSession { sftp in
            try sftp.createDirectory(remote)
            XCTAssertThrowsError(try sftp.createDirectory(remote), "an existing folder fails without ending the session")
            try sftp.createDirectory(remote + "/nested")
            try sftp.upload(local, to: remote + "/nested/a.txt") { _, _ in }
            try sftp.upload(local, to: remote + "/b.txt") { _, _ in }
            try sftp.download(remote + "/nested/a.txt", to: back) { _, _ in }
            return try sftp.listDirectory(remote).entries.map(\.name)
        }
        XCTAssertEqual(names, ["nested", "b.txt"])
        XCTAssertEqual(try Data(contentsOf: back), Data("one".utf8))
        XCTAssertEqual(try client.exec("mkdir -p \(remote)/nested/deeper/deepest && touch \(remote)/nested/deeper/x \(remote)/nested/deeper/deepest/y").status, 0)
        try client.remove(remote, recursive: true)
        XCTAssertNotEqual(try client.exec("test -e " + remote).status, 0)
        XCTAssertTrue(client.isConnected)
    }
    /// A path search reads every folder through one held session, across awaits, then closes it.
    func testHeldSFTPSessionServesAPathSearchAndEndsWhenClosed() async throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-search-" + UUID().uuidString
        XCTAssertEqual(try client.exec("mkdir -p \(remote)/alpha/one \(remote)/alpha/two \(remote)/beta && touch \(remote)/alpha/one/f.txt").status, 0)
        defer { _ = try? client.exec("rm -rf -- " + remote) }
        let sftp = try client.holdSFTPSession()
        var reads: [String] = []
        let result = try await resolveRemoteSearchDirectories(directory: remote, prefix: "al/on", showHidden: false) { path in
            reads.append(path)
            return try sftp.listDirectory(path)
        }
        XCTAssertEqual(reads.count, 3, "the base folder, alpha, then one")
        XCTAssertEqual(result.directories.map(\.path), [remote + "/alpha/one"])
        XCTAssertEqual(result.directories.first?.entries.map(\.name), ["f.txt"])
        XCTAssertThrowsError(try sftp.listDirectory(remote + "/missing"), "a failed read leaves the session usable")
        XCTAssertEqual(try sftp.listDirectory(remote).entries.map(\.name), ["alpha", "beta"])
        // While it is held, a terminal loop on this connection waits briefly; closing it restores the long wait.
        let loop = try XCTUnwrap(WorkerWake())
        client.asWaitingLoop(loop) { XCTAssertEqual(client.waitMilliseconds(for: loop), SSHConnection.sharedWaitMs) }
        sftp.close(); sftp.close()
        client.asWaitingLoop(loop) { XCTAssertEqual(client.waitMilliseconds(for: loop), SSHConnection.idleWaitMs) }
        XCTAssertThrowsError(try sftp.listDirectory(remote)) { XCTAssertEqual($0 as? RoamError, .cancelled) }
        XCTAssertEqual(try client.listDirectory(remote).entries.map(\.name), ["alpha", "beta"])
        XCTAssertTrue(client.isConnected)
    }
    func testHeldSFTPSessionRefusesACancelledRequest() throws {
        let client = try connect(); defer { client.disconnect() }
        let token = TransferCancellation(); token.cancel()
        XCTAssertThrowsError(try client.holdSFTPSession(cancellation: token)) { XCTAssertEqual($0 as? RoamError, .cancelled) }
        let loop = try XCTUnwrap(WorkerWake())
        client.asWaitingLoop(loop) { XCTAssertEqual(client.waitMilliseconds(for: loop), SSHConnection.idleWaitMs, "a refused open ends its work") }
        XCTAssertEqual(try client.exec("printf ok").output, Data("ok".utf8))
    }
    func testPTYInputAndResize() throws {
        let client = try connect(); defer { client.disconnect() }
        try client.openTerminal(mode: .shell, remoteName: "", columns: 80, rows: 24)
        let ready = expectation(description: "terminal output")
        let output = LockedOutput()
        DispatchQueue.global().async {
            try? client.runTerminal { data in
                output.append(data)
                if output.text.contains("ROAMTTY-PTY-OK") { ready.fulfill(); client.disconnect() }
            }
        }
        XCTAssertTrue(client.write(Data("printf 'ROAMTTY-PTY-%s\\n' OK\r".utf8)))
        client.resize(columns: 100, rows: 40)
        wait(for: [ready], timeout: 8)
    }
    func testTmuxGuardQueriesActivePaneOfExactSession() throws {
        let client = try connect(); defer { client.disconnect() }
        guard try client.exec(RemoteCommands.tmuxProbe).status == 0 else { throw XCTSkip("tmux is not installed on fixture") }
        let name = "roamtty-test-" + UUID().uuidString.prefix(8)
        XCTAssertEqual(try client.exec("tmux new-session -d -s " + name).status, 0)
        defer { _ = try? client.exec(RemoteCommands.killTmux(name)) }
        let state = try client.exec(RemoteCommands.tmuxAlternateScreen(name))
        XCTAssertEqual(state.status, 0)
        XCTAssertEqual(String(decoding: state.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "0")
    }
}
