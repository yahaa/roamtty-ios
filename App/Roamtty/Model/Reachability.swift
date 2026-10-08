import Foundation
import Network
import SwiftUI

enum HostReachability: Sendable {
    case checking, online(Double), offline
}
enum ReachabilityProbe {
    static func measure(address: String, port: Int) async -> HostReachability {
        guard let port = UInt16(exactly: port).flatMap(NWEndpoint.Port.init(rawValue:)) else { return .offline }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: .tcp)
            let reply = ProbeReply(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state { case .ready: reply.finish(online: true); case .failed, .cancelled: reply.finish(online: false); default: break }
            }
            let queue = DispatchQueue.global(qos: .utility)
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { reply.finish(online: false) }
        }
    }
}
private final class ProbeReply {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HostReachability, Never>?
    private let connection: NWConnection
    private let start = DispatchTime.now().uptimeNanoseconds
    init(connection: NWConnection, continuation: CheckedContinuation<HostReachability, Never>) { self.connection = connection; self.continuation = continuation }
    func finish(online: Bool) {
        lock.lock(); guard let continuation else { lock.unlock(); return }; self.continuation = nil; lock.unlock()
        connection.stateUpdateHandler = nil; connection.cancel()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        continuation.resume(returning: online ? .online(elapsed) : .offline)
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
    var body: some View { HStack(spacing: 6) { Circle().fill(tone).frame(width: 8, height: 8); Text(label).font(.caption) }.foregroundStyle(tone) }
}
