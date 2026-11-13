import Foundation
import CNative
import RoamttyCore

/// One-shot commands on their own exec channel.
extension SSHConnection {
    public func exec(_ command: String, timeout: TimeInterval = 20) throws -> CommandResult {
        try execute(command, input: nil, timeout: timeout, cancellation: nil, onOutput: nil)
    }

    /// Sends bytes through channel stdin, followed by EOF; input never becomes an
    /// SSH command argument. Output callbacks run on this worker outside the lock.
    /// Both input and combined stdout/stderr are limited to 8 MiB.
    public func exec(_ command: String, input: Data, timeout: TimeInterval = 20,
                     cancellation: TransferCancellation? = nil,
                     onOutput: ((Data) -> Void)? = nil) throws -> CommandResult {
        try execute(command, input: input, timeout: timeout, cancellation: cancellation, onOutput: onOutput)
    }

    /// What one command's run needs besides its channel.
    private struct ExecRun {
        let limit: Int
        let until: Date
        let cancellation: TransferCancellation?
        let onOutput: ((Data) -> Void)?
        var isCancelled: Bool { cancellation?.isCancelled == true }
    }

    private func execute(_ command: String, input: Data?, timeout: TimeInterval,
                         cancellation: TransferCancellation?, onOutput: ((Data) -> Void)?) throws -> CommandResult {
        let limit = 8 * 1024 * 1024
        guard timeout.isFinite, timeout > 0, command.utf8.count <= 256 * 1024,
              (input?.count ?? 0) <= limit else { throw RoamError.invalid("SSH command or input exceeds its limit") }
        guard !isStopped, cancellation?.isCancelled != true else { throw RoamError.cancelled }
        return try asOtherWork {
            let channel = try command.withCString { bytes in
                try openChannel(cancelled: { cancellation?.isCancelled == true }) { channel in
                    // Complete channel setup before honoring a per-command cancel;
                    // abandoning session-level EAGAIN state would affect other jobs.
                    try retry(timeout: min(timeout, 20)) { libssh2_channel_process_startup(channel, "exec", 4, bytes, UInt32(command.utf8.count)) }
                }
            }
            var completed = false
            defer { if !completed { terminateExec(channel) }; closeChannel(channel) }
            let run = ExecRun(limit: limit, until: Date().addingTimeInterval(timeout), cancellation: cancellation, onOutput: onOutput)
            let result = try pump(channel, input: input, run)
            completed = true
            return result
        }
    }

    /// Reads the command's output and feeds its input until it exits.
    private func pump(_ channel: OpaquePointer, input: Data?, _ run: ExecRun) throws -> CommandResult {
        let stdin = input ?? Data()
        return try stdin.withUnsafeBytes { inputBytes in
            var output = Data(); var buffer = [UInt8](repeating: 0, count: 32768)
            var sent = 0; var eofSent = input == nil
            while !isStopped {
                guard !run.isCancelled else { throw RoamError.cancelled }
                guard Date() < run.until else { throw RoamError.timeout }
                // Reading and writing must interleave. A command such as `cat`
                // can fill its output window before all input has been sent.
                var progressed = try readOutput(channel, into: &output, buffer: &buffer, run)
                if locked({ libssh2_channel_eof(channel) }) != 0 { return try exitResult(channel, output: output, run) }
                if sent < stdin.count {
                    let count = writeChannel(channel, 0, inputBytes.bindMemory(to: CChar.self).baseAddress!.advanced(by: sent), min(32768, stdin.count - sent))
                    if count > 0 { sent += count; progressed = true } else if count < 0 && count != LIBSSH2_ERROR_EAGAIN { throw error(Int32(count)) }
                } else if !eofSent {
                    let result = locked { libssh2_channel_send_eof(channel) }
                    if result == 0 { eofSent = true; progressed = true } else if result != LIBSSH2_ERROR_EAGAIN { throw error(result) }
                }
                if !progressed { try networkWait() }
            }
            throw RoamError.cancelled
        }
    }

    /// One read of stdout and stderr; true when either had something.
    private func readOutput(_ channel: OpaquePointer, into output: inout Data, buffer: inout [UInt8], _ run: ExecRun) throws -> Bool {
        var progressed = false
        for stream in 0...1 {
            let count = buffer.withUnsafeMutableBytes { raw in
                readChannel(channel, Int32(stream), raw.bindMemory(to: CChar.self).baseAddress, raw.count)
            }
            if count > 0 {
                guard count <= run.limit - output.count else { throw RoamError.invalid("远端响应过大 / Remote response too large") }
                let bytes = Data(buffer[0..<count])
                output.append(bytes); progressed = true
                run.onOutput?(bytes)
                guard !run.isCancelled, !isStopped else { throw RoamError.cancelled }
            } else if count < 0 && count != LIBSSH2_ERROR_EAGAIN { throw error(Int32(count)) }
        }
        return progressed
    }

    /// Output EOF can precede process exit. A short ignored wait would otherwise report libssh2's default
    /// status 0 while the command is still running and may eventually fail.
    private func exitResult(_ channel: OpaquePointer, output: Data, _ run: ExecRun) throws -> CommandResult {
        let remaining = run.until.timeIntervalSinceNow
        guard remaining > 0 else { throw RoamError.timeout }
        try retry(timeout: remaining, cancelled: { run.isCancelled }) { libssh2_channel_wait_closed(channel) }
        guard !run.isCancelled, !isStopped else { throw RoamError.cancelled }
        return CommandResult(output: output, status: locked { libssh2_channel_get_exit_status(channel) })
    }
}
