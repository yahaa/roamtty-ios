import Foundation
import Network
import RoamttyCore
import SwiftUI

enum HostReachability: Sendable {
    case checking, online(Double), offline
}
/// Whether a saved host's sshd answers, with the DNS resolution and TCP connection time when it does. No key exchange
/// or login happens. A proxy or VPN app on the phone can accept every TCP connect locally, so the host counts as
/// online only once its SSH identification arrives; waiting for it stays out of the latency.
enum ReachabilityProbe {
    static let timeout: TimeInterval = 3
    static func measure(address: String, port: Int) async -> HostReachability {
        guard let port = UInt16(exactly: port).flatMap(NWEndpoint.Port.init(rawValue:)) else { return .offline }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: .tcp)
            let reply = ProbeReply(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: reply.connected()
                case .failed, .cancelled: reply.finish(online: false)
                default: break
                }
            }
            let queue = DispatchQueue.global(qos: .utility)
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { reply.finish(online: false) }
        }
    }
}
private final class ProbeReply {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HostReachability, Never>?
    private let connection: NWConnection
    private let start = DispatchTime.now().uptimeNanoseconds
    private var connectMs: Double = 0
    private var received = Data()
    init(connection: NWConnection, continuation: CheckedContinuation<HostReachability, Never>) { self.connection = connection; self.continuation = continuation }
    func connected() {
        connectMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        // Our identification goes out first, as ssh does: a transparent proxy that sniffs the first client bytes
        // before dialing out never relays sshd's greeting to a silent client.
        connection.send(content: SSHGreeting.probeIdentification, completion: .contentProcessed { _ in })
        receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.received.append(data) }
            switch SSHGreeting.scan(self.received) {
            case .valid: self.finish(online: true)
            case .invalid: self.finish(online: false)
            case .needMore: if complete || error != nil { self.finish(online: false) } else { self.receive() }
            }
        }
    }
    func finish(online: Bool) {
        lock.lock(); guard let continuation else { lock.unlock(); return }; self.continuation = nil; lock.unlock()
        connection.stateUpdateHandler = nil; connection.cancel()
        continuation.resume(returning: online ? .online(connectMs) : .offline)
    }
}
struct ReachabilityLabel: View {
    @EnvironmentObject var model: AppModel
    let state: HostReachability
    private var tone: Color { switch state { case .checking: return Palette.secondary; case .online: return Palette.success; case .offline: return Palette.danger } }
    private var label: String {
        switch state {
        case .checking: return model.text("检测中", "Checking")
        case .offline: return model.text("离线", "Offline")
        case .online(let ms): return model.text("在线", "Online") + " · " + (ms < 1 ? "<1" : String(format: "%.0f", ms)) + " ms"
        }
    }
    var body: some View {
        // Android colours only the online label; offline and checking text stays secondary beside its dot.
        let online: Bool = { if case .online = state { return true }; return false }()
        HStack(spacing: 6) { Circle().fill(tone).frame(width: 8, height: 8); Text(label).font(.system(size: 12)).foregroundStyle(online ? tone : Palette.secondary) }
    }
}
