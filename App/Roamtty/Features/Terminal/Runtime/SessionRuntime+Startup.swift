import Foundation
import RoamttyCore
import RoamttyTransport

/// Startup: the session counts as connected once tmux (or the shell) is ready and the start command went.
extension SessionRuntime {
    func beginStartup(_ plan: SessionConnectionPlan, previousClients: Set<String>, attempt: UUID, afterFirstContact: Bool) {
        cancelStartup()
        startupAttempt = attempt; startupCommand = plan.startup
        startupGate = TerminalStartupGate(needsTmuxClient: plan.mode == .tmux, requiresOutput: afterFirstContact || plan.mode == .tmux, previousClients: previousClients)
        if !afterFirstContact { waitForStartup(ssh: plan.ssh, name: plan.name, token: plan.token, attempt: attempt) }
        finishStartup(token: plan.token, attempt: attempt)
    }

    func finishStartup(token: UUID, attempt: UUID) {
        guard generation == token, startupAttempt == attempt, !startupSent, startupGate?.ready == true else { return }
        let launchingAgent = startupCommand != nil && launchedAgent != nil
        if let startupCommand {
            let input = Data((startupCommand + "\r").utf8)
            guard mosh?.write(input) ?? ssh?.write(input) ?? false else {
                close(); fail(RoamError.transport("启动命令未发送 / Startup command was not accepted")); return
            }
        }
        // Acceptance is irreversible: any later transport failure must not replay startup input.
        startupSent = true; phase = .connected; end = nil
        // Messages from earlier attempts go; the fallback notice of this one stays to be read.
        message = fallbackNotice; fallbackNotice = nil
        startAgentStatusPolling(awaitingLaunch: launchingAgent)
        startupTask?.cancel(); startupTask = nil; startupCancellation?.cancel(); startupCancellation = nil
        startupTimeoutTask?.cancel(); startupTimeoutTask = nil
    }
    func waitForStartup(ssh: SSHConnection, name: String, token: UUID, attempt: UUID) {
        guard startupTask == nil, startupGate?.needsTmuxClient == true else { return }
        let cancellation = TransferCancellation(), deadline = ProcessInfo.processInfo.systemUptime + 8
        startupCancellation = cancellation
        startupTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
                guard let self, self.generation == token, self.startupAttempt == attempt, !self.startupSent else { return }
                self.close(); self.fail(RoamError.transport(Self.tmuxNotReadyMessage))
            } catch { }
        }
        startupTask = Task { [weak self] in
            await withTaskCancellationHandler(operation: {
                do {
                    while ProcessInfo.processInfo.systemUptime < deadline {
                        try Task.checkCancellation()
                        guard let self, self.generation == token, self.startupAttempt == attempt else { return }
                        if self.startupGate?.sawNewClient != true {
                            let remaining = min(2, deadline - ProcessInfo.processInfo.systemUptime)
                            guard remaining > 0 else { throw RoamError.timeout }
                            let clients = try await performInBackground { try SessionRemote.tmuxClients(ssh, name: name, cancellation: cancellation, timeout: remaining) }
                            guard self.generation == token, self.startupAttempt == attempt else { return }
                            self.startupGate?.observe(clients: clients)
                        }
                        self.finishStartup(token: token, attempt: attempt)
                        if self.startupSent { return }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    throw RoamError.transport(Self.tmuxNotReadyMessage)
                } catch {
                    guard !Task.isCancelled, let self, self.generation == token, self.startupAttempt == attempt else { return }
                    self.close(); self.fail(error)
                }
            }, onCancel: { cancellation.cancel() })
        }
    }
    func cancelStartup() {
        startupAttempt = UUID(); startupTask?.cancel(); startupTask = nil; startupCancellation?.cancel(); startupCancellation = nil
        startupTimeoutTask?.cancel(); startupTimeoutTask = nil
        startupGate = nil; startupCommand = nil
    }
}
