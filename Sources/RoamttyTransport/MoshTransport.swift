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
    // Budgets include both queued and already-sent, unacknowledged input.
    private var outstandingBytes = 0
    private var outstandingWrites = 0

    public init(host: String, port: Int, key: String) throws {
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              (1...65535).contains(port) else { throw RoamError.invalid("Invalid mosh endpoint") }
        self.host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        self.port = port
        self.crypto = try Mosh.Crypto(key: key)
    }

    /// Blocks until remote shutdown, cancellation, or a fallback-worthy error.
    /// Plain shells can set `stallTimeout` to nil to wait through network outages.
    /// The default silence limit is one minute below a 15-minute server timeout.
    public func run(columns: Int, rows: Int, firstContactTimeout: TimeInterval = 8,
                    silenceTimeout: TimeInterval = 14 * 60, stallTimeout: TimeInterval? = 10,
                    onOutput: @escaping (Data) -> Void) throws {
        guard firstContactTimeout.isFinite, firstContactTimeout > 0,
              silenceTimeout.isFinite, silenceTimeout > 0,
              stallTimeout == nil || (stallTimeout!.isFinite && stallTimeout! > 0) else {
            throw RoamError.invalid("Invalid mosh timeout")
        }
        try begin()
        defer { finish() }
        var socket = try MoshDatagram.connect(host: host, port: port)
        var state = MoshState(start: moshNow())
        var assembly = Mosh.Assembly()
        var instructionID: UInt64 = 0
        var lastHop = moshNow()
        var shutdownByServer = false
        state.enqueue(.resize(columns: columns, rows: rows), at: moshNow())

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

        defer {
            if !shutdownByServer {
                for _ in 0..<2 { try? send(moshNow(), shutdown: true) }
            }
            state.clear()
        }

        while true {
            let pending = drain(allowResize: state.pendingEventCount < 192)
            if pending.closed { throw RoamError.cancelled }
            let now = moshNow()
            // Size precedes keys in this batch, so `stty size` immediately after
            // a view resize observes the new terminal dimensions.
            if let size = pending.size { state.enqueue(.resize(columns: size.columns, rows: size.rows), at: now) }
            for var bytes in pending.keys {
                state.enqueue(.keys(bytes), at: now)
                bytes.resetBytes(in: 0..<bytes.count)
            }
            try state.checkTimeout(at: now, firstContact: firstContactTimeout, silence: silenceTimeout, stall: stallTimeout)
            if pending.probe, state.heardAny {
                state.requestProbe(at: now)
                if let replacement = try? MoshDatagram(endpoint: socket.endpoint) { socket = replacement }
                lastHop = now
                try send(now)
            } else if state.heardAny, now - state.lastHeard > 10, now - lastHop > 10 {
                if let replacement = try? MoshDatagram(endpoint: socket.endpoint) { socket = replacement }
                lastHop = now
            }
            if state.nextSendAt(now) <= now { try send(now) }

            // A short poll bounds cancellation and newly typed-input latency,
            // and avoids closing a descriptor from a competing thread.
            let delay = max(0, min(0.05, state.nextSendAt(moshNow()) - moshNow()))
            guard let packet = socket.receive(wait: delay), let plain = crypto.open(packet), plain.count >= 14 else { continue }
            let bytes = Array(plain)
            let timestamp = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            let reply = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
            let receivedAt = moshNow()
            let packetSequence = Mosh.readBigEndian(packet.prefix(8)) & 0x7fff_ffff_ffff_ffff
            state.heard(at: receivedAt, timestamp: timestamp, reply: reply, sequence: packetSequence)
            guard let payload = assembly.add(Data(bytes.dropFirst(4))) else { continue }
            let instruction = try Mosh.Instruction.decode(Mosh.decompress(payload))
            let accepted = try state.receive(instruction, at: receivedAt)
            release(bytes: accepted.releasedBytes, writes: accepted.releasedWrites)
            for output in accepted.output { onOutput(output) }
            if accepted.serverShutdown {
                shutdownByServer = true
                for _ in 0..<3 { try send(moshNow(), shutdown: true) }
                return
            }
        }
    }

    /// False means the caller must retain or reject the input; it was not queued.
    @discardableResult
    public func write(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        if data.isEmpty { return true }
        guard data.count <= 256 * 1024, outstandingWrites < 64,
              data.count <= 1024 * 1024 - outstandingBytes else { return false }
        pendingKeys.append(data)
        outstandingBytes += data.count
        outstandingWrites += 1
        return true
    }

    public func resize(columns: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        pendingSize = (max(1, min(columns, 65535)), max(1, min(rows, 65535)))
    }

    /// Call after wake or a network-path change. A fresh UDP source port avoids
    /// stale NAT mappings, and a missing reply starts the stall fallback timer.
    public func probe() {
        lock.lock(); defer { lock.unlock() }
        if !closed { probeRequested = true }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        clearPending()
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

/// Connected UDP lets the kernel discard packets from a different address/port.
/// It is owned solely by the worker; replacement is how mosh roams its source port.
private final class MoshDatagram {
    struct Endpoint {
        let address: Data
        let family: Int32
    }
    let endpoint: Endpoint
    private let descriptor: Int32

    init(endpoint: Endpoint) throws {
        self.endpoint = endpoint
        #if os(Linux)
        let type = Int32(SOCK_DGRAM.rawValue)
        #else
        let type = SOCK_DGRAM
        #endif
        let descriptor = socket(endpoint.family, type, 0)
        guard descriptor >= 0 else { throw RoamError.transport("Cannot create mosh UDP socket") }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            moshClose(descriptor); throw RoamError.transport("Cannot configure mosh UDP socket")
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let result = endpoint.address.withUnsafeBytes { address in
            moshConnect(descriptor, address.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(address.count))
        }
        guard result == 0 else { moshClose(descriptor); throw RoamError.transport("Cannot connect mosh UDP socket") }
        self.descriptor = descriptor
    }

    deinit { moshClose(descriptor) }

    static func connect(host: String, port: Int) throws -> MoshDatagram {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_DGRAM.rawValue)
        #else
        hints.ai_socktype = SOCK_DGRAM
        #endif
        hints.ai_protocol = Int32(IPPROTO_UDP)
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &head) == 0, let first = head else {
            throw RoamError.transport("Cannot resolve mosh server")
        }
        defer { freeaddrinfo(first) }
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let node = next {
            let value = node.pointee
            if let address = value.ai_addr, value.ai_addrlen > 0,
               let datagram = try? MoshDatagram(endpoint: Endpoint(address: Data(bytes: address, count: Int(value.ai_addrlen)), family: value.ai_family)) {
                return datagram
            }
            next = value.ai_next
        }
        throw RoamError.transport("Cannot connect mosh UDP socket")
    }

    func send(_ data: Data) {
        _ = data.withUnsafeBytes { moshSend(descriptor, $0.baseAddress, $0.count) }
    }

    func receive(wait seconds: TimeInterval) -> Data? {
        var descriptor = pollfd(fd: self.descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(max(1, seconds * 1000))) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 65_535)
        let count = recv(self.descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return Data(buffer.prefix(count))
    }
}

private func moshNow() -> TimeInterval {
    #if os(Linux)
    var value = timespec()
    clock_gettime(CLOCK_BOOTTIME, &value)
    return TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
    #else
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return TimeInterval(mach_continuous_time()) * TimeInterval(info.numer) / TimeInterval(info.denom) / 1_000_000_000
    #endif
}

private func moshClose(_ descriptor: Int32) {
    #if os(Linux)
    _ = Glibc.close(descriptor)
    #else
    _ = Darwin.close(descriptor)
    #endif
}

private func moshConnect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if os(Linux)
    return Glibc.connect(descriptor, address, length)
    #else
    return Darwin.connect(descriptor, address, length)
    #endif
}

private func moshSend(_ descriptor: Int32, _ bytes: UnsafeRawPointer?, _ count: Int) -> Int {
    #if os(Linux)
    return Glibc.send(descriptor, bytes, count, Int32(MSG_NOSIGNAL))
    #else
    return Darwin.send(descriptor, bytes, count, 0)
    #endif
}
