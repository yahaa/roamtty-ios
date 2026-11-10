import Foundation
import RoamttyCore

/// Whether each saved host's sshd answers, as the host cards and the session list show it.
@MainActor final class HostReachabilityTracker: ObservableObject {
    @Published private var status: [String: HostReachability] = [:]
    /// When each host's shown reachability was measured. Read by the model only, so not published: a change
    /// redraws nothing.
    private var measuredAt: [String: Date] = [:]
    private unowned let environment: ConnectionEnvironment

    init(environment: ConnectionEnvironment) { self.environment = environment }

    subscript(hostID: String) -> HostReachability? { status[hostID] }
    func checkedAt(_ hostID: String) -> Date? { measuredAt[hostID] }

    func probe(_ hosts: [Host]) async {
        for host in hosts where status[host.id] == nil { status[host.id] = .checking }
        await withTaskGroup(of: (String, HostReachability).self) { group in
            for host in hosts { group.addTask { (host.id, await ReachabilityProbe.measure(address: host.hostname, port: host.port)) } }
            for await (id, result) in group { if !Task.isCancelled, environment.host(id) != nil { status[id] = result; measuredAt[id] = Date() } }
        }
    }
    #if DEBUG
    /// On-device validation takes down what it measured of its fixture host.
    func forgetValidationHost(_ hostID: String) { status.removeValue(forKey: hostID) }
    #endif
}
