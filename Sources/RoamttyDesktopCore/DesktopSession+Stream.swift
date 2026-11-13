import Foundation

/// One run of the plugin's stream: publish it, read frames until it ends, tear it down.
extension DesktopSession {
    func runStream(_ s: DesktopStream, _ hello: Hello, parser: FrameParser) -> Outcome {
        sync { _hello = hello }
        callbackQueue.async { self.onHello?(hello) }
        if !hello.needs.isEmpty {
            setPhase(.needsAction(needs: hello.needs))
            s.close()
            sync { stream = nil }
            return isClosing ? .closed : .needs
        }
        let queue = DesktopOutQueue()
        updateStats { $0.encoder = hello.hardware }
        let canAudio = hello.audio.contains("opus")
        publish(queue, hello, canAudio: canAudio)
        startUdp(hello, queue)
        callbackQueue.async { self.onAudioAvailable?(canAudio) }
        if !sync({ everConnected }) { setPhase(.connecting(step: .firstFrame)) }
        sync { ping = DesktopPingClock(); traffic.restart(nowMs: Self.nowMs()) }
        latency.reset()

        startWriter(queue, to: s)
        let ticker = DesktopTicker(intervalMs: timings.tickMs) { [weak self] in self?.tick() }
        readFrames(s, parser: parser)
        lingerOnUdp()
        return endStream(s, queue, ticker)
    }

    /// Sends the first CONFIG and the page's standing requests, then lets the page's input reach the queue.
    private func publish(_ queue: DesktopOutQueue, _ hello: Hello, canAudio: Bool) {
        mediaSync {
            video?.reset()
            let first: [String: Any] = sync {
                sessionId = hello.session; resumeToken = hello.resumeToken
                if !hello.displays.indices.contains(_display) { _display = max(0, hello.displays.firstIndex { $0.primary } ?? 0) }
                videoOrder.restart()
                _audioAvailable = canAudio
                var config: [String: Any] = ["display": _display, "fps": streamFps, "quality": _quality, "lock_on_close": _lockOnClose]
                if _mini { config["max_bitrate"] = Self.miniMaxBitrate }
                if canAudio && _audio { config["audio"] = true }
                return config
            }
            queue.send(DesktopProtocol.config(first))
            if sync({ _viewOnly }) { queue.send(DesktopProtocol.req(DesktopProtocol.REQ_VIEW_ONLY_ON)) }
            if sync({ desiredPaused }) { queue.send(DesktopProtocol.req(DesktopProtocol.REQ_PAUSE)) }
            // Publication and initial pause intent share the media executor with pause/resume.
            sync { outgoing = queue }
        }
    }

    private func startWriter(_ queue: DesktopOutQueue, to s: DesktopStream) {
        let writer = Thread {
            while let batch = queue.take() {
                do { for b in batch { try s.write(b) } } catch { s.close(); break }
            }
        }
        writer.name = "roamtty.desktop.writer"
        writer.start()
    }

    /// Handles frames until the channel ends, the session closes or another device takes the desktop.
    private func readFrames(_ s: DesktopStream, parser initial: FrameParser) {
        var parser = initial
        while !isClosing {
            while let item = parser.next() {
                guard case .frame(let f) = item else { return }
                if let m = DesktopProtocol.decode(f) { handle(m) }
                if sync({ kicked || closing }) { return }
            }
            let bytes = s.read(maxBytes: 256 * 1024)
            if bytes.isEmpty { return }
            parser.push(bytes)
        }
    }

    /// The SSH channel is gone but UDP still carries the desktop: keep going on it alone, as the host
    /// does, until UDP falls silent too.
    private func lingerOnUdp() {
        guard !sync({ closing || kicked }) && sync({ link?.alive ?? false }) else { return }
        sync { outgoing = nil }
        while !sync({ closing || kicked }) && sync({ link?.alive ?? false }) { pause(ms: 200) }
    }

    private func endStream(_ s: DesktopStream, _ queue: DesktopOutQueue, _ ticker: DesktopTicker) -> Outcome {
        let l: UdpLink? = sync { outgoing = nil; stream = nil; let l = link; link = nil; return l }
        queue.close()
        ticker.stop()
        s.close()
        l?.close()
        updateStats { $0.link = "SSH"; $0.lossPercent = nil }
        audio?.stop()
        sync { inputsSent = 0; inputsDropped = 0 }
        if sync({ kicked }) { return .kicked }
        if sync({ closing }) { return .closed }
        return .streamed
    }

    /// Opens the host's UDP offer; the link sends its own port so a host firewall can let replies in.
    private func startUdp(_ hello: Hello, _ queue: DesktopOutQueue) {
        guard let offer = hello.udp else { return }
        let address = config.udpHostOverride.isEmpty ? config.address : config.udpHostOverride
        guard let transport = try? makeUdp(address, offer.port) else { return }
        let l = UdpLink(key: offer.key, transport: transport,
                        onFrame: { [weak self] f in if let m = DesktopProtocol.decode(f) { self?.handle(m) } },
                        onVideoLost: { [weak self] in self?.askKeyframe() },
                        log: { [weak self] in self?.line($0) })
        if config.testLoss > 0 { l.dropRate = config.testLoss; queue.send(DesktopProtocol.config(["debug_loss": config.testLoss])) }
        l.start()
        sync { link = l }
        queue.send(DesktopProtocol.config(["udp_client_port": l.localPort]))
    }
}
