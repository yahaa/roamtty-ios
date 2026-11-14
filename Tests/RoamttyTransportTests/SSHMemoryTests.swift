import XCTest
import CNative
import RoamttyCore
@testable import RoamttyTransport

final class SSHMemoryTests: XCTestCase {
    func client(connect: Bool = true) throws -> SSHConnection {
        guard let path = ProcessInfo.processInfo.environment["ROAMTTY_TEST_PASSWORD_FILE"] else { throw XCTSkip("Requires the dedicated live SSH fixture") }
        let secret = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let host = Host(name: "Memory fixture", address: "127.0.0.1", port: Int(ProcessInfo.processInfo.environment["ROAMTTY_TEST_PORT"] ?? "22992")!, username: "itermux_test")
        let result = SSHConnection(host: host, credentials: Credentials(password: Data(secret.utf8)), pinStore: try AppStore(url: URL(fileURLWithPath: ":memory:"))) { _ in ["trust"] }
        if connect { try result.connect() }
        return result
    }

    func testCancelledSFTPInitializationDestroysResultAfterDisconnect() throws {
        let connection = try client(); defer { connection.disconnect() }
        let counter = ShutdownSends()
        let old = connection.locked {
            let previous = roam_ssh_set_user(connection.session, Unmanaged.passUnretained(counter).toOpaque())
            let callback = unsafeBitCast(countShutdownSends, to: (@convention(c) () -> Void).self)
            return (previous, libssh2_session_callback_set2(connection.session, LIBSSH2_CALLBACK_SEND, callback))
        }
        defer { connection.locked {
            _ = libssh2_session_callback_set2(connection.session, LIBSSH2_CALLBACK_SEND, old.1)
            _ = roam_ssh_set_user(connection.session, old.0)
        } }
        var checks = 0
        XCTAssertThrowsError(try connection.openSFTP(cancelled: {
            checks += 1
            if checks == 1 { return false }
            counter.stopped = true
            connection.disconnect()
            return true
        })) { XCTAssertEqual($0 as? RoamError, .cancelled) }
        XCTAssertGreaterThan(counter.afterStop, 0, "Cancelled openSFTP must invoke native shutdown after stopped")
    }

    func testStreamNeverBuffersMoreThanFourMiBAndCloseWakesReader() throws {
        let connection = try client(); defer { connection.disconnect() }
        for _ in 0..<4 {
            let stream = try connection.openStream("head -c 67108864 /dev/zero")
            Thread.sleep(forTimeInterval: 0.7)
            XCTAssertLessThanOrEqual(stream.read(maxBytes: 128 * 1024 * 1024).count, 4 * 1024 * 1024)
            stream.close()
            let deadline = Date().addingTimeInterval(4)
            while !stream.isClosed && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertTrue(stream.isClosed)
            while !stream.read(maxBytes: 4 * 1024 * 1024).isEmpty { }
        }
        let idle = try connection.openStream("sleep 10")
        let ended = expectation(description: "close wakes blocked read")
        DispatchQueue.global().async { XCTAssertTrue(idle.read(maxBytes: 32).isEmpty); ended.fulfill() }
        idle.close()
        wait(for: [ended], timeout: 3)
    }

