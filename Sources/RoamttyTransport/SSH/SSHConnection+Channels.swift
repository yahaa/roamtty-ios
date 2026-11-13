import Foundation
import CNative
import RoamttyCore

/// Opening and closing channels. libssh2 keeps channel-open and SFTP-init retry state on the session, so
/// only one of them is in flight at a time.
extension SSHConnection {
    func openChannel(cancelled: () -> Bool = { false }, start: (OpaquePointer) throws -> Void) throws -> OpaquePointer {
        try withChannelCreation(cancelled: cancelled) {
            let channel = try pointer { libssh2_channel_open_ex(session, "session", 7, 2 * 1024 * 1024, 32768, nil, 0) }
            do { try start(channel); return channel } catch { closeChannel(channel); throw error }
        }
    }
    /// A direct-tcpip channel: the server connects to `host`:`port` and carries that connection. Throws
    /// `PortTunnelError.prohibited` when the server refuses to forward at all (`AllowTcpForwarding no`).
    func openDirectChannel(host: String, port: Int) throws -> OpaquePointer {
        var prohibited = false
        do {
            return try withChannelCreation {
                try pointer {
                    let channel = libssh2_channel_direct_tcpip_ex(session, host, Int32(port), "127.0.0.1", 22)
                    // Read under the library lock with the failure itself: the reason is only in libssh2's own text.
                    prohibited = channel == nil && Self.lastErrorIsProhibited(session)
                    return channel
                }
            }
        } catch {
            if prohibited { throw PortTunnelError.prohibited }
            throw error
        }
    }
    /// libssh2 reports every refused channel as `LIBSSH2_ERROR_CHANNEL_FAILURE`; the reason it gives in its own,
    /// fixed message tells "administratively prohibited" from "connect failed".
    static func lastErrorIsProhibited(_ session: OpaquePointer?) -> Bool {
        guard let session else { return false }
        var message: UnsafeMutablePointer<CChar>?
        guard libssh2_session_last_error(session, &message, nil, 0) == LIBSSH2_ERROR_CHANNEL_FAILURE, let message else { return false }
        return strstr(message, "prohibited") != nil
    }
    func openSFTP(cancelled: () -> Bool = { false }) throws -> OpaquePointer {
        try withChannelCreation(cancelled: cancelled) {
            // A second init cannot start while the first remains in EAGAIN.
            // Finish the shared init sequence, then dispose a cancelled result.
            let sftp = try pointer { libssh2_sftp_init(session) }
            if isStopped || cancelled() {
                settle(timeout: 10) { libssh2_sftp_shutdown(sftp) }
                throw RoamError.cancelled
            }
            return sftp
        }
    }
    func withChannelCreation<T>(cancelled: () -> Bool = { false }, _ action: () throws -> T) throws -> T {
        try asOtherWork { try createChannel(cancelled: cancelled, action) }
    }
    func createChannel<T>(cancelled: () -> Bool, _ action: () throws -> T) throws -> T {
        creationCondition.lock()
        while creatingChannel {
            if isStopped || cancelled() {
                creationCondition.unlock(); throw RoamError.cancelled
            }
            _ = creationCondition.wait(until: Date().addingTimeInterval(0.03))
        }
        guard !isStopped, !cancelled() else {
            creationCondition.unlock(); throw RoamError.cancelled
        }
        guard isConnected else {
            creationCondition.unlock(); throw RoamError.transport("SSH connection is not authenticated")
        }
        creatingChannel = true
        creationCondition.unlock()
        defer {
            creationCondition.lock(); creatingChannel = false; creationCondition.broadcast(); creationCondition.unlock()
        }
        do { return try action() } catch {
            // A timed-out init still owns libssh2's pending session state; a new
            // connection is required before another independent init can start.
            if error as? RoamError == .timeout { disconnect() }
            throw error
        }
    }
    func closeChannel(_ channel: OpaquePointer) {
        asOtherWork {
            settle(timeout: 2) { libssh2_channel_close(channel) }
            settle(timeout: 2) {
                let result = libssh2_channel_free(channel)
                if result != LIBSSH2_ERROR_EAGAIN { pendingChannelIO.removeValue(forKey: channel) }
                return result
            }
        }
    }
    /// Closing a pipe-backed exec channel does not stop its remote process.
    /// Signal this channel's process group first, leaving other exec/PTY/SFTP
    /// channels and the cached connection intact. TERM gives sudo time to relay
    /// the signal to its privileged command before any bounded escalation.
    /// This is best effort on servers that ignore SSH signals. Detached or
    /// differently privileged descendants need their own command's cleanup;
    /// there is deliberately no host-wide PID/group scan or extra sudo request.
    func terminateExec(_ channel: OpaquePointer) {
        guard !isStopped else { return }
        let deadline = Date().addingTimeInterval(3)
        // libssh2 retains the signal packet across EAGAIN and ignores a new
        // signame until that packet completes. Finish TERM before starting a
        // distinct KILL, reserving the final half-second for escalation.
        let escalation = deadline.addingTimeInterval(-0.5)
        guard sendExecSignal(channel, name: "TERM", until: escalation) else { return }
        if drainTerminatedExec(channel, until: min(escalation, Date().addingTimeInterval(2))) { return }
        guard !isStopped, Date() < deadline else { return }
        guard sendExecSignal(channel, name: "KILL", until: deadline) else { return }
        _ = drainTerminatedExec(channel, until: deadline)
    }
    func sendExecSignal(_ channel: OpaquePointer, name: String, until deadline: Date) -> Bool {
        do {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw RoamError.timeout }
            _ = try retry(timeout: remaining) { libssh2_channel_signal_ex(channel, name, name.utf8.count) }
            return true
        } catch {
            // An unfinished signal (or an earlier pending write that prevents
            // its send) occupies the session's shared transport slot. Closing
            // just this channel would leave every future channel stuck behind
            // that packet. Mark the connection unusable before normal cleanup.
            disconnect()
            return false
        }
    }
    func drainTerminatedExec(_ channel: OpaquePointer, until deadline: Date) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while !isStopped, Date() < deadline {
            for stream in 0...1 {
                let count = buffer.withUnsafeMutableBytes { raw in
                    readChannel(channel, Int32(stream), raw.bindMemory(to: CChar.self).baseAddress, raw.count)
                }
                if count < 0 && count != LIBSSH2_ERROR_EAGAIN { return false }
            }
            if locked({ libssh2_channel_eof(channel) }) != 0 {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return false }
                return (try? retry(timeout: remaining) { libssh2_channel_wait_closed(channel) }) != nil
            }
            do { try networkWait() } catch { return false }
        }
        return false
    }
}
