import Foundation
import Dispatch

/// Headless voice bridge session (`roamtty-desktop voice --proto 1`):
/// manages its own SSH exec channel + `UdpLink` (AES-128-GCM + RS-FEC + roaming),
/// headless plugin install (skipping OpenH264 & LaunchAgent/GUI), `ANTIGRAVITY_MIC` env injection,
/// `--resume` reconnection, and `MIC_*` / `SPK_*` routing to `VoiceAudioIO`.
public final class VoiceSession: @unchecked Sendable {
    public struct Config: Sendable {
        public var hostName: String
        public var address: String
        public var preferredPort: Int = VoiceProtocol.defaultPort
        public var idleTimeoutSec: Int = VoiceProtocol.defaultIdleTimeoutSec
        public var tmuxSession: String?
        public var udpHostOverride = ""
        public var testLoss = 0.0
        public var english = false

        public init(hostName: String, address: String, tmuxSession: String? = nil) {
            self.hostName = hostName
            self.address = address
            self.tmuxSession = tmuxSession
        }
    }

    public struct Timings: Sendable {
        public var recoverLimitMs: Int64 = 290_000
        public var recoverRetryMs: Int64 = 1_000
        public var tickMs: Int64 = 250
        public var exitWaitMs: Int64 = 3_000
        public var helloTimeoutMs: Int64 = 25_000
        public var shutdownGraceMs: Int64 = 120
        public init() {}
    }

    public let config: Config
    let manifest: PluginManifest
    let login: () -> DesktopLogin
    let fetch: (String) throws -> Data
    let makeUdp: (String, Int) throws -> UdpTransport
    let injectMicPort: (DesktopHost, Int, Bool) -> Void
    let clearMicPort: (DesktopHost, Bool) -> Void
    let timings: Timings
    let callbackQueue: DispatchQueue
    public var audioIO: VoiceAudioIO?

    public var onPhase: ((VoiceSessionPhase) -> Void)?
    public var onHello: ((VoiceHello) -> Void)?
    public var onEvent: ((VoiceStreamEvent) -> Void)?
    public var onNetworkPoor: ((Bool) -> Void)?
    public var onLog: (([String]) -> Void)?
    public var onEnded: ((VoiceSession) -> Void)?

    private let lock = NSRecursiveLock()
    let handleLock = NSRecursiveLock()
    private let wake = NSCondition()
    func sync<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var _phase: VoiceSessionPhase = .idle
    var _hello: VoiceHello?
    private var _log: [String] = []
    var _muted = false
    var _windowsHost = false
    var running = false
    var closing = false
    var kicked = false
    var everConnected = false
    var installAttempted = false
    var shutdownGraceUntil: Date?
    var sshEofDuringClose = false

    var host: DesktopHost?
    var stream: DesktopStream?
    var outgoing: DesktopOutQueue?
    var link: UdpLink?
    var sessionId: String?
    var resumeToken: String?
    var activeMicStreamId: UInt32?
    var activeSpkStreamId: UInt32?
    var ping = DesktopPingClock()
    var goodSinceMs: Int64 = 0
    var _networkPoor = false

    public init(
        config: Config,
        manifest: PluginManifest,
        timings: Timings = Timings(),
        callbackQueue: DispatchQueue = DispatchQueue(label: "roamtty.voice.callbacks"),
        login: @escaping () -> DesktopLogin,
        fetch: @escaping (String) throws -> Data = HTTPFetch.get,
        makeUdp: @escaping (String, Int) throws -> UdpTransport = { try UdpSocketTransport(host: $0, port: $1) },
        injectMicPort: ((DesktopHost, Int, Bool) -> Void)? = nil,
        clearMicPort: ((DesktopHost, Bool) -> Void)? = nil
    ) {
        self.config = config
        self.manifest = manifest
        self.timings = timings
        self.callbackQueue = callbackQueue
        self.login = login
        self.fetch = fetch
        self.makeUdp = makeUdp
        let tmux = config.tmuxSession
        self.injectMicPort = injectMicPort ?? { host, port, windows in
            Self.runMicPortOp(host: host, port: port, windows: windows, tmuxSession: tmux)
        }
        self.clearMicPort = clearMicPort ?? { host, windows in
            Self.runMicPortOp(host: host, port: nil, windows: windows, tmuxSession: tmux)
        }
    }

    // MARK: State & controls

    public var phase: VoiceSessionPhase { sync { _phase } }
    public var hello: VoiceHello? { sync { _hello } }
    public var micPort: Int? { sync { _hello?.micPort } }
    public var log: [String] { sync { _log } }
    public var onUdp: Bool { sync { link?.alive ?? false } }
    public var isMuted: Bool { sync { _muted } }
    public var networkPoor: Bool { sync { _networkPoor } }
    public var active: Bool {
        sync {
            switch _phase {
            case .idle, .failed: return false
            case .connecting, .ready, .recovering: return true
            }
        }
    }
    var isClosing: Bool { sync { closing } }

    public func setMuted(_ muted: Bool) { sync { _muted = muted } }

    public func start() {
        let go: Bool = sync {
            if running { return false }
            running = true; closing = false; kicked = false; installAttempted = false
            shutdownGraceUntil = nil; sshEofDuringClose = false
            return true
        }
        guard go else { return }
        setPhase(.connecting(step: .login))
        let t = Thread { [self] in runLoop() }
        t.name = "roamtty.voice.\(config.hostName)"
        t.start()
    }

