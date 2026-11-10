import Foundation
import Network
import RoamttyDesktopCore

/// Tells when the phone's traffic moves to another network, which a remote desktop's link has to follow.
@MainActor final class DesktopNetworkMonitor {
    private var monitor: NWPathMonitor?

    /// Starts watching, once; `onChange` runs on the main queue for every change after the first reading.
    func start(onChange: @escaping @MainActor (NetworkChange) -> Void) {
        // Already running.
        if monitor != nil { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        // Updates come one at a time on this serial queue, the only place `last` is touched.
        let queue = DispatchQueue(label: "roamtty.desktop.path", qos: .utility)
        final class Last: @unchecked Sendable { var interface: String?? }
        let last = Last()
        monitor.pathUpdateHandler = { path in
            let current = Self.defaultInterface(path)
            let change = NetworkChange.between(last.interface, current)
            last.interface = .some(current)
            guard let change else { return }
            DispatchQueue.main.async { onChange(change) }
        }
        monitor.start(queue: queue)
    }

    /// The interface the traffic goes out on ("cellular:pdp_ip0"), nil without one. A VPN's tunnel
    /// (Tailscale's utun, type other) is not it: its updates leave the network the same.
    nonisolated static func defaultInterface(_ path: NWPath) -> String? {
        guard path.status == .satisfied else { return nil }
        let kinds: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet]
        guard let i = path.availableInterfaces.first(where: { kinds.contains($0.type) }) else { return nil }
        return "\(i.type):\(i.name)"
    }
}
