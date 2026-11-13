import Foundation

/// The attempt loop: log in, probe the host, install the plugin when it is missing or old, start `serve`.
extension DesktopSession {
    public func start() {
        let go: Bool = sync {
            if running { return false }
            running = true; closing = false; kicked = false; agentReloaded = false; serviceInstallTried = false
            return true
        }
        guard go else { return }
        setPhase(.connecting(step: .login))
        let t = Thread { [self] in runLoop() }
        t.name = "roamtty.desktop.\(config.hostName)"
        t.start()
    }

    enum Outcome: Equatable {
        case closed, kicked, needs, streamed
        case failed(DesktopText)
        case dropped(DesktopText?)
    }

    func fail(_ t: DesktopText) {
        sync { _failure = t }
        setPhase(.failed(message: text(t)))
    }

    func runLoop() {
        var recoveringSince: Int64?
        while !sync({ closing }) {
            let outcome = attempt()
            switch outcome {
            case .closed: setPhase(.idle)
            case .kicked: fail(.openedElsewhere)
            case .failed(let t): fail(t)
            case .dropped(let t):
                if !sync({ everConnected }) { fail(t ?? .cannotConnect); break }
                let since = recoveringSince ?? Self.nowMs()
                recoveringSince = since
                if Self.nowMs() - since > timings.recoverLimitMs { fail(.lostOver30s); break }
                setPhase(.recovering(sinceMs: since))
                pause(ms: timings.recoverRetryMs)
                continue
            case .streamed: recoveringSince = nil
            case .needs: pause(ms: timings.needsRetryMs); continue
            }
            if case .streamed = outcome, !sync({ closing }) {
                // The stream ran and ended by itself: try to get it back right away.
                let now = Self.nowMs()
                recoveringSince = now
                setPhase(.recovering(sinceMs: now))
                continue
            }
            break
        }
        if sync({ closing }), !{ if case .failed = phase { return true }; return false }() { setPhase(.idle) }
        let ended: Bool = sync { running = false; return !active }
        if ended { callbackQueue.async { self.onEnded?(self) } }
    }

    func attempt() -> Outcome {
        let result = login()
        let remote: DesktopHost
        switch result {
        case .noCredentials: return .failed(.cannotReadCredentials)
        case .failed(let message, let connecting):
            if sync({ closing }) { return .closed }
            // A login that never got through is the host saying no, unless a live desktop is recovering.
            if sync({ everConnected }) || connecting { return .dropped(message.map(DesktopText.raw)) }
            return .failed(message.map(DesktopText.raw) ?? .cannotReachServer)
        case .host(let h): remote = h
        }
        let alreadyClosing: Bool = sync { if closing { return true }; host = remote; return false }
        if alreadyClosing { remote.disconnect(); return .closed }
        let outcome = loggedIn(remote)
        remote.disconnect()
        sync { host = nil }
        return sync({ closing }) ? .closed : outcome
    }

    func probeDesktop(_ remote: DesktopHost) -> HostDesktop? {
        let found = DesktopProbeScript.probe(remote)
        if let found { callbackQueue.async { self.onProbe?(found) } }
        return found
    }

    /// The plugin build a host takes, and what the probe said about the host.
    struct PluginTarget {
        let remote: DesktopHost
        let probe: HostDesktop
        let name: String
        let build: DesktopPluginInstaller.Build
        var windows: Bool { name.hasPrefix("windows-") }
        var macOS: Bool { name.hasPrefix("macos-") }
    }

    /// What one start of the plugin's `serve` leads to.
    enum StartStep {
        case finished(Outcome)
        /// Start it again; three starts in a row give up.
        case retry
        /// Start it again without counting this start (something was repaired in between).
        case retryUncounted
        /// The stream ran and the user has yet to allow it on the host: the count starts over.
        case startOver
    }

    func loggedIn(_ remote: DesktopHost) -> Outcome {
        let probe = probeUntilLoggedIn(remote)
        if isClosing { return .closed }
        guard let probe else { return .failed(.cannotProbe) }
        if probe.desktop == "no" { return .failed(.noDesktop) }
        guard let name = PluginManifest.targetFor(probe.uname), let build = DesktopPluginInstaller.Build.pinned(manifest, target: name) else {
            return .failed(.unsupportedSystem)
        }
        let target = PluginTarget(remote: remote, probe: probe, name: name, build: build)
        sync { _windowsHost = target.windows }
        if probe.version != manifest.version, let failed = install(target) { return failed }
        var tries = 0
        while !isClosing && tries < 3 {
            tries += 1
            switch startPlugin(target) {
            case .finished(let outcome): return outcome
            case .retry: break
            case .retryUncounted: tries -= 1
            case .startOver: tries = 0
            }
        }
        return isClosing ? .closed : .failed(.pluginStartFailed)
    }

    /// Probes the host, again every second while nobody is logged in at its console.
    private func probeUntilLoggedIn(_ remote: DesktopHost) -> HostDesktop? {
        var probe = probeDesktop(remote)
        if probe?.uname.hasPrefix("Windows") == true { sync { _windowsHost = true } }
        while probe?.desktop == "nologin" && !isClosing {
            setPhase(.needsAction(needs: ["not-logged-in"]))
            pause(ms: timings.nologinRetryMs)
            if isClosing { break }
            probe = probeDesktop(remote)
        }
        return probe
    }

