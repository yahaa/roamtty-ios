import Foundation
import Dispatch

/// What the page asks of a desktop: input, its settings, and coming and going.
extension DesktopSession {
    /// How long a UDP link may hear nothing after a path update before it gets a new socket: the host
    /// answers our heartbeats (four a second), so a working link is never this quiet.
    static let pathUpdateQuietUs: Int64 = 1_500_000
    /// The small window's frame rate and bitrate cap (bits per second): plenty for a picture a third of the screen.
    public static let miniFps = 15
    public static let miniMaxBitrate = 1_500_000
    /// Lifts the cap: the host takes the lower of this and its own quality cap.
    public static let uncappedBitrate = 1_000_000_000

    // MARK: Page input

    /// Sends a frame to the host: over UDP while it is alive (resent until acknowledged when it must arrive), else SSH.
    public func send(_ bytes: [UInt8]) {
        let (l, q) = sync { (link, outgoing) }
        if let l, l.alive { l.send(bytes, reliable: UdpLink.reliable(bytes)) } else { q?.send(bytes) }
    }

    public func input(_ bytes: [UInt8]) {
        let drop: Bool = sync { if _viewOnly { inputsDropped += 1; return true }; inputsSent += 1; return false }
        if !drop { send(bytes) }
    }

    public func setViewOnly(_ on: Bool) {
        sync { _viewOnly = on }
        send(DesktopProtocol.req(on ? DesktopProtocol.REQ_VIEW_ONLY_ON : DesktopProtocol.REQ_VIEW_ONLY_OFF))
    }
    public func setQuality(_ value: String) { sync { _quality = value }; send(DesktopProtocol.config(["quality": value])) }
    public func setFps(_ value: Int) { let fps = sync { _fps = value; return streamFps }; send(DesktopProtocol.config(["fps": fps])) }
    /// The frame rate asked of the host: the user's, capped while only the small window shows the picture. Under `sync`.
    var streamFps: Int { _mini ? min(_fps, Self.miniFps) : _fps }
    /// Whether only the small window over the terminal shows the picture (Android `DesktopConnection.updateMini`):
    /// the host then sends at most `miniFps` frames a second and `miniMaxBitrate` bits.
    public func setMini(_ on: Bool) {
        let fps: Int? = sync {
            guard _mini != on else { return nil }
            _mini = on
            return streamFps
        }
        guard let fps else { return }
        send(DesktopProtocol.config(["fps": fps, "max_bitrate": on ? Self.miniMaxBitrate : Self.uncappedBitrate]))
    }
    public func setDisplay(_ index: Int) { sync { _display = index }; send(DesktopProtocol.config(["display": index])) }
    public func setLockOnClose(_ on: Bool) { sync { _lockOnClose = on }; send(DesktopProtocol.config(["lock_on_close": on])) }
    /// 声音: asking again after the host said it has none lets it try once more (a device plugged in since).
    public func setAudio(_ on: Bool) {
        let (known, retry): (Bool, Bool) = sync {
            _audio = on
            let retry = on && _audioAvailable == false && (_hello?.audio.contains("opus") ?? false)
            if retry { _audioAvailable = true }
            return (_audioAvailable != nil, retry)
        }
        if !on { audio?.stop() }
        if retry { callbackQueue.async { self.onAudioAvailable?(true) } }
        if known { send(DesktopProtocol.config(["audio": on])) }
    }

    // MARK: Lifecycle

    /// The page went away: no pictures, the link kept for the keep-alive time.
    public func pause() {
        let generation: Int = mediaSync {
            let generation = sync { desiredPaused = true; keepAliveGeneration += 1; return keepAliveGeneration }
            send(DesktopProtocol.req(DesktopProtocol.REQ_PAUSE))
            video?.reset()
            audio?.stop()
            if case .connected(let poor, _) = phase { setPhase(.connected(poor: poor, paused: true)) }
            return generation
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(config.keepAliveMinutes * 60)) { [weak self] in
            guard let self, self.sync({ self.keepAliveGeneration == generation }) else { return }
            self.close()
        }
    }

    public func resume() {
        mediaSync {
            sync { desiredPaused = false; keepAliveGeneration += 1; videoOrder.awaitKeyframe(); keyframes.lift() }
            if case .connected(let poor, _) = phase { setPhase(.connected(poor: poor, paused: false)) }
            send(DesktopProtocol.req(DesktopProtocol.REQ_RESUME))
            askKeyframe()
        }
        // Only a desktop that ended quietly (keep-alive over) starts again by itself; a failed one, e.g.
        // taken over by another device, waits for 重试.
        if !sync({ running }), case .idle = phase { start() }
    }

    /// A new network. On UDP: a new socket and three heartbeats now, plus a keyframe. On SSH: drop the old
    /// socket instead of waiting for keepalives; the loop resumes it.
    ///
    /// `.pathUpdate` is something else about the same network (a VPN's interface, the radio, DNS): iOS
    /// reports those too, and a new socket for each moved the port every 3-25 s on mobile data, losing
    /// what was on its way each time. Then only a UDP link that hears nothing for `pathUpdateQuietUs`
    /// gets a new socket (Wi-Fi to another Wi-Fi keeps the interface but not the socket's address); SSH
    /// is left to its pings.
    public func networkChanged(_ change: NetworkChange = .newInterface) {
        let (ok, l, s, h) = sync { (everConnected && !closing, link, stream, host) }
        guard ok else { return }
        if change == .pathUpdate {
            guard let l, l.alive else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + .microseconds(Int(Self.pathUpdateQuietUs))) { [weak self] in
                guard let self, self.sync({ self.link === l && !self.closing }), l.silentUs >= Self.pathUpdateQuietUs else { return }
                self.rebind(l, "network changed, UDP silent, rebinding")
            }
            return
        }
        if let l, l.alive {
            rebind(l, "network changed, rebinding UDP")
            return
        }
        s?.close()
        h?.disconnect()
    }

    /// A new socket for the UDP link, and a keyframe at once for what was lost on the way.
    private func rebind(_ l: UdpLink, _ why: String) {
        line(why)
        l.rebind()
        sync { keyframes.lift() }
        askKeyframe()
    }

    public func close() {
        let (s, l, h, wasRunning): (DesktopStream?, UdpLink?, DesktopHost?, Bool) = sync {
            closing = true; keepAliveGeneration += 1
            return (stream, link, host, running)
        }
        s?.close()
        l?.close()
        h?.disconnect()
        mediaSync { video?.reset(); audio?.stop() }
        wakeAll()
        if !wasRunning {
            setPhase(.idle)
            callbackQueue.async { self.onEnded?(self) }
        }
    }

    /// Test only: drop this share of UDP datagrams on the phone side (1.0 blocks UDP).
    func testUdpDrop(_ rate: Double) { sync { link }?.dropRate = rate }
}
