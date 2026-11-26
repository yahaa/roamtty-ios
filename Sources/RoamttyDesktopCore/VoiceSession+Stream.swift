import Foundation

/// Attempt loop, headless install, stream execution, and `MIC_*`/`SPK_*` dispatch for `VoiceSession`.
extension VoiceSession {
    enum Outcome: Equatable {
        case closed, kicked, streamed
        case failed(DesktopText)
        case dropped(DesktopText?)
    }

    private enum StartStep { case finished(Outcome), retry }
    private enum HelloRead { case line(String), eof, timedOut }

    func runLoop() {
        defer { audioIO?.stopAll() }
        var recoveringSince: Int64?
        while !isClosing {
            let outcome = attempt()
            switch outcome {
            case .closed: setPhase(.idle)
            case .kicked: setPhase(.failed(message: text(.voiceOpenedElsewhere)))
            case .failed(let t): setPhase(.failed(message: text(t)))
            case .dropped(let t):
                if !sync({ everConnected }) { setPhase(.failed(message: text(t ?? .voiceCannotConnect))); break }
                let since = recoveringSince ?? Self.nowMs()
                recoveringSince = since
                if Self.nowMs() - since > timings.recoverLimitMs { setPhase(.failed(message: text(.voiceConnectionLost))); break }
                setPhase(.recovering(sinceMs: since))
                pause(ms: timings.recoverRetryMs)
                continue
            case .streamed:
                recoveringSince = nil
                if !isClosing {
                    let now = Self.nowMs()
                    recoveringSince = now
                    setPhase(.recovering(sinceMs: now))
                    continue
                }
            }
            break
        }
        if isClosing, case .failed = phase {} else if isClosing { setPhase(.idle) }
        let ended: Bool = sync { running = false; return !active }
        if ended { callbackQueue.async { self.onEnded?(self) } }
    }

    private func attempt() -> Outcome {
        let remote: DesktopHost
        switch login() {
        case .noCredentials: return .failed(.cannotReadCredentials)
        case .failed(let msg, let connecting):
            if isClosing { return .closed }
            if sync({ everConnected }) || connecting { return .dropped(msg.map(DesktopText.raw)) }
            return .failed(msg.map(DesktopText.raw) ?? .cannotReachServer)
        case .host(let h): remote = h
        }
        if sync({ if closing { return true }; host = remote; return false }) { remote.disconnect(); return .closed }
        let outcome = loggedIn(remote)
        remote.disconnect()
        sync { host = nil }
        return isClosing ? .closed : outcome
    }

    private func loggedIn(_ remote: DesktopHost) -> Outcome {
        // Headless voice does NOT require a graphical desktop or console login.
        guard let probe = DesktopProbeScript.probe(remote) else { return .failed(.voiceCannotProbe) }
        if isClosing { return .closed }
        guard let targetName = PluginManifest.targetFor(probe.uname),
              let build = DesktopPluginInstaller.Build.pinned(manifest, target: targetName) else {
            return .failed(.unsupportedSystem)
        }
        sync { _windowsHost = targetName.hasPrefix("windows-") }
        if probe.version != manifest.version, let failed = installHeadless(remote, build: build, target: targetName) { return failed }
        var tries = 0
        while !isClosing && tries < 3 {
            tries += 1
            switch startPlugin(remote, build: build, target: targetName) {
            case .finished(let outcome): return outcome
            case .retry: break
            }
        }
        return isClosing ? .closed : .failed(.voicePluginStartFailed)
    }

    private func startPlugin(_ remote: DesktopHost, build: DesktopPluginInstaller.Build, target: String) -> StartStep {
        if !sync({ everConnected }) { setPhase(.connecting(step: .start)) }
        guard let s = remote.openStream(voiceCommand()) else { return .finished(.dropped(nil)) }
        sync { stream = s }
        var parser = FrameParser()
        let first: String
        switch readHello(s, &parser) {
        case .line(let line): first = line
        case .eof: return pluginSaidNothing(s, remote: remote, build: build, target: target)
        case .timedOut:
            s.close()
            sync { stream = nil }
            return .finished(isClosing ? .closed : .dropped(.voiceHelloTimeout))
        }
        if isClosing { s.close(); sync { stream = nil }; return .finished(.closed) }
        switch VoiceProtocol.parseStart(first) {
        case .failed(let code, let detail, _, _):
            s.close()
            if code == "proto_unsupported", !sync({ installAttempted }) {
                if let failed = installHeadless(remote, build: build, target: target) { return .finished(failed) }
                return .retry
            }
            return .finished(.failed(.voicePluginError(detail ?? code)))
        case .ready(let hello):
            let outcome = runStream(s, remote: remote, hello: hello, parser: parser)
            if isClosing {
                clearMicPort(remote, sync { _windowsHost })
            }
            return .finished(outcome)
        }
    }

