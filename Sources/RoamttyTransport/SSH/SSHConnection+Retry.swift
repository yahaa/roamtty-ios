import Foundation
import CNative
import RoamttyCore

/// libssh2 is non-blocking here: a call that returns EAGAIN is repeated, with the same arguments, once the
/// socket is ready. These helpers do that, and finish what libssh2 retained when the connection stops.
extension SSHConnection {
    @discardableResult
    func retry(timeout: TimeInterval = 20, cancelled: () -> Bool = { false }, _ operation: () -> Int32) throws -> Int32 {
        let until = Date().addingTimeInterval(timeout)
        var pending = false
        while true {
            if isStopped {
                // Finish only an operation already retained by libssh2. The
                // caller still receives cancellation, never business success.
                if pending { settle(timeout: 0, operation) }
                throw RoamError.cancelled
            }
            guard !cancelled() else { throw RoamError.cancelled }
            let value = locked(operation)
            pending = value == LIBSSH2_ERROR_EAGAIN
            if !pending {
                guard value >= 0 else { throw error(value) }
                return value
            }
            guard Date() < until else {
                disconnect(); settle(timeout: 0, operation)
                throw RoamError.timeout
            }
            do { try networkWait() } catch {
                if isStopped { settle(timeout: 0, operation) }
                throw error
            }
        }
    }
    /// Keep the exact retry arguments until the raw native operation completes.
    /// Recording and stopped replay use the same library lock as ordinary I/O.
    func readChannel(_ channel: OpaquePointer, _ stream: Int32, _ bytes: UnsafeMutablePointer<CChar>?, _ count: Int) -> Int {
        locked {
            let result = libssh2_channel_read_ex(channel, stream, bytes, count)
            var pending = pendingChannelIO[channel] ?? PendingChannelIO()
            if result == LIBSSH2_ERROR_EAGAIN { pending.read = pending.read ?? (stream, count) } else { pending.read = nil }
            storePending(pending, channel: channel)
            return result
        }
    }
    func writeChannel(_ channel: OpaquePointer, _ stream: Int32, _ bytes: UnsafePointer<CChar>?, _ count: Int) -> Int {
        locked {
            let result = libssh2_channel_write_ex(channel, stream, bytes, count)
            var pending = pendingChannelIO[channel] ?? PendingChannelIO()
            if result == LIBSSH2_ERROR_EAGAIN, pending.write == nil {
                // libssh2 writes at most 32700 bytes, even for a larger input.
                // Own only this in-flight chunk; the caller's buffer may expire.
                pending.write = (stream, bytes.map { Data(bytes: $0, count: min(count, 32768)) } ?? Data())
            } else if result != LIBSSH2_ERROR_EAGAIN { pending.write = nil }
            storePending(pending, channel: channel)
            return result
        }
    }
    func resizeChannel(_ channel: OpaquePointer, _ columns: Int32, _ rows: Int32, _ width: Int32, _ height: Int32) -> Int32 {
        locked {
            let result = libssh2_channel_request_pty_size_ex(channel, columns, rows, width, height)
            var pending = pendingChannelIO[channel] ?? PendingChannelIO()
            if result == LIBSSH2_ERROR_EAGAIN { pending.resize = pending.resize ?? (columns, rows, width, height) } else { pending.resize = nil }
            storePending(pending, channel: channel)
            return result
        }
    }
    func storePending(_ pending: PendingChannelIO, channel: OpaquePointer) {
        if pending.isEmpty { pendingChannelIO.removeValue(forKey: channel) } else { pendingChannelIO[channel] = pending }
    }
    /// One bounded pass, under stopped disposal callbacks and libraryLock.
    /// Never wait for one candidate: its packet can belong to another candidate
    /// on this very worker. Whichever owns the native slot can finish this pass;
    /// the remaining candidates finish on the next pass.
    func unwindPendingChannelIO() {
        var scratch = [CChar](repeating: 0, count: 32768)
        for (channel, var pending) in pendingChannelIO {
            if let read = pending.read {
                let result = libssh2_channel_read_ex(channel, read.stream, &scratch, min(read.count, scratch.count))
                if result != LIBSSH2_ERROR_EAGAIN { pending.read = nil }
            }
            if let write = pending.write {
                let result = write.bytes.withUnsafeBytes { libssh2_channel_write_ex(channel, write.stream, $0.bindMemory(to: CChar.self).baseAddress, $0.count) }
                if result != LIBSSH2_ERROR_EAGAIN { pending.write = nil }
            }
            if let size = pending.resize {
                let result = libssh2_channel_request_pty_size_ex(channel, size.columns, size.rows, size.width, size.height)
                if result != LIBSSH2_ERROR_EAGAIN { pending.resize = nil }
            }
            storePending(pending, channel: channel)
        }
    }
    /// Destructors and already-started requests retain native state through EAGAIN.
    /// Cancellation must finish that local state before its owner releases the resource.
    @discardableResult
    func settle(timeout: TimeInterval, _ operation: () -> Int32) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var abortIO = false
        while true {
            let result = locked {
                guard abortIO, isStopped, let session else { return operation() }
                // A pending packet can keep returning EAGAIN even after socket shutdown
                // (including custom socket callbacks). Fail its I/O while holding the
                // library lock so libssh2 can finish local destruction without a wait.
                let sendCallback = unsafeBitCast(stoppedCleanupSend, to: (@convention(c) () -> Void).self)
                let recvCallback = unsafeBitCast(stoppedCleanupReceive, to: (@convention(c) () -> Void).self)
                let send = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, sendCallback)
                let recv = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, recvCallback)
                defer {
                    _ = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, send)
                    _ = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, recv)
                }
                unwindPendingChannelIO()
                return operation()
            }
            if result != LIBSSH2_ERROR_EAGAIN {
                if result < 0 { _ = error(result) }
                return result >= 0
            }
            if isStopped {
                // Give every raw owner one disposal attempt before yielding to
                // another worker's in-flight retry/pointer operation.
                if abortIO { Thread.sleep(forTimeInterval: 0.001) }
                abortIO = true
                continue
            }
            if Date() >= deadline { disconnect(); abortIO = true; continue }
            do { try networkWait() } catch { disconnect(); abortIO = true }
        }
    }
    func pointer(timeout: TimeInterval = 20, cancelled: () -> Bool = { false }, _ operation: () -> OpaquePointer?) throws -> OpaquePointer {
        let until = Date().addingTimeInterval(timeout)
        var pending = false
        func finishStoppedRequest() -> OpaquePointer? {
            var pointer: OpaquePointer?
            settle(timeout: 0) {
                pointer = operation()
                return pointer == nil ? libssh2_session_last_errno(session) : 0
            }
            return pointer
        }
        while true {
            if isStopped {
                // A buffered successful result must reach its owning caller's
                // defer, even if disconnect won the race with native init/open.
                if pending, let pointer = finishStoppedRequest() { return pointer }
                throw RoamError.cancelled
            }
            guard !cancelled() else { throw RoamError.cancelled }
            let result: (OpaquePointer?, Int32) = locked { let p = operation(); return (p, p == nil ? libssh2_session_last_errno(session) : 0) }
            if let p = result.0 { return p }
            pending = result.1 == LIBSSH2_ERROR_EAGAIN
            guard pending else { throw error(result.1) }
            guard Date() < until else {
                disconnect()
                // Return a successful native open to its owner for disposal;
                // otherwise preserve the timeout that invalidated the session.
                if let pointer = finishStoppedRequest() { return pointer }
                throw RoamError.timeout
            }
            do { try networkWait() } catch {
                if isStopped, let pointer = finishStoppedRequest() { return pointer }
                throw error
            }
        }
    }
}

// libssh2 socket callbacks return negative errno, rather than setting errno.
private let stoppedCleanupReceive: @convention(c) (Int32, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { _, _, _, _, _ in -Int(ENOTCONN) }

// Discard output only after socket shutdown. Reporting a complete send lets
// libssh2 clear its retained packet slot before its final receive fails.
private let stoppedCleanupSend: @convention(c) (Int32, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { _, _, count, _, _ in count }
