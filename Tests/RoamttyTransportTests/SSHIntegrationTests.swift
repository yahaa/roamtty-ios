import XCTest
import RoamttyCore
@testable import RoamttyTransport

final class SSHIntegrationTests: XCTestCase {
    func connect(auth: AuthMethod = .password, key: Data? = nil) throws -> SSHConnection {
        guard let path = ProcessInfo.processInfo.environment["ROAMTTY_TEST_PASSWORD_FILE"] else { throw XCTSkip("Set ROAMTTY_TEST_PASSWORD_FILE to run live OpenSSH tests") }
        let secret = try Data(contentsOf: URL(fileURLWithPath: path))
        let password = String(decoding: secret, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let host = Host(name: "Fixture", address: "127.0.0.1", port: Int(ProcessInfo.processInfo.environment["ROAMTTY_TEST_PORT"] ?? "22992")!, username: "itermux_test", auth: auth)
        let store = try AppStore(url: URL(fileURLWithPath: ":memory:"))
        let connection = SSHConnection(host: host,
            credentials: Credentials(password: Data(password.utf8), privateKey: key, passphrase: key == nil ? nil : "itermux-test-passphrase"),
            pinStore: store) { prompt in
            switch prompt {
            case .verifyHost: return ["trust"]
            case .keyboard(_, let labels, _): return labels.map { _ in password }
            }
        }
        try connection.connect()
        return connection
    }
    func testPasswordAndInteractiveExec() throws {
        for method in [AuthMethod.password, .interactive] {
            let client = try connect(auth: method); defer { client.disconnect() }
            let result = try client.exec("printf 'roamtty-ssh-ok'")
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "roamtty-ssh-ok")
        }
    }
    func testSFTPFileRoundTripLiteralPathsAndNoOverwrite() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-" + UUID().uuidString
        XCTAssertEqual(try client.exec("mkdir -m 700 " + remote).status, 0)
        defer { _ = try? client.exec("rm -rf " + remote) }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let bytes = Data((0..<250_000).map { UInt8($0 % 251) })
        let source = local.appendingPathComponent("source"); try bytes.write(to: source)
        let remoteFile = remote + "/中文 ' * ? \\ file.bin"
        var last: Int64 = 0
        try client.upload(source, to: remoteFile) { size, _ in last = size }
        XCTAssertEqual(last, Int64(bytes.count))
        XCTAssertThrowsError(try client.upload(source, to: remoteFile) { _, _ in })
        let listed = try client.listDirectory(remote)
        XCTAssertEqual(listed.entries.count, 1)
        XCTAssertEqual(listed.entries.first?.name, "中文 ' * ? \\ file.bin")
        let destination = local.appendingPathComponent("download")
        try client.download(remoteFile, to: destination) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let preview = try client.readFile(remoteFile, maxBytes: 10)
        XCTAssertEqual(preview.data.count, 10)
        XCTAssertTrue(preview.truncated)
        try client.rename(remoteFile, to: remote + "/renamed")
        try client.remove(remote + "/renamed")
        XCTAssertTrue(try client.listDirectory(remote).entries.isEmpty)
    }
    func testNonUTF8NamesAreLeftOutRatherThanAliasingAnotherFile() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-" + UUID().uuidString
        // bad\xff decodes lossily to the valid name bad\u{FFFD}, so both used to share one path.
        XCTAssertEqual(try client.exec("mkdir -m 700 " + remote + " && cd " + remote + " && printf X > \"$(printf 'bad\\377')\" && printf KEEP > \"$(printf 'bad\\357\\277\\275')\"").status, 0)
        defer { _ = try? client.exec("rm -rf -- " + remote) }
        let listed = try client.listDirectory(remote)
        XCTAssertEqual(listed.entries.map(\.name), ["bad\u{FFFD}"])
        XCTAssertEqual(listed.unreadableNames, 1)
        let entry = try XCTUnwrap(listed.entries.first)
        XCTAssertEqual(entry.size, 4)
        XCTAssertEqual(try client.readFile(entry.path).text, "KEEP")
        XCTAssertThrowsError(try client.remove(remote, recursive: true), "A folder with unnamed entries must not be emptied")
        XCTAssertEqual(try client.listDirectory(remote).entries.count, 1)
        try client.remove(entry.path)
        XCTAssertEqual(String(decoding: try client.exec("cd " + remote + " && cat -- *").output, as: UTF8.self), "X")
    }
    func testEncryptedEd25519AndRSAKeys() throws {
        guard let path = ProcessInfo.processInfo.environment["ROAMTTY_TEST_KEYS"] else { throw XCTSkip("No fixture keys") }
        for name in ["ed25519", "rsa"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(name))
            let client: SSHConnection
            do { client = try connect(auth: .key, key: data) } catch { XCTFail("Key authentication failed for \(name): \(error)"); continue }
            defer { client.disconnect() }
            XCTAssertEqual(try client.exec("printf key-ok").output, Data("key-ok".utf8))
        }
    }
    func testCreateDirectoryUsesLiteralPathAndRefusesExistingOrCancelledRequests() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-" + UUID().uuidString
        XCTAssertEqual(try client.exec("mkdir -m 700 " + remote).status, 0)
        defer { _ = try? client.exec("rm -rf " + remote) }
        let name = "中文 ' ; $(echo unsafe) folder"
        let path = joinRemotePath(directory: remote, name: name)
        try client.createDirectory(path)
        let entry = try XCTUnwrap(client.listDirectory(remote).entries.first)
        XCTAssertEqual(entry.name, name)
        XCTAssertTrue(entry.isDirectory)
        XCTAssertEqual(entry.permissions & 0o777, 0o755)
        XCTAssertThrowsError(try client.createDirectory(path))
        let cancelled = TransferCancellation(); cancelled.cancel()
        XCTAssertThrowsError(try client.createDirectory(remote + "/cancelled", cancellation: cancelled))
        XCTAssertThrowsError(try client.createDirectory(remote + "/nul\0suffix"))
        XCTAssertEqual(try client.listDirectory(remote).entries.map(\.name), [name])
        XCTAssertTrue(client.isConnected)
    }
    func testCancelledDownloadCleansLocalPartial() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-" + UUID().uuidString
        XCTAssertEqual(try client.exec("dd if=/dev/zero of=" + remote + " bs=1048576 count=4 2>/dev/null").status, 0)
        defer { _ = try? client.exec("rm -f " + remote) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let token = TransferCancellation()
        XCTAssertThrowsError(try client.download(remote, to: file, progress: { count, _ in
            if count > 0 { token.cancel() }
        }, cancellation: token))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try client.exec("printf still-connected").output, Data("still-connected".utf8))
    }
    func testBrowserMutationCancellationDoesNotRetargetOrCloseSharedConnection() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-mutation-" + UUID().uuidString
        XCTAssertEqual(try client.exec("mkdir -m 700 " + remote + " && printf original > " + remote + "/source").status, 0)
        defer { _ = try? client.exec("rm -rf -- " + remote) }
        let token = TransferCancellation(); token.cancel()
        XCTAssertThrowsError(try client.rename(remote + "/source", to: remote + "/destination", cancellation: token)) { XCTAssertEqual($0 as? RoamError, .cancelled) }
        XCTAssertThrowsError(try client.createDirectory(remote + "/new", cancellation: token)) { XCTAssertEqual($0 as? RoamError, .cancelled) }
        XCTAssertThrowsError(try client.remove(remote, recursive: true, cancellation: token)) { XCTAssertEqual($0 as? RoamError, .cancelled) }
        XCTAssertEqual(try client.listDirectory(remote).entries.map(\.name), ["source"])
        try client.rename(remote + "/source", to: remote + "/destination", cancellation: TransferCancellation())
        XCTAssertEqual(try client.readFile(remote + "/destination").text, "original")
        XCTAssertEqual(try client.exec("printf shared-terminal-alive").output, Data("shared-terminal-alive".utf8))
    }
    func testRecursiveBrowserDeleteCancelsAfterActualRemoteProgressAndKeepsOtherOperationsUsable() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-delete-" + UUID().uuidString
        XCTAssertEqual(try client.exec("mkdir -m 700 " + remote + " && i=0; while [ \"$i\" -lt 5000 ]; do : > " + remote + "/entry-$i; i=$((i+1)); done").status, 0)
        defer { _ = try? client.exec("rm -rf -- " + remote) }
        let token = TransferCancellation()
        let done = expectation(description: "Only the requested recursive deletion is cancelled")
        DispatchQueue.global().async {
            do { try client.remove(remote, recursive: true, cancellation: token); XCTFail("Delete completed without observing cancellation") } catch { XCTAssertEqual(error as? RoamError, .cancelled) }
            done.fulfill()
        }
        let deadline = Date().addingTimeInterval(8)
        var observedProgress = false
        while Date() < deadline {
            let result = try client.exec("find " + remote + " -type f 2>/dev/null | wc -l")
            if let count = Int(String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), count < 5000 {
                observedProgress = count > 0; break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        token.cancel()
        XCTAssertTrue(observedProgress, "Cancel after a real unlink, while work remains")
        wait(for: [done], timeout: 8)
        XCTAssertFalse(try client.listDirectory(remote).entries.isEmpty, "Cancellation must stop before deleting the remaining files")
        try client.createDirectory(remote + "/still-usable")
        XCTAssertEqual(try client.exec("printf shared-terminal-alive").output, Data("shared-terminal-alive".utf8))
    }
    func testIndividualTransferCancellationDoesNotCancelOtherJob() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-" + UUID().uuidString
        XCTAssertEqual(try client.exec("mkdir -m 700 " + remote).status, 0)
        defer { _ = try? client.exec("rm -rf " + remote) }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 42, count: 262_144).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let token = TransferCancellation()
        XCTAssertThrowsError(try client.upload(local, to: remote + "/cancelled", progress: { count, _ in
            if count > 0 { token.cancel() }
        }, cancellation: token))
        try client.upload(local, to: remote + "/completed") { _, _ in }
        XCTAssertEqual(try client.listDirectory(remote).entries.map(\.name), ["completed"])
        token.cancel()
        XCTAssertThrowsError(try client.listDirectory(remote, cancellation: token))
    }
    func testCancelAtLastUploadProgressCannotPublishDestination() throws {
        let client = try connect(); defer { client.disconnect() }
        let remote = "/tmp/roamtty-ios-" + UUID().uuidString
        XCTAssertEqual(try client.exec("mkdir -m 700 " + remote).status, 0)
        defer { _ = try? client.exec("rm -rf " + remote) }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 42, count: 10).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let token = TransferCancellation()
        XCTAssertThrowsError(try client.upload(local, to: remote + "/cancelled", progress: { count, _ in
            if count == 10 { token.cancel() }
        }, cancellation: token))
        XCTAssertTrue(try client.listDirectory(remote).entries.isEmpty)
    }
}
final class LockedOutput {
    let lock = NSLock(); var bytes = Data()
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data) }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
}
