import Foundation
import RoamttyCore
import RoamttyTransport

/// The host page's live metrics: sampled every few seconds over the host's shared connection while the page shows.
@MainActor final class HostMonitor: ObservableObject {
    @Published private(set) var metrics: [String: HostMetrics] = [:]
    @Published private(set) var series: [String: HostMetricSeries] = [:]
    @Published private(set) var states: [String: HostMonitorState] = [:]
    @Published private(set) var aiUsage: [String: [HostUsageRange: HostAiUsage]] = [:]
    @Published private(set) var aiUsageLoading: Set<String> = []
    /// The monitor logged in to the host: a moment to look at what else it has, without asking for a login again.
    var onConnected: ((Host) -> Void)?

    private var jobs: [String: TrackedTask] = [:]
    private var aiUsageTasks: [String: Task<Void, Never>] = [:]
    private var aiUsageFetchedAt: [String: [HostUsageRange: Date]] = [:]
    private unowned let environment: ConnectionEnvironment
    private let logins: HostLogins
    private let pool: HostConnectionPool

    init(environment: ConnectionEnvironment, logins: HostLogins, pool: HostConnectionPool) {
        self.environment = environment; self.logins = logins; self.pool = pool
    }

    /// Whether no host is being sampled.
    var idle: Bool { jobs.isEmpty }

    /// `interactive`: the user asked, so the login may ask for a password.
    func start(_ host: Host, interactive: Bool = false) {
        guard environment.foreground, jobs[host.id] == nil else { return }
        let hasSecret = pool.isConnected(host.id) || logins.hasLoginSecret(host)
        guard interactive || hasSecret else { return }
        let token = UUID(), cancellation = TransferCancellation()
        states[host.id] = HostMonitorState(phase: .connecting)
        let task = Task { [weak self] in
            guard let self else { return }
            @MainActor func current() -> Bool { !Task.isCancelled && !cancellation.isCancelled && self.environment.foreground && self.jobs[host.id]?.token == token }
            defer { if self.jobs[host.id]?.token == token { self.jobs.removeValue(forKey: host.id) } }
            var retry = 0, probedDesktop = false
            while current() {
                var samplingConnection: SSHConnection?
                do {
                    let ssh = try await self.pool.connection(for: host.id)
                    guard current() else { return }
                    samplingConnection = ssh
                    self.states[host.id] = HostMonitorState(phase: .connected)
                    // The page's own probe skips logins that need typing; this one rides the login just made.
                    if !probedDesktop {
                        probedDesktop = true
                        self.onConnected?(host)
                        self.loadAiUsage(host, range: .today, force: false)
                    }
                    guard try await self.sample(host, over: ssh, cancellation: cancellation, retry: &retry, current: current) else { return }
                } catch {
                    guard current() else { return }
                    // A channel can observe cancellation after another channel detected a dead socket.
                    // Only that established, dead connection is retryable; cancelling authentication is not.
                    let failure: Error = (error as? RoamError) == .cancelled && samplingConnection?.isConnected == false
                        ? RoamError.transport(self.environment.text("监控连接已关闭", "Monitor connection closed")) : error
                    retry += 1
                    guard let delay = HostMonitorRetry.delay(after: failure, attempt: retry, interactive: host.auth == .interactive) else {
                        self.states[host.id] = HostMonitorState(phase: ConnectionPhase(failure: failure), detail: failure.localizedDescription)
                        return
                    }
                    self.states[host.id] = HostMonitorState(phase: .connecting, reconnecting: true, detail: failure.localizedDescription)
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
            }
        }
        jobs[host.id] = TrackedTask(token: token, task: task, cancellation: cancellation)
    }
    /// Samples the host every three seconds while `current`. False once the collectors ran but returned nothing
    /// usable: the host refused the queries. A lost login (timeout, dropped connection) throws instead, and the
    /// caller reconnects, keeping the last sample.
    private func sample(_ host: Host, over ssh: SSHConnection, cancellation: TransferCancellation, retry: inout Int, current: () -> Bool) async throws -> Bool {
        var series = self.series[host.id] ?? HostMetricSeries()
        series.resetNetworkBaseline()
        while current() {
            let result = try await ssh.run(RemoteCommands.shell(HostMetrics.script), timeout: 10, cancellation: cancellation)
            guard current() else { return true }
            let value = HostMetrics.parse(result.text)
            guard result.status == 0, value.cpuPercent != nil || value.memPercent != nil || !value.disks.isEmpty else {
                metrics.removeValue(forKey: host.id); series.resetNetworkBaseline(); self.series[host.id] = series
                states[host.id] = HostMonitorState(phase: .connected, samplingFailed: true)
                return false
            }
            series.observe(value, timestamp: ProcessInfo.processInfo.systemUptime)
            metrics[host.id] = value
            self.series[host.id] = series
            states[host.id] = HostMonitorState(phase: .connected, sampled: true)
            retry = 0
            try await Task.sleep(for: .seconds(3))
        }
        return true
    }

    /// Loads machine-wide multi-agent AI token usage and active quotas for `range` over the shared SSH connection.
    func loadAiUsage(_ host: Host, range: HostUsageRange, force: Bool = false) {
        guard host.system.lowercased() != "windows" else { return }
        if !force, let fetched = aiUsageFetchedAt[host.id]?[range], Date().timeIntervalSince(fetched) < 30 { return }
        aiUsageTasks[host.id]?.cancel()
        aiUsageLoading.insert(host.id)
        let cancellation = TransferCancellation()
        aiUsageTasks[host.id] = Task { [weak self] in
            defer { self?.aiUsageLoading.remove(host.id) }
            guard let self else { return }
            guard let ssh = try? await self.pool.connection(for: host.id), !Task.isCancelled else { return }
            let cmd = AgentUsage.hostCommand(range: range)
            guard let result = try? await ssh.run(cmd, input: AgentUsage.scriptData, timeout: 15, cancellation: cancellation),
                  result.status == 0, !Task.isCancelled else { return }
            let parsed = AgentUsage.parseHost(result.text, requestedRange: range)
            var byRange = self.aiUsage[host.id] ?? [:]
            byRange[range] = parsed
            self.aiUsage[host.id] = byRange
            var times = self.aiUsageFetchedAt[host.id] ?? [:]
            times[range] = Date()
            self.aiUsageFetchedAt[host.id] = times
        }
    }

    func stop(_ hostID: String) {
        jobs.removeValue(forKey: hostID)?.cancel()
        aiUsageTasks.removeValue(forKey: hostID)?.cancel()
        aiUsageLoading.remove(hostID)
        if states[hostID]?.phase.active == true { states[hostID] = HostMonitorState(phase: .disconnected) }
    }
    func stopAll() { for id in Array(jobs.keys) { stop(id) } }
    /// Drops what was read from a deleted host.
    func forget(_ hostID: String) {
        aiUsageTasks.removeValue(forKey: hostID)?.cancel()
        metrics.removeValue(forKey: hostID); series.removeValue(forKey: hostID); states.removeValue(forKey: hostID)
        aiUsage.removeValue(forKey: hostID); aiUsageFetchedAt.removeValue(forKey: hostID); aiUsageLoading.remove(hostID)
    }
    #if DEBUG
    /// On-device validation shows the metrics it read itself, and takes them down again with nil.
    func showValidationMetrics(_ value: HostMetrics?, for hostID: String) { metrics[hostID] = value }
    #endif
}
