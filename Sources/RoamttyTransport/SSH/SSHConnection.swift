import Foundation
import CNative
import RoamttyCore

/// libssh2 handles are always touched under `libraryLock`. Waiting for network readiness never holds it,
/// so terminal, exec and short-lived SFTP channels can share an authenticated connection.
///
/// The connection's parts live in sibling files (`SSHConnection+*.swift`), which is the only reason its state
/// is internal rather than private: `stateLock` guards the flags and queues, `libraryLock` every libssh2 call.
public final class SSHConnection: @unchecked Sendable {
    let host: RoamttyCore.Host
    var credentials: Credentials
    let pins: PinStore
    let prompt: (AuthPrompt) -> [String]?
    public var onPhase: ((ConnectionPhase) -> Void)?
    let libraryLock = NSRecursiveLock()
    let stateLock = NSLock()
    // libssh2 keeps channel-open and SFTP-init retry state on the session.
    // Hold this gate across EAGAIN, without preventing existing-channel I/O.
    let creationCondition = NSCondition()
    var creatingChannel = false
    var session: OpaquePointer?
    /// The allocator of a session this connection made; see `roam_ssh_heap_destroy`.
    var heap: OpaquePointer?
    /// Blocks libssh2 left behind in sessions since launch, released when each session went.
    public static var reclaimedNativeBlocks: Int { reclaimedLock.lock(); defer { reclaimedLock.unlock() }; return reclaimed }
    static let reclaimedLock = NSLock()
    static var reclaimed = 0
    // Raw read/write/resize calls interleave on a worker. EAGAIN does not imply
    // that the most recent call owns libssh2's one retained transport packet.
    struct PendingChannelIO {
        var read: (stream: Int32, count: Int)?
        var write: (stream: Int32, bytes: Data)?
        var resize: (columns: Int32, rows: Int32, width: Int32, height: Int32)?
        var isEmpty: Bool { read == nil && write == nil && resize == nil }
    }
    var pendingChannelIO: [OpaquePointer: PendingChannelIO] = [:]
    var socket: Int32 = -1
    var terminal: OpaquePointer?
    var stopped = false
    var authenticated = false
    var acceptingInput = false
    var input = InputQueue()
    /// Ends the terminal loop's network wait as soon as input is queued.
    let wake = WorkerWake()
    var pendingSize: (Int, Int)?
    var transferGeneration = 0
    /// Loops parked on the socket between bursts (the terminal, exec streams), by their wake, and the other
    /// libssh2 work in flight. Another thread's libssh2 call can read a loop's packets off the socket into
    /// libssh2's buffer, where no poll sees them, so a loop waits long only while it is the connection's sole user.
    var waitingLoops: [ObjectIdentifier: WorkerWake] = [:]
    var otherWork = 0
    /// A loop's network wait while nothing else uses the connection: input, a resize, a close or other work wake it.
    static let idleWaitMs: Int32 = 1000
    /// A loop's network wait while other work may take its packets off the socket.
    static let sharedWaitMs: Int32 = 30
    static let initialized: Void = { _ = libssh2_init(0) }()

