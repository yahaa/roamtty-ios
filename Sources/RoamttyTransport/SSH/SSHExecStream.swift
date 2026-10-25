import Foundation
import CNative
import RoamttyCore
import RoamttyDesktopCore

/// One exec channel kept open for a long-running command whose stdin and stdout carry a binary protocol:
/// the remote desktop's `roamtty-desktop serve` (Android `RemoteStream`, roamtty #218). A pump thread
/// moves bytes under the connection's library lock; `read` blocks the caller until bytes come or the
/// command's output ends. Closing drops the channel only, as Android does: the plugin sees its stdin end
/// and keeps the desktop for a resume.
public final class SSHExecStream: DesktopStream, @unchecked Sendable {
    private let connection: SSHConnection
    private let channel: OpaquePointer
    private let cond = NSCondition()
    private var incoming: [UInt8] = []
    private var outgoing: [UInt8] = []
    private var errors: [UInt8] = []
    private var finished = false
    private var closeRequested = false
    private var status: Int?
    private let wake = WorkerWake()
    private static let maxErrors = 16 * 1024
    private static let maxIncoming = 4 * 1024 * 1024

    init(connection: SSHConnection, channel: OpaquePointer) {
        self.connection = connection; self.channel = channel
        let t = Thread { [self] in pump() }
        t.name = "roamtty.ssh.stream"
        t.start()
    }

    public func read(maxBytes: Int) -> [UInt8] {
        cond.lock(); defer { cond.unlock() }
        while incoming.isEmpty && !finished && !closeRequested { cond.wait() }
        if incoming.isEmpty { return [] }
        let n = min(maxBytes, incoming.count)
        let out = Array(incoming[0..<n])
        incoming.removeFirst(n)
        cond.broadcast()
        return out
    }

    public func write(_ bytes: [UInt8]) throws {
        cond.lock()
        guard !finished && !closeRequested else { cond.unlock(); throw RoamError.transport("Stream closed") }
        outgoing.append(contentsOf: bytes)
        cond.unlock()
        wake?.signal()
    }

    public var errorOutput: String { cond.lock(); defer { cond.unlock() }; return String(decoding: errors, as: UTF8.self) }
    public var isClosed: Bool { cond.lock(); defer { cond.unlock() }; return finished }
    public var exitStatus: Int? { cond.lock(); defer { cond.unlock() }; return status }

    public func close() {
        cond.lock(); closeRequested = true; cond.broadcast(); cond.unlock()
        wake?.signal()
    }