    /// Starts `serve` once and, when it greets, runs the stream until it ends.
    private func startPlugin(_ target: PluginTarget) -> StartStep {
        // While waiting on the user's permission, the guide stays up between tries.
        let showStart: Bool = sync { if everConnected { return false }; if case .needsAction = _phase { return false }; return true }
        if showStart { setPhase(.connecting(step: .start)) }
        guard let s = target.remote.openStream(serveCommand()) else { return .finished(.dropped(nil)) }
        sync { stream = s }
        var parser = FrameParser()
        guard let first = readHello(s, &parser) else { return pluginSaidNothing(s, target) }
        switch DesktopProtocol.parseStart(first) {
        case .failed(let code, let detail, _, _):
            s.close()
            return startRefused(code: code, detail: detail, target)
        case .ready(let hello):
            let outcome = runStream(s, hello, parser: parser)
            if outcome != .needs { return .finished(outcome) }
            // Every 1.5 s until the user allowed it on the host (plan §4.3: then it connects by itself).
            pause(ms: timings.needsRetryMs)
            return .startOver
        }
    }

    /// The plugin's first line, nil when the stream ended or sent something else before it.
    private func readHello(_ s: DesktopStream, _ parser: inout FrameParser) -> String? {
        while true {
            let bytes = s.read(maxBytes: 64 * 1024)
            if bytes.isEmpty { return nil }
            parser.push(bytes)
            switch parser.next() {
            case .hello(let line): return line
            case .tooLong: return nil
            default: continue
            }
        }
    }

    /// `serve` ended without a greeting: a missing plugin is installed, anything else ends the attempt.
    private func pluginSaidNothing(_ s: DesktopStream, _ target: PluginTarget) -> StartStep {
        let deadline = Self.nowMs() + timings.exitWaitMs
        while !s.isClosed && Self.nowMs() < deadline { Thread.sleep(forTimeInterval: 0.03) }
        let status = s.exitStatus
        let errors = s.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        s.close()
        if !errors.isEmpty { line(String(errors.suffix(500))) }
        if status == 127 || status == WindowsDesktop.NOT_FOUND {
            if let failed = install(target) { return .finished(failed) }
            return .retry
        }
        if let status, s.isClosed { return .finished(.failed(.pluginStartFailedCode(status))) }
        return .finished(.dropped(nil))
    }

    /// The plugin greeted with an error code.
    private func startRefused(code: String, detail: String?, _ target: PluginTarget) -> StartStep {
        switch code {
        case "encoder_failed", "proto_unsupported":
            if let failed = install(target) { return .finished(failed) }
            return .retry
        case "no_desktop": return .finished(.failed(.noDesktop))
        case "not_logged_in": return notLoggedIn(target)
        default: return .finished(.failed(.pluginError(detail ?? code)))
        }
    }

    private func notLoggedIn(_ target: PluginTarget) -> StartStep {
        // Someone is at the Mac's console, so the agent itself is gone (an upgrade that raced
        // launchd unloaded it): load it again once instead of waiting.
        if target.macOS && target.probe.desktop == "yes" && !sync({ agentReloaded }) {
            sync { agentReloaded = true }
            line(text(.restartingAgent))
            let ok = DesktopPluginInstaller(remote: target.remote, fetch: fetch, onLine: { [weak self] in self?.line($0) }).registerAgent()
            if ok { return .retryUncounted }
        }
        // Windows: the plugin is current but runs as a logon task. An install over an
        // administrator's login sets the service up, which serves the sign-in screen.
        if target.windows && !sync({ serviceInstallTried }) {
            sync { serviceInstallTried = true }
            if let failed = install(target) { return .finished(failed) }
            return .retryUncounted
        }
        setPhase(.needsAction(needs: ["not-logged-in"]))
        pause(ms: timings.notLoggedInRetryMs)
        return .retry
    }

    /// The `serve` command line, with the resume token once a stream ran.
    public func serveCommand() -> String {
        let (session, token, windows) = sync { (sessionId, resumeToken, _windowsHost) }
        // Resume tokens are base64: no quotes or spaces to escape in either shell.
        var resume = ""
        if let session, let token {
            let clean = String(token.unicodeScalars.filter { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "+/=".unicodeScalars.contains($0) })
            resume = " --resume \(session) --token \(clean)"
        }
        let client = "\(max(config.clientWidth, config.clientHeight))x\(min(config.clientWidth, config.clientHeight))@\(config.clientDpi)"
        let args = "--proto \(DesktopProtocol.supported.upperBound) --client \(client)\(resume)"
        return windows ? WindowsDesktop.serveCommand(args) : "\"$HOME/.roamtty/bin/roamtty-desktop\" serve \(args)"
    }

    /// Installs or upgrades the pinned plugin; nil once it is in place, else why not.
    private func install(_ target: PluginTarget) -> Outcome? {
        setPhase(.connecting(step: .install))
        line(text(.installing(version: target.build.version, target: target.name)))
        let installer = DesktopPluginInstaller(remote: target.remote, fetch: fetch,
            onStep: { [weak self] step in guard let self else { return }; self.line(self.text(.step(step))) },
            onLine: { [weak self] l in if !l.hasPrefix("__ROAMTTY_") { self?.line(l) } })
        switch installer.install(target.build) {
        case .installed: return nil
        case .failed(let reason, _): return .failed(DesktopText.installFailure(reason))
        }
    }
}
