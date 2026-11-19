import Foundation
import RoamttyCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// One mosh session. Call `run` once on a dedicated worker; other methods are
/// thread-safe. Output is delivered on that worker. No pending input escapes this
/// instance when it stops, so a caller may safely create a separate SSH fallback.
public final class MoshTransport {
    private let host: String
    private let port: Int
    private let crypto: Mosh.Crypto
    private let lock = NSLock()
    private var started = false
    private var closed = false
    private var pendingKeys = [Data]()
    private var pendingSize: (columns: Int, rows: Int)?
    private var probeRequested = false
    // Budgets include both queued and already-sent, unacknowledged input. `outstandingWrites` counts key events: the
    // writes the worker takes in one turn go out as one.
    private var outstandingBytes = 0
    private var outstandingWrites = 0
    /// Key events awaiting the server's ack. The worker can take each write of a burst in its own turn, and every
    /// unacknowledged event is resent until acked, so this bounds the resend while leaving room for a revision of
    /// hundreds of characters within one round trip; the byte budget bounds the size.
    static let eventBudget = 1024
    /// Wakes the worker's poll as soon as input arrives, instead of after its timeout.
    private let wake: WorkerWake

    public init(host: String, port: Int, key: String) throws {
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              (1...65535).contains(port) else { throw RoamError.invalid("Invalid mosh endpoint") }
        self.host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        self.port = port
        self.crypto = try Mosh.Crypto(key: key)
        guard let wake = WorkerWake() else { throw RoamError.transport("Cannot create mosh wake pipe") }
        self.wake = wake
    }

    /// Blocks until remote shutdown, cancellation, or a fallback-worthy error.
    /// Plain shells can set `stallTimeout` to nil to wait through network outages.
    /// The default silence limit is one minute below a 15-minute server timeout. `log` hears why it gave up.
    public func run(columns: Int, rows: Int, firstContactTimeout: TimeInterval = 8,
                    silenceTimeout: TimeInterval = 14 * 60, stallTimeout: TimeInterval? = 10,
                    log: @escaping (String) -> Void = { _ in },
                    onOutput: @escaping (Data) -> Void) throws {
        guard firstContactTimeout.isFinite, firstContactTimeout > 0,
              silenceTimeout.isFinite, silenceTimeout > 0,
              stallTimeout == nil || (stallTimeout!.isFinite && stallTimeout! > 0) else {
            throw RoamError.invalid("Invalid mosh timeout")
        }
        let limits = MoshLink.Timeouts(firstContact: firstContactTimeout, silence: silenceTimeout, stall: stallTimeout)
        try begin()
        defer { finish() }
        let link = try MoshLink(host: host, port: port, crypto: crypto)
        link.state.enqueue(.resize(columns: columns, rows: rows), at: moshNow())
        var shutdownByServer = false
        defer {
            if !shutdownByServer {
                for _ in 0..<2 { try? link.send(moshNow(), shutdown: true) }
            }
            link.state.clear()
        }
        var lastTurn = moshNow()
        while true {
            let pending = drain(allowResize: link.state.pendingEventCount < 192)
            if pending.closed { throw RoamError.cancelled }
            let now = moshNow()
            link.enqueue(size: pending.size, keys: pending.keys, at: now)
            // A turn takes at most a one-second wait plus delivering output, so a long gap means iOS froze the worker.
            let frozen = now - lastTurn
            let thawed = frozen > 5
            lastTurn = now
            if thawed {
                log(String(format: "mosh resumed after %.1fs frozen", frozen))
                link.state.thawed(at: now)
            }
            if let reason = link.state.timeoutReason(at: now, firstContact: limits.firstContact, silence: limits.silence, stall: limits.stall) {
                log("mosh timeout: " + reason)
                throw RoamError.timeout
            }
            // Thawing probes like a wake: the old source port's NAT mapping may be gone.
            try link.keepReachable(probe: pending.probe || thawed, at: now)
            if link.state.nextSendAt(now) <= now { try link.send(now) }
            if try receiveBurst(link, limits, onOutput: onOutput) {
                shutdownByServer = true
                for _ in 0..<3 { try link.send(moshNow(), shutdown: true) }
                return
            }
        }
    }