    func testStoppedSFTPDestructorsFreeAllNativeAllocationsWithPendingReadAndEAGAIN() throws {
        // Custom allocators count actual libssh2 allocations after the production
        // cleanup runner and connection deinit, not an allocator RSS high-water.
        for readSize in [7, 65536] {
            let allocations = NativeAllocations()
            do {
                let connection = try client(connect: false)
                let port = Int32(ProcessInfo.processInfo.environment["ROAMTTY_TEST_PORT"] ?? "22992")!
                let fd = roam_tcp_connect("127.0.0.1", port, 5000)
                XCTAssertGreaterThanOrEqual(fd, 0)
                defer { roam_socket_close(fd) }
                let session = try XCTUnwrap(libssh2_session_init_ex(nativeAlloc, nativeFree, nativeRealloc, Unmanaged.passUnretained(allocations).toOpaque()))
                connection.session = session // SSHConnection owns session destruction from here.
                libssh2_session_set_timeout(session, 5000)
                XCTAssertEqual(libssh2_session_handshake(session, fd), 0)
                let passwordPath = try XCTUnwrap(ProcessInfo.processInfo.environment["ROAMTTY_TEST_PASSWORD_FILE"])
                let secret = try String(contentsOfFile: passwordPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertEqual(libssh2_userauth_password_ex(session, "itermux_test", 12, secret, UInt32(secret.utf8.count), nil), 0)
                let sftp = try XCTUnwrap(libssh2_sftp_init(session))
                let handle = try XCTUnwrap(libssh2_sftp_open_ex(sftp, "/dev/zero", 9, UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE))
                var bytes = [UInt8](repeating: 0, count: readSize)
                XCTAssertGreaterThan(bytes.withUnsafeMutableBytes { libssh2_sftp_read(handle, $0.bindMemory(to: CChar.self).baseAddress, $0.count) }, 0)
                libssh2_session_set_blocking(session, 0)
                connection.disconnect()
                roam_socket_shutdown(fd)
                // A real callback that never accepts a send reproduces a pending
                // transport packet; stopped cleanup must not wait or spin on it.
                let callback = unsafeBitCast(blockCleanupSend, to: (@convention(c) () -> Void).self)
                let previous = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, callback)
                defer { _ = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, previous) }
                let started = Date()
                var result: Int32 = LIBSSH2_ERROR_EAGAIN
                _ = connection.settle(timeout: 0.1) { result = libssh2_sftp_close_handle(handle); return result }
                XCTAssertNotEqual(result, LIBSSH2_ERROR_EAGAIN, "Only a terminal close result consumes the native handle")
                XCTAssertTrue(connection.settle(timeout: 0.1) { libssh2_sftp_shutdown(sftp) })
                XCTAssertLessThan(Date().timeIntervalSince(started), 1)
            }
            XCTAssertEqual(allocations.blocks, 0, "Stopped close/shutdown and session destruction must free every tracked allocation")
            XCTAssertEqual(allocations.bytes, 0)
            print("native stopped teardown read=\(readSize) live_blocks=\(allocations.blocks) live_bytes=\(allocations.bytes)")
        }
    }

    func testDisconnectWakesAStreamThrottledAtTheCap() throws {
        let connection = try client()
        let stream = try connection.openStream("head -c 67108864 /dev/zero")
        Thread.sleep(forTimeInterval: 0.7)
        connection.disconnect()
        let deadline = Date().addingTimeInterval(3)
        while !stream.isClosed && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(stream.isClosed, "Connection death must wake the full-buffer condition wait")
    }

    func testStreamPendingWriteAndSFTPTeardownCanRaceDisconnect() throws {
        let connection = try client()
        let stream = try connection.openStream("cat")
        let sftp = try connection.openSFTP()
        let handle = try connection.pointer { libssh2_sftp_open_ex(sftp, "/dev/zero", 9, UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE) }
        let gate = PendingStreamSend()
        let old = connection.locked {
            let previous = roam_ssh_set_user(connection.session, Unmanaged.passUnretained(gate).toOpaque())
            let callback = unsafeBitCast(blockStreamSend, to: (@convention(c) () -> Void).self)
            return (previous, libssh2_session_callback_set2(connection.session, LIBSSH2_CALLBACK_SEND, callback))
        }
        defer { connection.locked {
            _ = libssh2_session_callback_set2(connection.session, LIBSSH2_CALLBACK_SEND, old.1)
            _ = roam_ssh_set_user(connection.session, old.0)
        } }
        try stream.write([UInt8](repeating: 42, count: 65536))
        XCTAssertEqual(gate.blocked.wait(timeout: .now() + 2), .success)
        connection.disconnect()
        let finished = expectation(description: "both native owners finish stopped teardown")
        DispatchQueue.global().async {
            _ = connection.settle(timeout: 0.2) { libssh2_sftp_close_handle(handle) }
            _ = connection.settle(timeout: 0.2) { libssh2_sftp_shutdown(sftp) }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
        let deadline = Date().addingTimeInterval(3)
        while !stream.isClosed && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(stream.isClosed)
    }

    func testPendingChannelCreationAndSFTPTeardownCanRaceDisconnect() throws {
        let connection = try client()
        let sftp = try connection.openSFTP()
        let handle = try connection.pointer { libssh2_sftp_open_ex(sftp, "/dev/zero", 9, UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE) }
        let gate = PendingStreamSend()
        let old = connection.locked {
            let previous = roam_ssh_set_user(connection.session, Unmanaged.passUnretained(gate).toOpaque())
            let callback = unsafeBitCast(blockStreamSend, to: (@convention(c) () -> Void).self)
            return (previous, libssh2_session_callback_set2(connection.session, LIBSSH2_CALLBACK_SEND, callback))
        }
        defer { connection.locked {
            _ = libssh2_session_callback_set2(connection.session, LIBSSH2_CALLBACK_SEND, old.1)
            _ = roam_ssh_set_user(connection.session, old.0)
        } }
        let creation = expectation(description: "pending channel creation unwinds")
        DispatchQueue.global().async {
            do { let stream = try connection.openStream("true"); stream.close(); XCTFail("Disconnected channel creation must throw") } catch { XCTAssertEqual(error as? RoamError, .cancelled) }
            creation.fulfill()
        }
        XCTAssertEqual(gate.blocked.wait(timeout: .now() + 2), .success)
        connection.disconnect()
        let finished = expectation(description: "SFTP teardown finishes after pending channel creation")
        DispatchQueue.global().async {
            _ = connection.settle(timeout: 0.2) { libssh2_sftp_close_handle(handle) }
            _ = connection.settle(timeout: 0.2) { libssh2_sftp_shutdown(sftp) }
            finished.fulfill()
        }
        wait(for: [creation, finished], timeout: 3)
    }

    func testPendingTerminalResizeAndSFTPTeardownCanRaceDisconnect() throws {
        let connection = try client()
        try connection.openTerminal(mode: .shell, remoteName: "", columns: 80, rows: 24)
        let sftp = try connection.openSFTP()
        let handle = try connection.pointer { libssh2_sftp_open_ex(sftp, "/dev/zero", 9, UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE) }
        let gate = PendingStreamSend()
        let old = connection.locked {
            let previous = roam_ssh_set_user(connection.session, Unmanaged.passUnretained(gate).toOpaque())
            let callback = unsafeBitCast(blockStreamSend, to: (@convention(c) () -> Void).self)
            return (previous, libssh2_session_callback_set2(connection.session, LIBSSH2_CALLBACK_SEND, callback))
        }
        defer { connection.locked {
            _ = libssh2_session_callback_set2(connection.session, LIBSSH2_CALLBACK_SEND, old.1)
            _ = roam_ssh_set_user(connection.session, old.0)
        } }
        connection.resize(columns: 100, rows: 40)
        let terminal = expectation(description: "terminal unwinds pending resize")
        DispatchQueue.global().async { _ = try? connection.runTerminal(onOutput: { _ in }); terminal.fulfill() }
        XCTAssertEqual(gate.blocked.wait(timeout: .now() + 2), .success)
        connection.disconnect()
        let finished = expectation(description: "SFTP teardown finishes after terminal resize")
        DispatchQueue.global().async {
            _ = connection.settle(timeout: 0.2) { libssh2_sftp_close_handle(handle) }
            _ = connection.settle(timeout: 0.2) { libssh2_sftp_shutdown(sftp) }
            finished.fulfill()
        }
        wait(for: [terminal, finished], timeout: 3)
    }
}

