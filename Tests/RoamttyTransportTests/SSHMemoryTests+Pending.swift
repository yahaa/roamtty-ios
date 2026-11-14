import XCTest
import CNative
import RoamttyCore
@testable import RoamttyTransport

/// Requests still pending when the connection is dropped.
extension SSHMemoryTests {
    func testPendingWindowAdjustmentDisconnectFreesStreamSFTPAndEveryNativeAllocation() throws {
        let allocations = NativeAllocations()
        do {
            let (connection, fd) = try trackedConnection(allocations)
            defer { roam_socket_close(fd) }
            let session = try XCTUnwrap(connection.session)
            let sftp = try XCTUnwrap(libssh2_sftp_init(session))
            let handle = try XCTUnwrap(libssh2_sftp_open_ex(sftp, "/dev/zero", 9, UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE))
            let channel = try XCTUnwrap(libssh2_channel_open_ex(session, "session", 7, 2 * 1024 * 1024, 32768, nil, 0))
            let command = "head -c 16777216 /dev/zero"
            XCTAssertEqual(libssh2_channel_process_startup(channel, "exec", 4, command, UInt32(command.utf8.count)), 0)
            libssh2_session_set_blocking(session, 0)
            // No stdin or keepalive: the first outgoing packet after output
            // drains is the actual read path's receive-window adjustment.
            let callback = unsafeBitCast(blockTrackedWindowSend, to: (@convention(c) () -> Void).self)
            let old = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, callback)
            defer { _ = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, old) }
            let stream = SSHExecStream(connection: connection, channel: channel)
            XCTAssertEqual(allocations.windowBlocked.wait(timeout: .now() + 3), .success)
            connection.disconnect(); roam_socket_shutdown(fd)
            let cleaned = expectation(description: "SFTP native owner finishes behind pending WINDOW_ADJUST")
            DispatchQueue.global().async {
                _ = connection.settle(timeout: 0.1) { libssh2_sftp_close_handle(handle) }
                _ = connection.settle(timeout: 0.1) { libssh2_sftp_shutdown(sftp) }
                cleaned.fulfill()
            }
            wait(for: [cleaned], timeout: 3)
            let deadline = Date().addingTimeInterval(3)
            while !stream.isClosed && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertTrue(stream.isClosed)
        }
        let deadline = Date().addingTimeInterval(2)
        while allocations.blocks != 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(allocations.blocks, 0)
        XCTAssertEqual(allocations.bytes, 0)
        print("WINDOW_ADJUST teardown live_blocks=\(allocations.blocks) live_bytes=\(allocations.bytes)")
    }

    func testPendingExecStdinWriteCancellationCompletesBeforeSignalCleanup() throws {
        let connection = try client()
        let token = TransferCancellation()
        let gate = PendingStreamSend(skipping: 2) { token.cancel() }
        let restore = blockSends(connection, gate)
        defer { restore() }
        let finished = expectation(description: "exec cancels despite its earlier retained stdin packet")
        let started = Date()
        DispatchQueue.global().async {
            do {
                _ = try connection.exec("cat", input: Data(repeating: 42, count: 65536), timeout: 8, cancellation: token)
                XCTFail("Expected cancellation")
            } catch {
                XCTAssertEqual(error as? RoamError, .cancelled)
            }
            finished.fulfill()
        }
        XCTAssertEqual(gate.blocked.wait(timeout: .now() + 3), .success)
        wait(for: [finished], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testPendingTerminalInputBeforeResizeDisconnectCompletesSFTPCleanup() throws {
        let connection = try client()
        try connection.openTerminal(mode: .shell, remoteName: "", columns: 80, rows: 24)
        let sftp = try connection.openSFTP()
        let handle = try connection.pointer { libssh2_sftp_open_ex(sftp, "/dev/zero", 9, UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE) }
        let gate = PendingStreamSend()
        let restore = blockSends(connection, gate)
        defer { restore() }
        XCTAssertTrue(connection.write(Data(repeating: 42, count: 65536)))
        let terminal = expectation(description: "terminal unwinds its input before the queued resize")
        DispatchQueue.global().async { _ = try? connection.runTerminal(onOutput: { _ in }); terminal.fulfill() }
        XCTAssertEqual(gate.blocked.wait(timeout: .now() + 3), .success)
        connection.resize(columns: 100, rows: 40)
        Thread.sleep(forTimeInterval: 0.1)
        connection.disconnect()
        let cleaned = expectation(description: "SFTP cleanup finishes after terminal input and resize")
        DispatchQueue.global().async {
            _ = connection.settle(timeout: 0.1) { libssh2_sftp_close_handle(handle) }
            _ = connection.settle(timeout: 0.1) { libssh2_sftp_shutdown(sftp) }
            cleaned.fulfill()
        }
        wait(for: [terminal, cleaned], timeout: 3)
    }

    func trackedConnection(_ allocations: NativeAllocations) throws -> (SSHConnection, Int32) {
        let connection = try client(connect: false)
        let fd = roam_tcp_connect("127.0.0.1", Int32(ProcessInfo.processInfo.environment["ROAMTTY_TEST_PORT"] ?? "22992")!, 5000)
        guard fd >= 0 else { throw RoamError.transport("Fixture socket failed") }
        let session = try XCTUnwrap(libssh2_session_init_ex(nativeAlloc, nativeFree, nativeRealloc, Unmanaged.passUnretained(allocations).toOpaque()))
        connection.session = session
        libssh2_session_set_timeout(session, 5000)
        XCTAssertEqual(libssh2_session_handshake(session, fd), 0)
        let secret = try String(contentsOfFile: XCTUnwrap(ProcessInfo.processInfo.environment["ROAMTTY_TEST_PASSWORD_FILE"]), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(libssh2_userauth_password_ex(session, "itermux_test", 12, secret, UInt32(secret.utf8.count), nil), 0)
        return (connection, fd)
    }

    func blockSends(_ connection: SSHConnection, _ gate: PendingStreamSend) -> () -> Void {
        connection.locked {
            let previous = roam_ssh_set_user(connection.session, Unmanaged.passUnretained(gate).toOpaque())
            let callback = unsafeBitCast(blockStreamSend, to: (@convention(c) () -> Void).self)
            let old = libssh2_session_callback_set2(connection.session, LIBSSH2_CALLBACK_SEND, callback)
            return { connection.locked {
                _ = libssh2_session_callback_set2(connection.session, LIBSSH2_CALLBACK_SEND, old)
                _ = roam_ssh_set_user(connection.session, previous)
            }; withExtendedLifetime(gate) {}
            }
        }
    }

    #if os(macOS)
    func testUploadDrainsAutoreleasedChunksWithinTheWorker() throws {
        let connection = try client(); defer { connection.disconnect() }
        let name = "roamtty-memory-" + UUID().uuidString
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let remote = "/tmp/" + name
        try Data().write(to: file)
        let writer = try FileHandle(forWritingTo: file)
        try writer.truncate(atOffset: 64 * 1024 * 1024); try writer.close()
        defer { try? FileManager.default.removeItem(at: file); _ = try? connection.exec("rm -f -- " + remote) }
        let ended = expectation(description: "upload finishes")
        DispatchQueue.global().async {
            // Deliberately one dispatch autorelease lifetime, matching the app worker.
            autoreleasepool {
                let before = Self.residentBytes()
                var peak = before
                do { try connection.upload(file, to: remote, progress: { _, _ in peak = max(peak, Self.residentBytes()) }) } catch { XCTFail("Upload failed: \(error)") }
                print("upload bytes=67108864 rss_growth=\(peak - before)")
                XCTAssertLessThan(peak - before, 24 * 1024 * 1024, "64 MiB upload must retain only current chunks")
            }
            ended.fulfill()
        }
        wait(for: [ended], timeout: 45)
        XCTAssertEqual(String(decoding: try connection.exec("wc -c < " + remote).output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "67108864")
    }
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }
    #endif
}
