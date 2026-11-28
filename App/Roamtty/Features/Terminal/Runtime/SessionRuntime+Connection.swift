import UIKit
import SwiftTerm
import RoamttyCore
import RoamttyTransport

/// What one connection attempt needs on its worker, gathered on the main thread before it starts.
struct SessionConnectionPlan {
    let ssh: SSHConnection
    let mode: SessionMode
    let name: String
    /// The tmux session already exists on the host.
    let existing: Bool
    let columns: Int, rows: Int
    /// Typed once the terminal is ready: the agent's command line, or a `cd` into the start folder.
    let startup: String?
    /// The runtime's generation when the attempt began; callbacks of an older one drop out.
    let token: UUID
    let lifetime: TransferCancellation
}

/// Connecting: log in, then carry the terminal over mosh when asked and possible, else over SSH.
extension SessionRuntime {
    func connect(ssh: SSHConnection, credentials: Credentials, preferMosh: Bool, directory: String, agent: AgentLaunch?) {
        loginSnapshot = SessionLoginSnapshot(host: host, credentials: credentials)
        self.ssh = ssh; currentDirectory = directory; phase = .connecting; end = nil
        if let agent { launchedAgent = agent.agent }
        let hooks = agent.flatMap { $0.reportsStatus ? $0.agent : nil }
        let token = generation
        // Once mosh carries the terminal, SSH only does side work: its drop must not stop a terminal that still works.
        ssh.onPhase = { [weak self] value in
            DispatchQueue.main.async { guard self?.generation == token, self?.mosh == nil else { return }; self?.phase = value == .connected && self?.startupSent == false ? .connecting : value }
        }
        let hookSession = record.mode == .tmux ? record.remoteName : nil
        let plan = SessionConnectionPlan(ssh: ssh, mode: record.mode, name: record.remoteName, existing: record.external, columns: columns, rows: rows,
                                         startup: agent?.commandLine(session: hookSession) ?? StartDirectory.command(directory),
                                         token: token, lifetime: lifetimeCancellation)
        let overMosh = preferMosh ? moshTerminal(plan) : nil
        let overSSH = sshTerminal(plan)
        worker = Task { [weak self] in
            do {
                try await performInBackground {
                    try ssh.connect()
                    // The hook script and the agent's hook file go on the host before it starts; a failure only costs the status.
                    if let hooks { SessionRemote.installAgentHooks(ssh, agent: hooks, session: hookSession, cancellation: plan.lifetime) }
                    if let overMosh, try overMosh() { return }
                    guard !plan.lifetime.isCancelled else { throw RoamError.cancelled }
                    try overSSH()
                }
                guard self?.generation == token else { return }
                self?.voice.shutdown()
                self?.cancelStartup(); self?.end = .ended; self?.phase = .disconnected
            } catch { guard self?.generation == token else { return }; self?.cancelStartup(); self?.fail(error) }
        }
    }

    /// The worker's mosh attempt: true once the terminal ran over mosh to its end, false when mosh could not
    /// carry it and nothing was typed yet, so SSH takes over. It keeps no strong hold on the runtime while it blocks.
    private func moshTerminal(_ plan: SessionConnectionPlan) -> () throws -> Bool {
        return { [weak self] in
            do {
                let previous = plan.mode == .tmux ? try SessionRemote.tmuxClients(plan.ssh, name: plan.name, cancellation: plan.lifetime) : []
                let attempt = UUID()
                let mosh = try plan.ssh.startMosh(mode: plan.mode, remoteName: plan.name, existing: plan.existing)
                DispatchQueue.main.sync {
                    guard self?.generation == plan.token else { mosh.close(); return }
                    self?.mosh = mosh; self?.transportName = "mosh"
                    self?.beginStartup(plan, previousClients: previous, attempt: attempt, afterFirstContact: true)
                }
                try mosh.run(columns: plan.columns, rows: plan.rows, firstContactTimeout: 8, silenceTimeout: plan.mode == .shell ? 43_740 : 840,
                             stallTimeout: plan.mode == .shell ? nil : 10, log: { Diagnostics.shared.log("mosh", $0) }) { data in
                    DispatchQueue.main.sync { self?.receive(data, token: plan.token, attempt: attempt) }
                }
                return true
            } catch {
                let canFallback = DispatchQueue.main.sync { () -> Bool in
                    guard let self, self.generation == plan.token, !self.startupSent else { return false }
                    self.cancelStartup(); self.mosh?.close(); self.mosh = nil; self.transportName = "SSH"; self.fallbackNotice = Self.moshFallbackNotice
                    return true
                }
                // Commitment and fallback are one main-thread transaction, so no
                // readiness callback can authorize input between those decisions.
                guard canFallback else { throw error }
                return false
            }
        }
    }

