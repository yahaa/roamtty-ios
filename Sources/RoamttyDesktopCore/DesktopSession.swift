import Foundation
import Dispatch

/// One host's desktop (plan §4.1): its own SSH login, the plugin's `serve` on an exec channel, frames to
/// the video sink, input from the page. It outlives the page: `pause` keeps it for the keep-alive time
/// without pictures, and a dropped link is resumed with the session token for up to 30 s.
///
/// Port of Android `DesktopConnection` (roamtty #218) without the Android parts: coroutines become one
/// worker thread for the attempt loop plus a reader, a writer and a 250 ms ticker per stream; every
/// callback goes out on `callbackQueue` in order. The SSH login, the phone's downloads, the UDP socket and
/// the video decoder are injected, so the whole flow runs in tests against a local shell or a fake host.
public final class DesktopSession: @unchecked Sendable {
    public struct Config: Sendable {
        public var hostName: String
        /// The SSH host's address; UDP goes there unless `udpHostOverride` is set.
        public var address: String
        /// The phone's screen: its long edge caps the encode size.
        public var clientWidth: Int, clientHeight: Int, clientDpi: Int
        public var fps = 60
        public var quality = "auto"
        public var lockOnClose = false
        /// The host's sound on the phone (sent only by plugins that can).
        public var audio = true
        public var keepAliveMinutes = 5
        public var udpHostOverride = ""
        /// Test only: drop this share of datagrams on both ends.
        public var testLoss = 0.0
        public var english = false

        public init(hostName: String, address: String, clientWidth: Int, clientHeight: Int, clientDpi: Int) {
            self.hostName = hostName; self.address = address
            self.clientWidth = clientWidth; self.clientHeight = clientHeight; self.clientDpi = clientDpi
        }
    }

    /// Android's constants, shortened in tests.
    public struct Timings: Sendable {
        public var recoverLimitMs: Int64 = 30_000
        public var recoverRetryMs: Int64 = 1000
        public var needsRetryMs: Int64 = 1500
        public var nologinRetryMs: Int64 = 1000
        public var notLoggedInRetryMs: Int64 = 1000
        public var tickMs: Int64 = 250
        public var exitWaitMs: Int64 = 3000
        public init() {}
    }

    public static let POOR_MS: Int64 = 300

    public let config: Config
    let manifest: PluginManifest
    let login: () -> DesktopLogin
    let fetch: (String) throws -> Data
    let makeUdp: (String, Int) throws -> UdpTransport
    let timings: Timings
    let callbackQueue: DispatchQueue
    /// The decoder; the session owns it, as Android's connection owns its `VideoDecoder`.
    public var video: DesktopVideoSink?
    /// The sound player; the session feeds it AUDIO frames while sound is on and the page is shown.
    public var audio: DesktopAudioSink?

    // Observers: called on `callbackQueue`, in order.
    public var onPhase: ((DesktopPhase) -> Void)?
    /// Fresh capability results let the host list replace stale desktop availability, including on retry.
    public var onProbe: ((HostDesktop) -> Void)?
    public var onLog: (([String]) -> Void)?
    public var onHello: ((Hello) -> Void)?
    public var onStats: ((DesktopStats) -> Void)?
    public var onCursor: ((RemoteCursor?) -> Void)?
    public var onRemoteClipboard: ((String) -> Void)?
    /// One-off messages for the page, e.g. 请在本机解锁; nil clears it.
    public var onNotice: ((String?) -> Void)?
    public var onVideoSize: ((Int, Int) -> Void)?
    /// Whether the host can send its sound: known with the hello, false after STATE `audio: unavailable`.
    public var onAudioAvailable: ((Bool) -> Void)?
    /// The desktop ended (closed, failed or kicked) and is no longer active.
    public var onEnded: ((DesktopSession) -> Void)?