final class ShutdownSends { var stopped = false; var afterStop = 0 }
let countShutdownSends: @convention(c) (Int32, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { socket, bytes, count, flags, abstract in
    guard let value = roam_ssh_user(abstract) else { return -Int(EINVAL) }
    let counter = Unmanaged<ShutdownSends>.fromOpaque(value).takeUnretainedValue()
    if counter.stopped { counter.afterStop += 1 }
    let result = send(socket, bytes, count, flags)
    return result < 0 ? -Int(errno) : result
}

final class NativeAllocations {
    let windowBlocked = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var sizes: [UInt: Int] = [:]
    var blocks: Int { lock.lock(); defer { lock.unlock() }; return sizes.count }
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return sizes.values.reduce(0, +) }
    func allocated(_ pointer: UnsafeMutableRawPointer, size: Int) { lock.lock(); sizes[UInt(bitPattern: pointer)] = size; lock.unlock() }
    func freed(_ pointer: UnsafeMutableRawPointer) { lock.lock(); sizes.removeValue(forKey: UInt(bitPattern: pointer)); lock.unlock() }
}
func allocationTracker(_ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> NativeAllocations {
    Unmanaged<NativeAllocations>.fromOpaque(abstract!.pointee!).takeUnretainedValue()
}
let nativeAlloc: @convention(c) (Int, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer? = { size, abstract in
    let memory = malloc(max(size, 1))
    if let memory { allocationTracker(abstract).allocated(memory, size: size) }
    return memory
}
let nativeFree: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Void = { memory, abstract in
    if let memory { allocationTracker(abstract).freed(memory); free(memory) }
}
let nativeRealloc: @convention(c) (UnsafeMutableRawPointer?, Int, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeMutableRawPointer? = { memory, size, abstract in
    let next = realloc(memory, max(size, 1))
    if let next {
        let tracker = allocationTracker(abstract)
        if let memory { tracker.freed(memory) }
        tracker.allocated(next, size: size)
    }
    return next
}
let blockCleanupSend: @convention(c) (Int32, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { _, _, _, _, _ in -Int(EAGAIN) }

final class PendingStreamSend {
    let blocked = DispatchSemaphore(value: 0)
    var skipping: Int
    var onBlock: (() -> Void)?
    init(skipping: Int = 0, onBlock: (() -> Void)? = nil) { self.skipping = skipping; self.onBlock = onBlock }
}
let blockStreamSend: @convention(c) (Int32, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { socket, bytes, count, flags, abstract in
    guard let value = roam_ssh_user(abstract) else { return -Int(EINVAL) }
    let gate = Unmanaged<PendingStreamSend>.fromOpaque(value).takeUnretainedValue()
    if gate.skipping > 0 {
        gate.skipping -= 1
        let result = send(socket, bytes, count, flags)
        return result < 0 ? -Int(errno) : result
    }
    if let action = gate.onBlock { gate.onBlock = nil; action() }
    gate.blocked.signal()
    return -Int(EAGAIN)
}
let blockTrackedWindowSend: @convention(c) (Int32, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { _, _, _, _, abstract in
    allocationTracker(abstract).windowBlocked.signal()
    return -Int(EAGAIN)
}