    /// Waits for the server and handles what it sent; true once the server shut the session down.
    private func receiveBurst(_ link: MoshLink, _ limits: MoshLink.Timeouts, onOutput: (Data) -> Void) throws -> Bool {
        // The wait ends at the next send or timeout, and at most a second on: new input, a resize, a probe or a
        // close wake it at once, so an idle session does not spin. The worker alone closes the descriptor.
        let waitStart = moshNow()
        let deadline = min(link.state.nextSendAt(waitStart),
                           link.state.nextTimeoutAt(firstContact: limits.firstContact, silence: limits.silence, stall: limits.stall) + 0.001)
        let delay = max(0, min(Self.idleWait, deadline - waitStart))
        guard var packet = link.socket.receive(wait: delay, wake: wake) else { return false }
        // A burst is read in one turn instead of one datagram per pass through the whole loop.
        var read = 1
        while true {
            if let accepted = try link.handle(packet) {
                release(bytes: accepted.releasedBytes, writes: accepted.releasedWrites)
                for output in accepted.output { onOutput(output) }
                if accepted.serverShutdown { return true }
            }
            guard read < Self.burstPackets, let next = link.socket.receiveReady() else { return false }
            packet = next; read += 1
        }
    }

    /// The longest network wait of an idle session.
    static let idleWait: TimeInterval = 1
    /// Datagrams read in one turn before the loop sends, checks timeouts and takes input again.
    static let burstPackets = 64

    /// False means the caller must retain or reject the input; it was not queued.
    @discardableResult
    public func write(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        if data.isEmpty { return true }
        // Writes the worker has not taken yet join the event already waiting, so a burst costs one event: dictation
        // revises its text with one write per deleted character (issue #108).
        let newEvent = pendingKeys.isEmpty
        guard data.count <= 256 * 1024, !newEvent || outstandingWrites < Self.eventBudget,
              data.count <= 1024 * 1024 - outstandingBytes else { return false }
        pendingKeys.append(data)
        outstandingBytes += data.count
        if newEvent { outstandingWrites += 1 }
        wake.signal()
        return true
    }

    public func resize(columns: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        pendingSize = (max(1, min(columns, 65535)), max(1, min(rows, 65535)))
        wake.signal()
    }

    /// Call after wake or a network-path change. A fresh UDP source port avoids
    /// stale NAT mappings, and a missing reply starts the stall fallback timer.
    public func probe() {
        lock.lock(); defer { lock.unlock() }
        if !closed { probeRequested = true; wake.signal() }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        clearPending()
        wake.signal()
    }

    private func begin() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw RoamError.cancelled }
        guard !started else { throw RoamError.invalid("Mosh transport already started") }
        started = true
    }

    private func finish() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        clearPending()
    }

    private func clearPending() {
        for index in pendingKeys.indices { pendingKeys[index].resetBytes(in: 0..<pendingKeys[index].count) }
        pendingKeys.removeAll()
        pendingSize = nil
        probeRequested = false
        outstandingBytes = 0
        outstandingWrites = 0
    }

    private func drain(allowResize: Bool) -> (closed: Bool, keys: [Data], size: (columns: Int, rows: Int)?, probe: Bool) {
        lock.lock(); defer { lock.unlock() }
        let result = (closed, pendingKeys, allowResize ? pendingSize : nil, probeRequested)
        pendingKeys.removeAll(keepingCapacity: true)
        if allowResize { pendingSize = nil }
        probeRequested = false
        return result
    }

    private func release(bytes: Int, writes: Int) {
        lock.lock(); defer { lock.unlock() }
        outstandingBytes = max(0, outstandingBytes - bytes)
        outstandingWrites = max(0, outstandingWrites - writes)
    }
}