    // Everything below is the session's own state. It is internal rather than private only because the
    // session's parts live in sibling files (`DesktopSession+*.swift`); read and write it under `sync`.
    private let lock = NSRecursiveLock()
    private let wake = NSCondition()
    func sync<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    // Serialize transport media delivery with pause/resume and stream publication. No state
    // lock is held across a sink callback; synchronous reentry on this executor is supported.
    private let mediaQueue = DispatchQueue(label: "roamtty.desktop.media")
    private let mediaKey = DispatchSpecificKey<Bool>()
    func mediaSync<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: mediaKey) == true { return body() }
        return mediaQueue.sync(execute: body)
    }

    var desiredPaused = false
    var _phase: DesktopPhase = .idle
    private var _log: [String] = []
    var _hello: Hello?
    private var _stats = DesktopStats()
    var _cursor: RemoteCursor?
    var _videoSize = (0, 0)
    var _display = 0
    var _viewOnly = false
    var _fps: Int, _quality: String, _lockOnClose: Bool, _audio: Bool
    /// Only the small window over the terminal shows the picture: the host sends fewer, smaller frames.
    var _mini = false
    var _audioAvailable: Bool?
    var audioPacketsSeen: Int64 = 0
    var _failure: DesktopText?

    var running = false
    var closing = false
    var kicked = false
    var everConnected = false
    var agentReloaded = false
    var serviceInstallTried = false
    var _windowsHost = false
    var host: DesktopHost?
    var stream: DesktopStream?
    var outgoing: DesktopOutQueue?
    var link: UdpLink?
    var sessionId: String?
    var resumeToken: String?
    var keepAliveGeneration = 0

    var videoOrder = DesktopVideoOrder()
    var keyframes = DesktopKeyframeThrottle()
    /// When each frame arrived (monotonic µs), until the decoder acknowledges it.
    var received: [Int64: Int64] = [:]
    var shapes: [UInt64: CursorImage] = [:]
    var ping = DesktopPingClock()
    /// Since when the link has been good, 0 while it is bad.
    var goodSinceMs: Int64 = 0
    var traffic = DesktopTrafficWindow()
    public internal(set) var inputsSent = 0
    public internal(set) var inputsDropped = 0
    let latency = LatencyMeter()

    /// `login` opens the desktop's own SSH login (called again for every attempt); `fetch` downloads on the
    /// phone (`HTTPFetch.get`); `makeUdp` opens a UDP socket to (host, port).
    public init(config: Config, manifest: PluginManifest, timings: Timings = Timings(),
                callbackQueue: DispatchQueue = DispatchQueue(label: "roamtty.desktop.callbacks"),
                login: @escaping () -> DesktopLogin,
                fetch: @escaping (String) throws -> Data = HTTPFetch.get,
                makeUdp: @escaping (String, Int) throws -> UdpTransport = { try UdpSocketTransport(host: $0, port: $1) }) {
        self.config = config; self.manifest = manifest; self.timings = timings; self.callbackQueue = callbackQueue
        self.login = login; self.fetch = fetch; self.makeUdp = makeUdp
        _fps = config.fps; _quality = config.quality; _lockOnClose = config.lockOnClose; _audio = config.audio
        mediaQueue.setSpecific(key: mediaKey, value: true)
    }

    // MARK: State

    public var phase: DesktopPhase { sync { _phase } }
    public var log: [String] { sync { _log } }
    public var hello: Hello? { sync { _hello } }
    public var stats: DesktopStats { sync { _stats } }
    public var display: Int { sync { _display } }
    public var viewOnly: Bool { sync { _viewOnly } }
    public var fps: Int { sync { _fps } }
    public var quality: String { sync { _quality } }
    public var lockOnClose: Bool { sync { _lockOnClose } }
    public var audioOn: Bool { sync { _audio } }
    /// Nil until the host said; false when it has no sound to send (an older plugin, or no audio server).
    public var audioAvailable: Bool? { sync { _audioAvailable } }
    /// Why the last attempt failed, in both languages (the phase carries it in the configured one).
    public var failure: DesktopText? { sync { _failure } }
    /// The host runs Windows (known once the probe answered): the NeedsAction card shows the service hint.
    public var windowsHost: Bool { sync { _windowsHost } }
    public var active: Bool { sync { if case .idle = _phase { return false }; if case .failed = _phase { return false }; return true } }
    /// Whether frames go over UDP right now.
    public var onUdp: Bool { sync { link?.alive ?? false } }

    var isClosing: Bool { sync { closing } }

    func text(_ t: DesktopText) -> String { t.text(english: config.english) }

    func setPhase(_ p: DesktopPhase) {
        sync {
            let next: DesktopPhase
            if case .connected(let poor, _) = p { next = .connected(poor: poor, paused: desiredPaused) } else { next = p }
            if _phase != next { _phase = next; callbackQueue.async { self.onPhase?(next) } }
        }
        wakeAll()
    }

    func line(_ s: String) {
        let snapshot: [String] = sync { _log.append(s); if _log.count > 200 { _log.removeFirst(_log.count - 200) }; return _log }
        callbackQueue.async { self.onLog?(snapshot) }
    }

    func updateStats(_ change: (inout DesktopStats) -> Void) {
        let s: DesktopStats = sync { change(&_stats); return _stats }
        callbackQueue.async { self.onStats?(s) }
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static func nowUs() -> Int64 { UdpLink.monotonicUs() }

    /// Sleeps up to `ms`, waking early on `close`.
    func pause(ms: Int64) {
        let until = Date().addingTimeInterval(Double(ms) / 1000)
        wake.lock()
        while !sync({ closing }) && Date() < until { _ = wake.wait(until: until) }
        wake.unlock()
    }

    func wakeAll() { wake.lock(); wake.broadcast(); wake.unlock() }
}