    public init(host: RoamttyCore.Host, credentials: Credentials, pinStore: PinStore, prompt: @escaping (AuthPrompt) -> [String]?) {
        self.host = host; self.credentials = credentials; self.pins = pinStore; self.prompt = prompt
    }
    deinit {
        disconnect()
        libraryLock.lock()
        if let session { _ = libssh2_session_free(session) }
        if let heap {
            let count = roam_ssh_heap_destroy(heap, nil)
            Self.reclaimedLock.lock(); Self.reclaimed += count; Self.reclaimedLock.unlock()
        }
        libraryLock.unlock()
        roam_socket_close(socket)
        credentials.clear()
    }
    var isStopped: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stopped }
    public var isConnected: Bool { stateLock.lock(); defer { stateLock.unlock() }; return authenticated && !stopped }
    /// The numeric address this connection actually reached, which a name with several addresses does not pin down.
    var peerAddress: String? {
        stateLock.lock(); let fd = socket; stateLock.unlock()
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard roam_socket_peer(fd, &buffer, Int32(buffer.count)) == 0 else { return nil }
        return String(cString: buffer)
    }
    func locked<T>(_ action: () throws -> T) rethrows -> T { libraryLock.lock(); defer { libraryLock.unlock() }; return try action() }
    /// `wake` lets queued input end the wait early.
    func networkWait(wake: WorkerWake? = nil) throws {
        guard !isStopped else { throw RoamError.cancelled }
        let direction = locked { libssh2_session_block_directions(session) }
        let read = direction & LIBSSH2_SESSION_BLOCK_INBOUND != 0
        let write = direction & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0
        let result = wake.map { $0.poll(socket, events: Int16((read || !write ? POLLIN : 0) | (write ? POLLOUT : 0)), timeout: waitMilliseconds(for: $0)) }
            ?? roam_socket_poll(socket, read || !write ? 1 : 0, write ? 1 : 0, Self.sharedWaitMs)
        if result < 0 {
            disconnect()
            throw RoamError.transport("Network wait failed")
        }
    }
    func waitMilliseconds(for wake: WorkerWake) -> Int32 {
        stateLock.lock(); defer { stateLock.unlock() }
        let alone = otherWork == 0 && waitingLoops.count == 1 && waitingLoops[ObjectIdentifier(wake)] != nil
        return alone ? Self.idleWaitMs : Self.sharedWaitMs
    }
    /// Wakes every parked loop, so each picks its wait again.
    func wakeLoops(_ loops: [WorkerWake]) { for loop in loops { loop.signal() } }
    /// A loop that waits on the socket with `wake`, for as long as `body` runs.
    func asWaitingLoop<T>(_ wake: WorkerWake?, _ body: () throws -> T) rethrows -> T {
        guard let wake else { return try body() }
        stateLock.lock(); waitingLoops[ObjectIdentifier(wake)] = wake; let others = Array(waitingLoops.values); stateLock.unlock()
        wakeLoops(others)
        defer { stateLock.lock(); waitingLoops.removeValue(forKey: ObjectIdentifier(wake)); let rest = Array(waitingLoops.values); stateLock.unlock(); wakeLoops(rest) }
        return try body()
    }
    /// libssh2 work outside the loops: parked loops switch to short waits until it ends.
    func asOtherWork<T>(_ body: () throws -> T) rethrows -> T {
        beginOtherWork()
        defer { endOtherWork() }
        return try body()
    }
    /// The two halves of `asOtherWork`, for work that outlives one call (a held SFTP session).
    func beginOtherWork() {
        stateLock.lock(); otherWork += 1; let loops = otherWork == 1 ? Array(waitingLoops.values) : []; stateLock.unlock()
        wakeLoops(loops)
    }
    func endOtherWork() {
        // Its last call may have left a loop's packets in libssh2's buffer: each loop reads once more before waiting long.
        stateLock.lock(); otherWork -= 1; let loops = otherWork == 0 ? Array(waitingLoops.values) : []; stateLock.unlock()
        wakeLoops(loops)
    }

    func error(_ code: Int32) -> RoamError {
        if code == LIBSSH2_ERROR_AUTHENTICATION_FAILED { return .authentication }
        switch code {
        case LIBSSH2_ERROR_SOCKET_SEND, LIBSSH2_ERROR_SOCKET_RECV,
             LIBSSH2_ERROR_SOCKET_DISCONNECT, LIBSSH2_ERROR_BAD_SOCKET,
             LIBSSH2_ERROR_SOCKET_TIMEOUT, LIBSSH2_ERROR_INVALID_MAC,
             LIBSSH2_ERROR_DECRYPT, LIBSSH2_ERROR_ENCRYPT,
             LIBSSH2_ERROR_KEX_FAILURE, LIBSSH2_ERROR_KEY_EXCHANGE_FAILURE,
             LIBSSH2_ERROR_PROTO, LIBSSH2_ERROR_ZLIB, LIBSSH2_ERROR_COMPRESS:
            disconnect()
        default: break // Missing files, denied channels, and command exits are not connection death.
        }
        // Library text may contain remote-controlled content or credentials; never log it.
        return .transport("SSH operation failed (\(code))")
    }

    public func disconnect() {
        stateLock.lock()
        let notify = authenticated && !stopped
        authenticated = false; stopped = true; acceptingInput = false; input.reset(); transferGeneration += 1
        let fd = socket, loops = Array(waitingLoops.values)
        stateLock.unlock()
        roam_socket_shutdown(fd)
        wakeLoops(loops)
        creationCondition.lock(); creationCondition.broadcast(); creationCondition.unlock()
        if notify { onPhase?(.disconnected) }
    }

    func transferEpoch() -> Int { stateLock.lock(); defer { stateLock.unlock() }; return transferGeneration }
}