    /// The worker's SSH terminal: opens it and carries it until it ends.
    private func sshTerminal(_ plan: SessionConnectionPlan) -> () throws -> Void {
        return { [weak self] in
            let previous = plan.mode == .tmux ? try SessionRemote.tmuxClients(plan.ssh, name: plan.name, cancellation: plan.lifetime) : []
            let attempt = UUID()
            try plan.ssh.openTerminal(mode: plan.mode, remoteName: plan.name, existing: plan.existing, columns: plan.columns, rows: plan.rows)
            DispatchQueue.main.sync {
                guard self?.generation == plan.token else { return }
                self?.beginStartup(plan, previousClients: previous, attempt: attempt, afterFirstContact: false)
            }
            try plan.ssh.runTerminal { data in DispatchQueue.main.sync { self?.receive(data, token: plan.token, attempt: attempt) } }
        }
    }

    /// The SSH connection for side work, logged in again when it dropped under a working mosh terminal; nil when
    /// there is none. A failed login waits `sideReconnectInterval` before the next try.
    func sideConnection() async -> SSHConnection? {
        if let ssh, ssh.isConnected { return ssh }
        guard mosh != nil, phase == .connected, let reopenSideConnection else { return nil }
        if let sideReconnect { return await sideReconnect.value }
        if let sideReconnectAt, Date().timeIntervalSince(sideReconnectAt) < Self.sideReconnectInterval { return nil }
        sideReconnectAt = Date()
        let token = generation
        let task = Task { [weak self] () -> SSHConnection? in
            guard let connection = try? await reopenSideConnection() else { return nil }
            guard let self, self.generation == token, self.mosh != nil else { connection.disconnectInBackground(); return nil }
            let previous = self.ssh; self.ssh = connection; self.sideReconnectAt = nil
            previous?.disconnectInBackground()
            return connection
        }
        sideReconnect = task
        let connection = await task.value
        if generation == token { sideReconnect = nil }
        return connection
    }
    static let sideReconnectInterval: TimeInterval = 30
    func receive(_ data: Data, token: UUID, attempt: UUID) {
        guard generation == token, startupAttempt == attempt else { return }
        if let view = terminalView as? AccessibleTerminalView { view.feedKeepingPlace(Array(data)[...]) } else { terminalView.feed(byteArray: Array(data)[...]) }
        voice.codexStatus?.receive(data)
        mouseTracking.consume(data); restoreMouseTracking()
        queueCursorRefresh()
        if !startupSent {
            startupGate?.sawOutput = true
            if let ssh { waitForStartup(ssh: ssh, name: record.remoteName, token: token, attempt: attempt) }
            finishStartup(token: token, attempt: attempt)
        }
    }
    /// SwiftTerm drops tracking when an encoding mode is reset, as mosh does on every resize; swipes then stop
    /// reaching tmux. Put the mode the host asked for back.
    func restoreMouseTracking() {
        guard mouseTracking.atBoundary else { return }
        let terminal = terminalView.getTerminal()
        let current: Int?
        switch terminal.mouseMode {
        case .off: current = nil
        case .x10: current = 9
        case .vt200: current = 1000
        case .buttonEventTracking: current = 1002
        case .anyEvent: current = 1003
        }
        guard current != mouseTracking.mode, let mode = mouseTracking.mode ?? current else { return }
        terminalView.feed(text: "\u{1b}[?\(mode)" + (mouseTracking.mode == nil ? "l" : "h"))
    }

}
