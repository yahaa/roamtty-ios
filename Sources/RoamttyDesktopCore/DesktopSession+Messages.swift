import Foundation

/// What the host sends: pictures, sound, the cursor, its state and the ping answers.
extension DesktopSession {
    /// Frames from either transport; UDP's arrive on its receive thread.
    func handle(_ m: ServerMessage) {
        switch m {
        case .video, .audio: mediaSync { dispatch(m) }
        default: dispatch(m)
        }
    }

    private func dispatch(_ m: ServerMessage) {
        switch m {
        case .video(let v): handleVideo(v)
        case .cursorShape(let hash, let w, let h, let hx, let hy, let rgba):
            handleCursorShape(hash, w > 0 && h > 0 ? CursorImage(width: w, height: h, hotX: hx, hotY: hy, rgba: rgba) : nil)
        case .cursorPos(let x, let y, let visible, let shape):
            let c: RemoteCursor = sync {
                let cursor = RemoteCursor(x: x, y: y, visible: visible, shape: shapes[shape])
                _cursor = cursor
                return cursor
            }
            callbackQueue.async { self.onCursor?(c) }
        case .state(let st): handleState(st)
        case .audio(let a):
            let play: Bool = sync { _audio && !desiredPaused && !closing }
            if play { audio?.submit(a) }
        case .ping(let t1):
            let now = Self.nowUs()
            send(DesktopProtocol.pong(t1, now, now))
        case .pong(let t1, let t2, let t3):
            let now = Self.nowUs()
            latency.onPong(t1: t1, t2: t2, t3: t3, t4: now)
            if let rtt = sync({ ping.answer(t1: t1, nowUs: now) }) { updateStats { $0.rttMs = rtt } }
        }
    }

    private func handleVideo(_ v: Video) {
        guard !sync({ desiredPaused || closing }) else { return }
        switch sync({ videoOrder.accept(frame: v.frame, keyframe: v.keyframe) }) {
        case .stale: return
        case .broken: askKeyframe(); return
        case .ok: break
        }
        let now = Self.nowUs()
        let sizeChanged: Bool = sync {
            received[v.frame] = now
            traffic.count(bytes: v.data.count)
            let changed = _videoSize != (v.width, v.height)
            _videoSize = (v.width, v.height)
            return changed
        }
        latency.onReceived(frame: v.frame, captureUs: v.captureUs, encodedUs: v.encodedUs, recvUs: now)
        if sizeChanged { callbackQueue.async { self.onVideoSize?(v.width, v.height) } }
        if stats.width != v.width || stats.height != v.height { updateStats { $0.width = v.width; $0.height = v.height } }
        video?.submit(v)
    }

    /// A cursor image (nil for an empty one): kept by its hash, and shown if the cursor was waiting for it.
    private func handleCursorShape(_ hash: UInt64, _ image: CursorImage?) {
        let c: RemoteCursor? = sync {
            if let image { shapes[hash] = image }
            guard let c = _cursor else { return nil }
            _cursor = RemoteCursor(x: c.x, y: c.y, visible: c.visible, shape: c.shape ?? shapes[hash])
            return _cursor
        }
        if let c { callbackQueue.async { self.onCursor?(c) } }
    }

    private func handleState(_ st: StateMessage) {
        if st.kicked { let s: DesktopStream? = sync { kicked = true; return stream }; s?.close(); wakeAll() }
        if let clip = st.clip { callbackQueue.async { self.onRemoteClipboard?(clip) } }
        if let needs = st.needs, !needs.isEmpty { setPhase(.needsAction(needs: needs)) }
        if let locked = st.locked {
            let notice = locked ? text(.unlockOnComputer) : nil
            callbackQueue.async { self.onNotice?(notice) }
        }
        if let e = st.error { line(e) }
        if let timing = st.timing { latency.onHostTiming(timing) }
        if let a = st.audio {
            line("host audio \(a): \(JSONValue.string(st.json["detail"]))")
            sync { _audioAvailable = false }
            audio?.stop()
            callbackQueue.async { self.onAudioAvailable?(false) }
        }
    }

    /// Asks the host for a keyframe, at most once a second (`DesktopKeyframeThrottle`).
    func askKeyframe() {
        if sync({ keyframes.shouldAsk(nowMs: Self.nowMs()) }) { send(DesktopProtocol.req(DesktopProtocol.REQ_KEYFRAME)) }
    }

    /// The decoder lost its place (phase 3 calls this).
    public func needKeyframe() { askKeyframe() }
    /// The decoder output `frame` at `decodedUs` (monotonic µs): ACK it, and the desktop is up.
    public func decoded(frame: Int64, decodedUs: Int64) {
        latency.onDecoded(frame: frame, decodedUs: decodedUs)
        let recv: Int64 = sync {
            let r = received.removeValue(forKey: frame) ?? decodedUs
            // Frames that never decode are forgotten in batches, not by rebuilding the table for every frame.
            if received.count > 240 { received = received.filter { $0.key >= frame - 120 } }
            return r
        }
        send(DesktopProtocol.ack(frame: frame, recvUs: recv, decodedUs: decodedUs))
        // Only a desktop on its way up: a frame the decoder still held after a kick or a failure (UDP keeps
        // them coming until the link closes) must not bring a dead connection back to life.
        let up: Bool = sync {
            switch _phase {
            case .connecting, .recovering:
                everConnected = true
                return true
            default: return false
            }
        }
        if up { setPhase(.connected(poor: false, paused: sync { desiredPaused })) }
    }

    /// Presentation timestamp (monotonic µs); iOS approximates it with actual layer enqueue.
    public func rendered(frame: Int64, renderedUs: Int64) { latency.onRendered(frame: frame, renderedUs: renderedUs) }
}
