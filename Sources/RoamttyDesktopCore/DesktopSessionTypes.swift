import Foundation

/// What logging in gave: a host to run the desktop on, or why not.
public enum DesktopLogin {
    case host(DesktopHost)
    /// The credentials could not be read (Android: 无法读取凭据…).
    case noCredentials
    /// The host refused or could not be reached; `connecting` when the login dropped midway (a live
    /// desktop then recovers instead of failing). `message` is the SSH layer's own, nil for 无法连接服务器.
    case failed(message: String?, connecting: Bool)
}

/// Where VIDEO frames go: the VideoToolbox decoder on iOS (phase 3), a recorder in tests. The decoder calls
/// back `DesktopSession.decoded`, `rendered` and `needKeyframe`.
public protocol DesktopVideoSink: AnyObject {
    func submit(_ video: Video)
    func reset()
    var decoderName: String { get }
    var decodedFrames: Int64 { get }
}

public extension DesktopVideoSink {
    func reset() {}
}

/// The cursor the plugin reports, in native pixels of the selected display; `shape` nil until its image came.
public struct RemoteCursor: Equatable, Sendable {
    public let x: Int, y: Int, visible: Bool
    public let shape: CursorImage?
}

/// RGBA pixels, row by row, and the hot spot.
public struct CursorImage: Equatable, Sendable {
    public let width: Int, height: Int, hotX: Int, hotY: Int
    public let rgba: [UInt8]
}

/// What the network badge and the statistics show.
public struct DesktopStats: Equatable, Sendable {
    public var rttMs: Int?
    public var fps = 0, kbps = 0, width = 0, height = 0
    public var frames: Int64 = 0
    public var decoder = "", link = "SSH", encoder = ""
    /// UDP only: share of shards lost before FEC, frames FEC rebuilt, frames lost outright.
    public var lossPercent: Double?
    public var fecRecovered: Int64 = 0, lostFrames: Int64 = 0
    /// Where the last second's frames spent their time, host to screen.
    public var latency: LatencyMeter.Latency?
    /// Sound waiting to be heard on the phone, while sound plays.
    public var audioMs: Int?
    public init() {}
}

/// What `NWPathMonitor` said, as `DesktopSession.networkChanged` needs it.
public enum NetworkChange: Sendable, Equatable {
    /// Another interface carries the traffic, or there is one again after none.
    case newInterface
    /// The same interface, something else about the path changed.
    case pathUpdate

    /// `previous` and `current`: the interface the default route uses ("wifi:en0"), nil while there is
    /// none. Nil for the first report: that is the network the session already uses.
    public static func between(_ previous: String??, _ current: String?) -> NetworkChange? {
        guard let previous else { return nil }
        return previous == current ? .pathUpdate : .newInterface
    }
}
