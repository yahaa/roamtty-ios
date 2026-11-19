import Foundation
import CNative
import RoamttyCore

/// The interactive terminal: one PTY channel, fed from the input queue and drained in bursts.
extension SSHConnection {
    /// The most terminal output gathered before it is handed over.
    static let burstLimit = 128 * 1024

    public func openTerminal(mode: SessionMode, remoteName: String, existing: Bool = false, columns: Int, rows: Int) throws {
        guard terminal == nil else { throw RoamError.invalid("A terminal is already open") }
        if mode == .tmux { if try exec(RemoteCommands.tmuxProbe).status != 0 { onPhase?(.tmuxMissing); throw RoamError.tmuxMissing } }
        let channel = try openChannel { channel in
            try retry { libssh2_channel_request_pty_ex(channel, "xterm-256color", 14, nil, 0, Int32(max(2, columns)), Int32(max(2, rows)), 0, 0) }
            if mode == .tmux {
                let command = RemoteCommands.tmuxAttach(remoteName, existing: existing)
                _ = try command.withCString { bytes in
                    try retry { libssh2_channel_process_startup(channel, "exec", 4, bytes, UInt32(command.utf8.count)) }
                }
            } else { try retry { libssh2_channel_process_startup(channel, "shell", 5, nil, 0) } }
        }
        stateLock.lock(); terminal = channel; acceptingInput = !stopped; stateLock.unlock()
    }

    @discardableResult public func write(_ data: Data) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !stopped && acceptingInput && input.enqueue(data) else { return false }
        wake?.signal()
        return true
    }

    public func resize(columns: Int, rows: Int) {
        stateLock.lock(); pendingSize = (max(2, columns), max(2, rows)); stateLock.unlock()
        wake?.signal()
    }

    public func runTerminal(onOutput: @escaping (Data) -> Void) throws {
        guard let channel = terminal else { throw RoamError.invalid("Terminal is not open") }
        defer {
            stateLock.lock(); acceptingInput = false; input.reset(); terminal = nil; stateLock.unlock()
            closeChannel(channel); onPhase?(.disconnected)
        }
        try asWaitingLoop(wake) { try terminalLoop(channel, onOutput: onOutput) }
    }

    private func terminalLoop(_ channel: OpaquePointer, onOutput: @escaping (Data) -> Void) throws {
        var sizing: (Int, Int)?
        var buffer = [UInt8](repeating: 0, count: 32768)
        var outgoing = Data(); var offset = 0
        var lastAlive = Date()
        // libssh2 resends the request it started after EAGAIN and ignores the size passed with the retry, so the
        // size in flight is kept apart from a newer one, which goes once it is done.
        while !isStopped {
            stateLock.lock()
            if sizing == nil { sizing = pendingSize; pendingSize = nil }
            if outgoing.isEmpty { outgoing = input.pop() ?? Data(); offset = 0 }
            stateLock.unlock()
            let resized = try sendSize(&sizing, to: channel)
            try sendInput(&outgoing, from: &offset, to: channel)
            let received = try readBurst(channel, buffer: &buffer, onOutput: onOutput)
            if locked({ libssh2_channel_eof(channel) }) != 0 { return }
            if Date().timeIntervalSince(lastAlive) > 15 {
                var seconds: Int32 = 0
                try retry(timeout: 60) { libssh2_keepalive_send(session, &seconds) }
                lastAlive = Date()
            }
            stateLock.lock(); let newerSize = resized && pendingSize != nil; stateLock.unlock()
            if !received && !newerSize { try networkWait(wake: wake) }
        }
        throw RoamError.cancelled
    }

    /// Sends the size in flight; true once the host took it (`sizing` is then nil).
    private func sendSize(_ sizing: inout (Int, Int)?, to channel: OpaquePointer) throws -> Bool {
        guard let size = sizing else { return false }
        let rc = resizeChannel(channel, Int32(size.0), Int32(size.1), 0, 0)
        if rc == 0 { sizing = nil; return true }
        if rc != LIBSSH2_ERROR_EAGAIN { throw error(rc) }
        return false
    }

    /// Writes what it can of `outgoing` from `offset`; both are reset once all of it went.
    private func sendInput(_ outgoing: inout Data, from offset: inout Int, to channel: OpaquePointer) throws {
        guard !outgoing.isEmpty else { return }
        let start = offset
        let sent = outgoing.withUnsafeBytes { raw in
            writeChannel(channel, 0, raw.bindMemory(to: CChar.self).baseAddress!.advanced(by: start), raw.count - start)
        }
        if sent > 0 {
            offset += sent
            if offset == outgoing.count { outgoing.removeAll(keepingCapacity: true); offset = 0 }
        } else if sent < 0 && sent != LIBSSH2_ERROR_EAGAIN {
            throw error(Int32(sent))
        }
    }

    /// A burst is drained up to `burstLimit` and handed over once: each hand-over waits for the main
    /// thread, so one per 8 KiB read kept it busy for as long as a large output ran. True when there was output.
    private func readBurst(_ channel: OpaquePointer, buffer: inout [UInt8], onOutput: (Data) -> Void) throws -> Bool {
        var chunk = Data()
        for stream in 0...1 {
            while chunk.count < Self.burstLimit {
                let count = buffer.withUnsafeMutableBytes { raw in
                    readChannel(channel, Int32(stream), raw.bindMemory(to: CChar.self).baseAddress, raw.count)
                }
                if count > 0 { chunk.append(contentsOf: buffer[0..<count]) } else if count < 0 && count != LIBSSH2_ERROR_EAGAIN {
                    if !chunk.isEmpty { onOutput(chunk) }
                    throw error(Int32(count))
                } else { break }
            }
        }
        if !chunk.isEmpty { onOutput(chunk) }
        return !chunk.isEmpty
    }
}
