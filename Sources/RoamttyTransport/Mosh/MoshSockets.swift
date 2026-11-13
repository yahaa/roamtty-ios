import Foundation
import RoamttyCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Connected UDP lets the kernel discard packets from a different address/port.
/// It is owned solely by the worker; replacement is how mosh roams its source port.
final class MoshDatagram {
    struct Endpoint {
        let address: Data
        let family: Int32
    }
    let endpoint: Endpoint
    private let descriptor: Int32
    /// Reused by every receive: the worker owns this socket alone.
    private var buffer = [UInt8](repeating: 0, count: 65_535)

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

    /// nil after the timeout, or as soon as `wake` is signalled.
    func receive(wait seconds: TimeInterval, wake: WorkerWake) -> Data? {
        guard wake.poll(descriptor, events: Int16(POLLIN), timeout: Int32(max(1, seconds * 1000))) == 1 else { return nil }
        return receiveReady()
    }

    /// A datagram already waiting on the non-blocking socket; nil when there is none.
    func receiveReady() -> Data? {
        let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
        guard count > 0 else { return nil }
        return Data(buffer[0..<count])
    }
}

/// A self-pipe that ends a transport worker's network wait as soon as input is queued, instead of after the
/// wait's timeout. Writers signal it; the worker polls its read end beside the socket.
final class WorkerWake {
    private let descriptor: Int32
    private let writer: Int32

    init?() {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { return nil }
        for end in ends {
            _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL, 0) | O_NONBLOCK)
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
        }
        descriptor = ends[0]; writer = ends[1]
    }

    deinit { moshClose(descriptor); moshClose(writer) }

    /// A full pipe already wakes the worker, so a failed write is fine.
    func signal() {
        var byte: UInt8 = 1
        _ = moshWrite(writer, &byte, 1)
    }

    /// Waits for `events` on `socket` or for a signal: 1 when the socket is ready, 0 after the timeout or a
    /// signal, and -1 when the poll failed.
    func poll(_ socket: Int32, events: Int16, timeout milliseconds: Int32) -> Int32 {
        var descriptors = [pollfd(fd: socket, events: events, revents: 0), pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)]
        let result = moshPoll(&descriptors, milliseconds)
        guard result > 0 else { return result }
        if descriptors[1].revents != 0 {
            var buffer = [UInt8](repeating: 0, count: 64)
            while moshRead(descriptor, &buffer, buffer.count) > 0 { }
        }
        return descriptors[0].revents != 0 ? 1 : 0
    }
}

#if !os(Linux)
/// Seconds per `mach_continuous_time` tick; the timebase never changes while the process runs.
private let moshTickSeconds: TimeInterval = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return TimeInterval(info.numer) / TimeInterval(info.denom) / 1_000_000_000
}()
#endif

/// Seconds on a clock that keeps running while the device sleeps.
func moshNow() -> TimeInterval {
    #if os(Linux)
    var value = timespec()
    clock_gettime(CLOCK_BOOTTIME, &value)
    return TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
    #else
    return TimeInterval(mach_continuous_time()) * moshTickSeconds
    #endif
}

private func moshClose(_ descriptor: Int32) {
    #if os(Linux)
    _ = Glibc.close(descriptor)
    #else
    _ = Darwin.close(descriptor)
    #endif
}

private func moshWrite(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    #if os(Linux)
    return Glibc.write(descriptor, bytes, count)
    #else
    return Darwin.write(descriptor, bytes, count)
    #endif
}

private func moshRead(_ descriptor: Int32, _ bytes: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if os(Linux)
    return Glibc.read(descriptor, bytes, count)
    #else
    return Darwin.read(descriptor, bytes, count)
    #endif
}

private func moshPoll(_ descriptors: inout [pollfd], _ milliseconds: Int32) -> Int32 {
    #if os(Linux)
    return Glibc.poll(&descriptors, nfds_t(descriptors.count), milliseconds)
    #else
    return Darwin.poll(&descriptors, nfds_t(descriptors.count), milliseconds)
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