    private func pump() {
        var buffer = [UInt8](repeating: 0, count: 32768)
        var lastAlive = Date()
        var exit: Int?
        defer {
            connection.closeChannel(channel)
            cond.lock(); finished = true; status = exit; cond.broadcast(); cond.unlock()
        }
        do {
            while !connection.isStopped {
                cond.lock()
                // Hold back while the reader is far behind (libssh2's window then throttles the host).
                while incoming.count >= Self.maxIncoming && !closeRequested && !connection.isStopped {
                    _ = cond.wait(until: Date().addingTimeInterval(0.03))
                }
                let stop = closeRequested || connection.isStopped
                let pending = outgoing
                cond.unlock()
                if stop { return }
                var progressed = false
                if !pending.isEmpty {
                    let sent = pending.withUnsafeBytes { raw in connection.locked {
                        libssh2_channel_write_ex(channel, 0, raw.bindMemory(to: CChar.self).baseAddress, pending.count)
                    } }
                    if sent > 0 {
                        cond.lock(); outgoing.removeFirst(sent); cond.unlock()
                        progressed = true
                    } else if sent < 0 && sent != LIBSSH2_ERROR_EAGAIN { throw connection.error(Int32(sent)) }
                }
                for stream in 0...1 {
                    while true {
                        cond.lock()
                        let stop = closeRequested || connection.isStopped
                        let available = stream == 0 ? Self.maxIncoming - incoming.count : buffer.count
                        cond.unlock()
                        if stop { return }
                        let want = min(buffer.count, available)
                        if want == 0 { break }
                        let count = buffer.withUnsafeMutableBytes { raw in
                            connection.locked { libssh2_channel_read_ex(channel, Int32(stream), raw.bindMemory(to: CChar.self).baseAddress, want) }
                        }
                        if count > 0 {
                            cond.lock()
                            if stream == 0 { incoming.append(contentsOf: buffer[0..<count]) }
                            else { errors.append(contentsOf: buffer[0..<count]); if errors.count > Self.maxErrors { errors.removeFirst(errors.count - Self.maxErrors) } }
                            cond.broadcast(); cond.unlock()
                            progressed = true
                            if stream == 0 && count == buffer.count { continue }
                        } else if count < 0 && count != LIBSSH2_ERROR_EAGAIN { throw connection.error(Int32(count)) }
                        break
                    }
                }
                if connection.locked({ libssh2_channel_eof(channel) }) != 0 {
                    // The exit status comes with the channel's close; bounded, like exec.
                    _ = try? connection.retry(timeout: 5, cancelled: { self.closeWanted }) { libssh2_channel_wait_closed(channel) }
                    exit = Int(connection.locked { libssh2_channel_get_exit_status(channel) })
                    return
                }
                if Date().timeIntervalSince(lastAlive) > 15 {
                    var seconds: Int32 = 0
                    try connection.retry(timeout: 60) { libssh2_keepalive_send(connection.session, &seconds) }
                    lastAlive = Date()
                }
                if !progressed { try connection.networkWait(wake: wake) }
            }
        } catch {
            return
        }
    }

    private var closeWanted: Bool { cond.lock(); defer { cond.unlock() }; return closeRequested }
}

extension SSHConnection {
    /// Starts `command` on a new exec channel and keeps it open (see `SSHExecStream`).
    public func openStream(_ command: String) throws -> SSHExecStream {
        guard command.utf8.count <= 256 * 1024 else { throw RoamError.invalid("SSH command exceeds its limit") }
        let channel = try command.withCString { bytes in
            try openChannel { channel in
                try retry { libssh2_channel_process_startup(channel, "exec", 4, bytes, UInt32(command.utf8.count)) }
            }
        }
        return SSHExecStream(connection: self, channel: channel)
    }
}

/// The remote desktop's view of an SSH login (`DesktopHost`), on the existing exec and SFTP code.
public final class SSHDesktopHost: DesktopHost, @unchecked Sendable {
    public let connection: SSHConnection

    public init(connection: SSHConnection) { self.connection = connection }

    public func run(_ script: String, timeout: TimeInterval, onLine: @escaping (String) -> Void) -> Int? {
        execute("/bin/sh -s", input: Data(script.utf8), timeout: timeout, onLine: onLine)
    }

    public func runCommand(_ command: String, timeout: TimeInterval, onLine: @escaping (String) -> Void) -> Int? {
        execute(command, input: Data(), timeout: timeout, onLine: onLine)
    }

    private func execute(_ command: String, input: Data, timeout: TimeInterval, onLine: @escaping (String) -> Void) -> Int? {
        var pending = Data()
        func flush(all: Bool) {
            while let nl = pending.firstIndex(of: 0x0A) {
                var line = pending[pending.startIndex..<nl]
                if line.last == 0x0D { line = line.dropLast() }
                onLine(String(decoding: line, as: UTF8.self))
                pending = Data(pending[(nl + 1)...])
            }
            if all && !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
        }
        do {
            let result = try connection.exec(command, input: input, timeout: timeout) { chunk in pending.append(chunk); flush(all: false) }
            flush(all: true)
            return Int(result.status)
        } catch {
            flush(all: true)
            return nil
        }
    }

    public func upload(_ data: Data, to path: String) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("roamtty-desktop-\(UUID().uuidString)")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try connection.upload(file, to: path, progress: { _, _ in })
    }

    public func openStream(_ command: String) -> DesktopStream? { try? connection.openStream(command) }

    public func disconnect() { connection.disconnect() }
}