    private func readHello(_ s: DesktopStream, _ parser: inout FrameParser) -> HelloRead {
        let lock = NSLock()
        var done = false
        var timedOut = false
        let timeoutMs = max(1, timings.helloTimeoutMs)
        let watchdog = DispatchWorkItem {
            let shouldClose: Bool = lock.withLock {
                guard !done else { return false }
                timedOut = true
                return true
            }
            if shouldClose { s.close() }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMs)), execute: watchdog)
        defer {
            lock.withLock { done = true }
            watchdog.cancel()
        }
        while !isClosing {
            let bytes = s.read(maxBytes: 64 * 1024)
            if lock.withLock({ timedOut }) { return .timedOut }
            if bytes.isEmpty { return .eof }
            parser.push(bytes)
            switch parser.next() {
            case .hello(let line): return .line(line)
            case .tooLong: return .eof
            default: continue
            }
        }
        return .eof
    }

    private func pluginSaidNothing(_ s: DesktopStream, remote: DesktopHost, build: DesktopPluginInstaller.Build, target: String) -> StartStep {
        if isClosing { s.close(); sync { stream = nil }; return .finished(.closed) }
        let deadline = Self.nowMs() + timings.exitWaitMs
        while !s.isClosed && !isClosing && Self.nowMs() < deadline { Thread.sleep(forTimeInterval: 0.03) }
        if isClosing { s.close(); sync { stream = nil }; return .finished(.closed) }
        let status = s.exitStatus
        let errors = s.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        s.close()
        if !errors.isEmpty { line(String(errors.suffix(500))) }
        // Exit 2 occurs on older plugins that do not yet support the `voice` subcommand.
        let needsUpgrade = status == 127 || status == WindowsDesktop.NOT_FOUND || status == 2
        if needsUpgrade && !sync({ installAttempted }) {
            if let failed = installHeadless(remote, build: build, target: target) { return .finished(failed) }
            return .retry
        }
        if status == 2 && s.isClosed { return .finished(.failed(.voiceUnsupportedByPlugin)) }
        if let status, s.isClosed { return .finished(.failed(.voicePluginStartFailedCode(status))) }
        return .finished(.dropped(nil))
    }

    private func installHeadless(_ remote: DesktopHost, build: DesktopPluginInstaller.Build, target: String) -> Outcome? {
        sync { installAttempted = true }
        setPhase(.connecting(step: .install))
        line(text(.voiceInstalling(version: build.version, target: target)))
        let installer = DesktopPluginInstaller(
            remote: remote, fetch: fetch,
            onStep: { [weak self] step in guard let self else { return }; self.line(self.text(.step(step))) },
            onLine: { [weak self] l in if !l.hasPrefix("__ROAMTTY_") { self?.line(l) } }
        )
        switch installer.install(build, headless: true) {
        case .installed: return nil
        case .failed(let reason, _): return .failed(DesktopText.voiceInstallFailure(reason))
        }
    }

    private func runStream(_ s: DesktopStream, remote: DesktopHost, hello: VoiceHello, parser: FrameParser) -> Outcome {
        let windows = sync {
            _hello = hello
            if !hello.session.isEmpty { sessionId = hello.session }
            if !hello.resumeToken.isEmpty { resumeToken = hello.resumeToken }
            everConnected = true
            ping = DesktopPingClock()
            sshEofDuringClose = false
            return _windowsHost
        }
        // Always (re-)inject ANTIGRAVITY_MIC on hello so even a fresh fallback port after resume takes effect.
        injectMicPort(remote, hello.micPort, windows)
        if isClosing { s.close(); sync { stream = nil }; return .closed }
        callbackQueue.async { self.onHello?(hello) }

        let queue = DesktopOutQueue()
        let writer = Thread {
            while let batch = queue.take() {
                do { for b in batch { try s.write(b) } } catch { s.close(); break }
            }
        }
        writer.name = "roamtty.voice.writer"
        writer.start()

        sync { outgoing = queue }
        startUdp(hello, queue)
        if !isClosing { setPhase(.ready(micPort: hello.micPort, udp: sync { link?.alive ?? false })) }

        let ticker = DesktopTicker(intervalMs: timings.tickMs) { [weak self] in self?.tick() }
        readFrames(s, parser: parser)
        lingerOnUdp()
        return endStream(s, queue, ticker)
    }

    private func startUdp(_ hello: VoiceHello, _ queue: DesktopOutQueue) {
        guard let offer = hello.udp else { return }
        let address = config.udpHostOverride.isEmpty ? config.address : config.udpHostOverride
        guard let transport = try? makeUdp(address, offer.port) else { return }
        let l = UdpLink(
            key: offer.key, transport: transport,
            onFrame: { [weak self] f in if let msg = VoiceProtocol.decode(f) { self?.handle(msg) } },
            onVideoLost: {},
            onGiveUp: { [weak self] frame in
                guard let self, !self.isClosing else { return }
                self.sync({ self.outgoing })?.send(frame)
            },
            log: { [weak self] in self?.line($0) }
        )
        if config.testLoss > 0 {
            l.dropRate = config.testLoss
            queue.send(VoiceProtocol.config(["debug_loss": config.testLoss]))
        }
        l.start()
        sync { link = l }
        queue.send(VoiceProtocol.config(["udp_client_port": l.localPort]))
    }

    private func readFrames(_ s: DesktopStream, parser initial: FrameParser) {
        var parser = initial
        while !sync({ kicked }) {
            while let item = parser.next() {
                guard case .frame(let f) = item else { return }
                if !isClosing, let msg = VoiceProtocol.decode(f) { handle(msg) }
                if sync({ kicked }) { return }
            }
            let bytes = s.read(maxBytes: 64 * 1024)
            if bytes.isEmpty {
                sync { sshEofDuringClose = closing }
                return
            }
            if !isClosing { parser.push(bytes) }
        }
    }

    private func lingerOnUdp() {
        guard !sync({ closing || kicked }) && sync({ link?.alive ?? false }) else { return }
        sync { outgoing = nil }
        while !sync({ closing || kicked }) && sync({ link?.alive ?? false }) { pause(ms: 200) }
    }

    private func endStream(_ s: DesktopStream, _ queue: DesktopOutQueue, _ ticker: DesktopTicker) -> Outcome {
        let graceDeadline: Date? = sync {
            guard closing, !sshEofDuringClose, link?.alive == true else { return nil }
            return shutdownGraceUntil
        }
        if let deadline = graceDeadline {
            waitUntilDate(deadline)
        }
        let l: UdpLink? = sync {
            outgoing = nil; stream = nil
            activeMicStreamId = nil; activeSpkStreamId = nil
            shutdownGraceUntil = nil; sshEofDuringClose = false
            let l = link; link = nil; return l
        }
        audioIO?.stopAll()
        queue.close()
        ticker.stop()
        s.close()
        l?.close()
        if sync({ kicked }) { return .kicked }
        if isClosing { return .closed }
        return .streamed
    }

    private func tick() {
        guard !isClosing else { return }
        let nowUs = Self.nowUs()
        if let p = sync({ ping.due(nowUs: nowUs) }) { sendFrame(VoiceProtocol.ping(p), reliable: false) }
        if let p = sync({ ping.resendIfLate(nowUs: nowUs, lateMs: DesktopSession.POOR_MS) }) {
            sendFrame(VoiceProtocol.ping(p), reliable: false)
        }
        let (port, udpAlive) = sync { (_hello?.micPort, link?.alive ?? false) }
        if let port, case .ready(let p, let wasUdp) = phase, p == port, wasUdp != udpAlive {
            setPhase(.ready(micPort: port, udp: udpAlive))
        }
    }

    func handle(_ message: VoiceServerMessage) {
        handleLock.lock()
        defer { handleLock.unlock() }
        guard !isClosing else { return }
        switch message {
        case .micStart(let id, let rate, let ch):
            let accepted = sync { () -> Bool in
                guard !closing else { return false }
                activeMicStreamId = id; return true
            }
            guard accepted else { return }
            audioIO?.startMic(streamId: id, sampleRate: rate, channels: ch) { [weak self] streamId, pcm in
                self?.sendMicPcm(streamId: streamId, pcm: pcm)
            }
            if isClosing { audioIO?.stopAll(); return }
            emit(.micStarted(streamId: id, sampleRate: rate))
        case .micStop(let id):
            let matched = sync { () -> Bool in
                guard activeMicStreamId == id else { return false }
                activeMicStreamId = nil; return true
            }
            if matched { audioIO?.stopMic(streamId: id); emit(.micStopped(streamId: id)) }
        case .spkStart(let id, let rate, let ch):
            handleSpeakerStart(streamId: id, sampleRate: rate, channels: ch)
        case .spkAudio(let id, let pcm):
            guard sync({ !closing && activeSpkStreamId == id }) else { return }
            audioIO?.playSpeaker(streamId: id, pcm: pcm)
            emit(.speakerAudio(streamId: id, bytes: pcm.count))
        case .spkClear(let id):
            guard sync({ !closing && activeSpkStreamId == id }) else { return }
            audioIO?.clearSpeaker(streamId: id)
            emit(.speakerCleared(streamId: id))
        case .spkStop(let id):
            let matched = sync { () -> Bool in
                guard activeSpkStreamId == id else { return false }
                activeSpkStreamId = nil; return true
            }
            if matched { audioIO?.stopSpeaker(streamId: id); emit(.speakerStopped(streamId: id)) }
        case .state(let st):
            if st.kicked { let s = sync { kicked = true; return stream }; s?.close(); wakeAll() }
            if let e = st.error { line(e) }
        case .ping(let t1):
            let now = Self.nowUs()
            sendFrame(VoiceProtocol.pong(t1, now, now), reliable: false)
        case .pong(let t1, _, _):
            _ = sync { ping.answer(t1: t1, nowUs: Self.nowUs()) }
        }
    }

    private func handleSpeakerStart(streamId: UInt32, sampleRate: UInt32, channels: UInt8) {
        guard !isClosing else { return }
        guard VoiceProtocol.speakerRateRange.contains(sampleRate), channels == 1 else {
            let err = "unsupported format \(sampleRate)Hz \(channels)ch"
            sendFrame(VoiceProtocol.spkAck(streamId: streamId, ok: false, error: err), reliable: true, fecRatio: 1.0)
            return
        }
        let result = audioIO?.startSpeaker(streamId: streamId, sampleRate: sampleRate, channels: channels) ?? .success(())
        switch result {
        case .success:
            let accepted = sync { () -> Bool in
                guard !closing else { return false }
                activeSpkStreamId = streamId; return true
            }
            guard accepted else { audioIO?.stopAll(); return }
            sendFrame(VoiceProtocol.spkAck(streamId: streamId, ok: true), reliable: true, fecRatio: 1.0)
            emit(.speakerStarted(streamId: streamId, sampleRate: sampleRate))
        case .failure(let error):
            guard !isClosing else { return }
            sendFrame(VoiceProtocol.spkAck(streamId: streamId, ok: false, error: error.description), reliable: true, fecRatio: 1.0)
        }
    }

    /// Sends captured 16 kHz mono s16le PCM in single-shard chunks (<= 640 B, even byte boundary).
    public func sendMicPcm(streamId: UInt32, pcm: [UInt8]) {
        let alignedCount = pcm.count & ~1
        guard alignedCount > 0, sync({ !closing && !_muted && activeMicStreamId == streamId }) else { return }
        let chunk = VoiceProtocol.micChunkBytes
        var offset = 0
        while offset < alignedCount {
            let end = min(offset + chunk, alignedCount)
            let slice = Array(pcm[offset..<end])
            sendFrame(VoiceProtocol.micAudio(streamId: streamId, pcm: slice), reliable: false, fecRatio: 1.0)
            offset = end
        }
    }
}