    public func close() {
        var s: DesktopStream?
        var l: UdpLink?
        var q: DesktopOutQueue?
        var h: DesktopHost?
        var wasRunning = false
        var alreadyClosing = false
        var sendShutdown = false
        let graceMs = max(0, timings.shutdownGraceMs)
        sync {
            if closing {
                alreadyClosing = true
                return
            }
            closing = true
            activeMicStreamId = nil
            activeSpkStreamId = nil
            s = stream
            l = link
            q = outgoing
            h = host
            wasRunning = running
            sendShutdown = (q != nil || (l?.alive ?? false))
            if sendShutdown {
                shutdownGraceUntil = Date().addingTimeInterval(Double(graceMs) / 1000)
            }
        }
        audioIO?.stopAll()
        if alreadyClosing { wakeAll(); return }
        if sendShutdown {
            let shutdownFrame = VoiceProtocol.config(["shutdown": true])
            if let l, l.alive { l.send(shutdownFrame, reliable: true, fecRatio: 1.0) }
            q?.send(shutdownFrame)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(Int(graceMs))) { [weak self] in
                s?.close()
                l?.close()
                self?.wakeAll()
            }
        } else {
            s?.close()
            l?.close()
            h?.disconnect()
        }
        wakeAll()
        if !wasRunning {
            setPhase(.idle)
            callbackQueue.async { self.onEnded?(self) }
        }
    }

    public func networkChanged(_ change: NetworkChange = .newInterface) {
        let (ok, l, s, h) = sync { (everConnected && !closing, link, stream, host) }
        guard ok else { return }
        if change == .pathUpdate {
            guard let l, l.alive else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + .microseconds(Int(DesktopSession.pathUpdateQuietUs))) { [weak self] in
                guard let self, self.sync({ self.link === l && !self.closing }), l.silentUs >= DesktopSession.pathUpdateQuietUs else { return }
                l.rebind()
            }
            return
        }
        if let l, l.alive { l.rebind(); return }
        s?.close()
        h?.disconnect()
    }

    public func voiceCommand() -> String {
        let (session, token, windows) = sync { (sessionId, resumeToken, _windowsHost) }
        return VoiceProtocol.voiceCommand(
            windows: windows,
            port: config.preferredPort,
            resumeSession: session,
            resumeToken: token,
            idleTimeoutSec: config.idleTimeoutSec
        )
    }

    /// Sends a protocol frame over UDP while alive (with optional FEC ratio), otherwise SSH exec stdin.
    func sendFrame(_ bytes: [UInt8], reliable: Bool, fecRatio: Float? = nil) {
        let (l, q) = sync { (link, outgoing) }
        if let l, l.alive {
            l.send(bytes, reliable: reliable, fecRatio: fecRatio)
        } else {
            q?.send(bytes)
        }
    }

    func setPhase(_ next: VoiceSessionPhase) {
        sync {
            if _phase != next {
                _phase = next
                callbackQueue.async { self.onPhase?(next) }
            }
        }
        wakeAll()
    }

    func emit(_ event: VoiceStreamEvent) {
        callbackQueue.async { self.onEvent?(event) }
    }

    func line(_ s: String) {
        let snapshot: [String] = sync {
            _log.append(s)
            if _log.count > 200 { _log.removeFirst(_log.count - 200) }
            return _log
        }
        callbackQueue.async { self.onLog?(snapshot) }
    }

    func text(_ t: DesktopText) -> String { t.text(english: config.english) }
    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static func nowUs() -> Int64 { UdpLink.monotonicUs() }

    func pause(ms: Int64) {
        let until = Date().addingTimeInterval(Double(ms) / 1000)
        wake.lock()
        while !sync({ closing }) && Date() < until { _ = wake.wait(until: until) }
        wake.unlock()
    }

    func waitUntilDate(_ deadline: Date) {
        wake.lock()
        while !sync({ sshEofDuringClose }) && Date() < deadline { _ = wake.wait(until: deadline) }
        wake.unlock()
    }

    func wakeAll() { wake.lock(); wake.broadcast(); wake.unlock() }

    private static func runMicPortOp(host: DesktopHost, port: Int?, windows: Bool, tmuxSession: String?) {
        if let port, !(1...65535).contains(port) { return }
        if windows {
            if let port {
                if let cmd = WindowsDesktop.writeAgyLauncherCommand(micPort: port) {
                    _ = host.runCommand(cmd, timeout: 10) { _ in }
                }
            } else {
                _ = host.runCommand(WindowsDesktop.clearAgyLauncherCommand(), timeout: 5) { _ in }
            }
            return
        }
        var lines = [
            "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/home/linuxbrew/.linuxbrew/bin:/snap/bin\"; export PATH"
        ]
        if let port {
            let addr = "127.0.0.1:\(port)"
            lines.append("mkdir -p \"$HOME/.roamtty\"")
            lines.append(
                "tmp=$(mktemp \"$HOME/.roamtty/voice-mic.XXXXXX\") && " +
                "{ printf '%s\\n' '\(addr)' > \"$tmp\" && mv -f \"$tmp\" \"$HOME/.roamtty/voice-mic\" || { rm -f \"$tmp\"; false; }; }"
            )
        } else {
            lines.append("rm -f \"$HOME/.roamtty/voice-mic\"")
        }
        if let raw = tmuxSession, !raw.isEmpty {
            let safe = String(raw.unicodeScalars.filter {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "-" || $0 == "_"
            }.prefix(64))
            if !safe.isEmpty {
                if let port {
                    lines.append("tmux set-environment -t =\(safe) ANTIGRAVITY_MIC '127.0.0.1:\(port)' 2>/dev/null || true")
                } else {
                    lines.append("tmux set-environment -u -t =\(safe) ANTIGRAVITY_MIC 2>/dev/null || true")
                }
            }
        }
        _ = host.run(lines.joined(separator: "\n") + "\n", timeout: port == nil ? 5 : 10) { _ in }
    }
}