/// What the worker alone touches while a session runs: the socket, the protocol state and the datagrams
/// being put together.
private final class MoshLink {
    struct Timeouts {
        let firstContact: TimeInterval
        let silence: TimeInterval
        let stall: TimeInterval?
    }

    private let crypto: Mosh.Crypto
    private(set) var socket: MoshDatagram
    var state = MoshState(start: moshNow())
    private var assembly = Mosh.Assembly()
    private var instructionID: UInt64 = 0
    private var lastHop = moshNow()

    init(host: String, port: Int, crypto: Mosh.Crypto) throws {
        self.crypto = crypto
        socket = try MoshDatagram.connect(host: host, port: port)
    }

    func send(_ now: TimeInterval, shutdown: Bool = false) throws {
        let instruction = try state.instruction(at: now, shutdown: shutdown)
        let compressed = try Mosh.compress(instruction.encode())
        let fragments = try Mosh.fragments(id: instructionID, payload: compressed, maxPayload: 400)
        instructionID &+= 1
        for fragment in fragments {
            let timestamp = MoshState.timestamp(now)
            let reply = state.timestampReply(at: now)
            let header = Data([UInt8(timestamp >> 8), UInt8(truncatingIfNeeded: timestamp),
                               UInt8(reply >> 8), UInt8(truncatingIfNeeded: reply)])
            let packet = try crypto.seal(header + fragment)
            // A missing route while roaming is not fatal. SSP retries until
            // the configured liveness policy decides to fall back.
            socket.send(packet)
        }
    }

    /// One datagram from the server: what it carried, nil when it was not ours or its instruction is incomplete.
    func handle(_ packet: Data) throws -> MoshState.Accepted? {
        guard let plain = crypto.open(packet), plain.count >= 14 else { return nil }
        let base = plain.startIndex
        let timestamp = UInt16(plain[base]) << 8 | UInt16(plain[base + 1])
        let reply = UInt16(plain[base + 2]) << 8 | UInt16(plain[base + 3])
        let receivedAt = moshNow()
        let packetSequence = Mosh.readBigEndian(packet.prefix(8)) & 0x7fff_ffff_ffff_ffff
        state.heard(at: receivedAt, timestamp: timestamp, reply: reply, sequence: packetSequence)
        guard let payload = assembly.add(plain.dropFirst(4)) else { return nil }
        let instruction = try Mosh.Instruction.decode(Mosh.decompress(payload))
        return try state.receive(instruction, at: receivedAt)
    }

    /// Queues what was written and resized since the last turn.
    func enqueue(size: (columns: Int, rows: Int)?, keys: [Data], at now: TimeInterval) {
        // Size precedes keys in this batch, so `stty size` immediately after
        // a view resize observes the new terminal dimensions.
        if let size { state.enqueue(.resize(columns: size.columns, rows: size.rows), at: now) }
        // Everything written since the last turn is one event, as the budget in `write` counts it.
        guard !keys.isEmpty else { return }
        var bytes = Data(capacity: keys.reduce(0) { $0 + $1.count })
        for var piece in keys {
            bytes.append(piece)
            piece.resetBytes(in: 0..<piece.count)
        }
        state.enqueue(.keys(bytes), at: now)
        bytes.resetBytes(in: 0..<bytes.count)
    }

    /// A probe, or ten quiet seconds, moves to a fresh UDP source port: the old one's NAT mapping may be gone.
    func keepReachable(probe: Bool, at now: TimeInterval) throws {
        if probe, state.heardAny {
            state.requestProbe(at: now)
            hop(at: now)
            try send(now)
        } else if state.heardAny, now - state.lastHeard > 10, now - lastHop > 10 {
            hop(at: now)
        }
    }

    private func hop(at now: TimeInterval) {
        if let replacement = try? MoshDatagram(endpoint: socket.endpoint) { socket = replacement }
        lastHop = now
    }
}
