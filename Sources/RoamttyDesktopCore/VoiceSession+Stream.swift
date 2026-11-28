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
        let isWindows = targetName.hasPrefix("windows-")
        sync { _windowsHost = isWindows }
        if config.backend == .codex && isWindows {
            return .failed(.codexVoiceUnsupportedOs)
        }
        if config.backend == .codex, codexTarget == nil {
            guard let target = resolveCodexTarget(remote) else { return .failed(.codexThreadRequired) }
            codexTarget = target
        }
        if probe.version != manifest.version, let failed = installHeadless(remote, build: build, target: targetName) { return failed }
        if isClosing { return .closed }
        var tries = 0
        while !isClosing && tries < 3 {
            tries += 1
            switch startPlugin(remote, build: build, target: targetName, codexThread: codexTarget?.thread, codexCwd: codexTarget?.cwd) {
            case .finished(let outcome): return outcome
            case .retry: break
            }
        }
        return isClosing ? .closed : .failed(.voicePluginStartFailed)
    }

    private func startPlugin(
        _ remote: DesktopHost,
        build: DesktopPluginInstaller.Build,
        target: String,
        codexThread: String?,
        codexCwd: String?
    ) -> StartStep {
        if !sync({ everConnected }) { setPhase(.connecting(step: .start)) }
        guard let s = remote.openStream(voiceCommand(codexThread: codexThread, codexCwd: codexCwd)) else { return .finished(.dropped(nil)) }
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
        switch VoiceProtocol.parseStart(first, backend: config.backend) {
        case .failed(let code, let detail, _, _):
            s.close()
            if code == "proto_unsupported", !sync({ installAttempted }) {
                if let failed = installHeadless(remote, build: build, target: target) { return .finished(failed) }
                return .retry
            }
            if code == "codex_voice_failed" {
                return .finished(.failed(.codexVoiceFailed(detail ?? code)))
            }
            return .finished(.failed(.voicePluginError(detail ?? code)))
        case .ready(let hello):
            if config.backend == .codex && hello.micPort != 0 {
                s.close()
                if !sync({ installAttempted }) {
                    if let failed = installHeadless(remote, build: build, target: target) { return .finished(failed) }
                    return .retry
                }
                return .finished(.failed(.codexVoiceOutdatedPlugin))
            }
            let outcome = runStream(s, remote: remote, hello: hello, parser: parser)
            if config.backend == .agy && isClosing {
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
        let epoch = UUID()
        let (windows, useOpus): (Bool, Bool) = sync {
            transportEpoch = epoch
            closedMicIds.removeAll()
            closedSpeakerIds.removeAll()
            hadMediaThisAttempt = false
            _hello = hello
            if !hello.session.isEmpty { sessionId = hello.session }
            if !hello.resumeToken.isEmpty { resumeToken = hello.resumeToken }
            if config.backend == .agy { everConnected = true }
            ping = DesktopPingClock()
            goodSinceMs = 0
            _networkPoor = false
            sshEofDuringClose = false
            lastSpkStats = nil
            lastUplinkStats = nil
            lastStallRebindMs = 0
            micSender = nil
            let opus = hello.codecs.contains { $0.caseInsensitiveCompare("opus") == .orderedSame }
            voiceOpusEnabled = opus
            return (_windowsHost, opus)
        }
        callbackQueue.async { self.onNetworkPoor?(false) }
        if config.backend == .agy {
            // Always (re-)inject ANTIGRAVITY_MIC on hello so even a fresh fallback port after resume takes effect.
            sync { _agyKeysAllowed = false }
            let target = agyKeyTarget(remote, hello.micPort, windows: windows)
            injectMicPort(remote, hello.micPort, windows)
            if isClosing { s.close(); sync { stream = nil }; return .closed }
            let stillTargeted = target != nil && target == agyKeyTarget(remote, hello.micPort, windows: windows)
            sync { _agyKeysAllowed = stillTargeted }
        }
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
        if useOpus {
            queue.send(VoiceProtocol.config(["voice_codec": "opus"]))
        }
        startUdp(hello, queue, epoch: epoch)
        if !isClosing, config.backend == .agy { setPhase(.ready(micPort: hello.micPort, udp: sync { link?.alive ?? false })) }

        let ticker = startVoiceTicker(stream: s, epoch: epoch)
        readFrames(s, parser: parser, epoch: epoch)
        lingerOnUdp()
        return endStream(s, queue, ticker)
    }

    private func startVoiceTicker(stream: DesktopStream, epoch: UUID) -> DesktopTicker {
        let deadline = Self.nowUs() / 1000 + timings.mediaStartTimeoutMs
        return DesktopTicker(intervalMs: timings.tickMs) { [weak self] in
            guard let self, self.sync({ self.transportEpoch == epoch }) else { return }
            if self.config.backend == .codex, Self.nowUs() / 1000 >= deadline {
                self.handleLock.lock()
                let expired = self.sync {
                    guard self.transportEpoch == epoch, !self.hadMediaThisAttempt, !self.closing else { return false }
                    self.transportEpoch = nil
                    return true
                }
                self.handleLock.unlock()
                if expired {
                    self.sync { self.link }?.close()
                    stream.close()
                    return
                }
            }
            self.tick()
        }
    }

    private func startUdp(_ hello: VoiceHello, _ queue: DesktopOutQueue, epoch: UUID) {
        guard let offer = hello.udp else { return }
        let address = config.udpHostOverride.isEmpty ? config.address : config.udpHostOverride
        guard let transport = try? makeUdp(address, offer.port) else { return }
        let l = UdpLink(
            key: offer.key, transport: transport,
            onFrame: { [weak self] f in if let msg = VoiceProtocol.decode(f) { self?.handle(msg, epoch: epoch) } },
            onVideoLost: {},
            onGiveUp: { [weak self] frame in
                guard let self else { return }
                self.sync { self.transportEpoch == epoch && !self.closing ? self.outgoing : nil }?.send(frame)
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

    private func readFrames(_ s: DesktopStream, parser initial: FrameParser, epoch: UUID) {
        var parser = initial
        while !sync({ kicked }) {
            while let item = parser.next() {
                guard case .frame(let f) = item else { return }
                if !isClosing, let msg = VoiceProtocol.decode(f) { handle(msg, epoch: epoch) }
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
        guard sync({ !closing && !kicked && transportEpoch != nil && link?.alive == true }) else { return }
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
        handleLock.lock()
        let (l, wasPoor): (UdpLink?, Bool) = sync {
            transportEpoch = nil
            outgoing = nil; stream = nil
            activeMicStreamId = nil; activeSpkStreamId = nil; drainingSpeakerId = nil
            shutdownGraceUntil = nil; sshEofDuringClose = false
            goodSinceMs = 0
            let prevPoor = _networkPoor; _networkPoor = false
            let l = link; link = nil; return (l, prevPoor)
        }
        if wasPoor { callbackQueue.async { self.onNetworkPoor?(false) } }
        audioIO?.stopAll()
        handleLock.unlock()
        queue.close()
        ticker.stop()
        s.close()
        l?.close()
        if sync({ kicked }) { return .kicked }
        if isClosing { return .closed }
        return config.backend == .codex && !sync({ hadMediaThisAttempt }) ? .dropped(.codexVoiceNoMedia) : .streamed
    }

    private func tick() {
        guard !isClosing else { return }
        let nowUs = Self.nowUs()
        let nowMs = nowUs / 1000
        if let p = sync({ ping.due(nowUs: nowUs) }) { sendFrame(VoiceProtocol.ping(p), reliable: false) }
        if let p = sync({ ping.resendIfLate(nowUs: nowUs, lateMs: DesktopSession.POOR_MS) }) {
            sendFrame(VoiceProtocol.ping(p), reliable: false)
        }
        let (useOpus, spkId, udpLink, lastRebind) = sync { (voiceOpusEnabled, activeSpkStreamId, link, lastStallRebindMs) }
        if useOpus, let spkId, let st = audioIO?.speakerStats(streamId: spkId, nowMs: nowMs) {
            sync { lastSpkStats = st }
            sendFrame(VoiceProtocol.voiceStats(st), reliable: false, fecRatio: 0.0)
        }
        // Fast UDP stall probe: trigger rebind after 700 ms silence instead of waiting full 3 s ALIVE_US.
        if let l = udpLink, l.alive, l.silentUs > 700_000, nowMs - lastRebind >= 2_000 {
            sync { lastStallRebindMs = nowMs }
            DispatchQueue.global(qos: .userInitiated).async { l.rebind() }
        }
        updateLinkQuality(now: Self.nowMs())
        let (port, udpAlive) = sync { (_hello?.micPort, link?.alive ?? false) }
        if let port, case .ready(let p, let wasUdp) = phase, p == port, wasUdp != udpAlive {
            setPhase(.ready(micPort: port, udp: udpAlive))
        }
    }

    private func updateLinkQuality(now: Int64) {
        let (l, rtt, missed, spkSt, upSt) = sync { (link, ping.rttMs, ping.missed, lastSpkStats, lastUplinkStats) }
        let voiceLoss = max(Double(spkSt?.lossPermille ?? 0) / 1000.0, Double(upSt?.lossPermille ?? 0) / 1000.0)
        let bad: Bool
        if let l, l.alive {
            bad = l.silentUs > 700_000 || max(l.loss, voiceLoss) > 0.20 || Int64(rtt) > DesktopSession.POOR_MS
        } else {
            bad = missed >= 2 || voiceLoss > 0.20 || Int64(rtt) > DesktopSession.POOR_MS
        }
        let next: Bool? = sync {
            if bad { goodSinceMs = 0 } else if goodSinceMs == 0 { goodSinceMs = now }
            let poor = bad || (_networkPoor && now - goodSinceMs < 5_000)
            guard poor != _networkPoor else { return nil }
            _networkPoor = poor
            return poor
        }
        if let next { callbackQueue.async { self.onNetworkPoor?(next) } }
    }
}
