import Foundation

/// Where decoded frames go for display. On iOS this is an `AVSampleBufferDisplayLayer` (or a
/// `CVPixelBuffer` sink); tests use a recorder. The decoder calls `session.decoded` /
/// `session.rendered` / `session.needKeyframe`.
public protocol DesktopVideoDisplay: AnyObject {
    /// A decoded access unit ready to show; `sample` is AVCC (length-prefixed) when the VT path
    /// produced it, else the raw Annex-B bytes with SPS/PPS still attached on a keyframe.
    func present(frame: Int64, keyframe: Bool, width: Int, height: Int, annexB: [UInt8], offset: Int, avcc: [UInt8])
    func flush()
}

/// H.264 decode for the desktop (plan §8): hardware when available, one access unit per input,
/// every output rendered at once. Port of Android `VideoDecoder` (roamtty #218) without MediaCodec:
/// the real decoder sits behind `DesktopVideoDisplay` (VideoToolbox on iOS), and this class owns the
/// queue, keyframe gating, size changes and the need-keyframe signal so the logic is Linux-testable.
public final class DesktopVideoDecoder: DesktopVideoSink, @unchecked Sendable {
    public weak var session: DesktopSession?
    public weak var display: DesktopVideoDisplay?

    private let lock = NSLock()
    private var pending: [Video] = []
    private var size = (0, 0)
    private var ready = false
    private var _name = ""
    private var _decoded: Int64 = 0
    /// When set, frames are handed to `display` after this conversion; nil keeps Annex-B only.
    public var makeAvcc: (([UInt8], Int) -> [UInt8])? = H264.avcc

    public var decoderName: String { lock.lock(); defer { lock.unlock() }; return _name }
    public var decodedFrames: Int64 { lock.lock(); defer { lock.unlock() }; return _decoded }

    public init(name: String = "pending") { _name = name }

    /// The display is attached (or replaced); the next keyframe reconfigures.
    public func attach(name: String) {
        lock.lock(); _name = name; ready = true; size = (0, 0); pending.removeAll(); lock.unlock()
        session?.needKeyframe()
    }

    public func detach() {
        lock.lock(); ready = false; size = (0, 0); pending.removeAll(); lock.unlock()
        display?.flush()
    }

    public func submit(_ video: Video) {
        lock.lock()
        guard ready else { lock.unlock(); return }
        // Only a keyframe can start a stream; later frames wait for one.
        if !readyFormat(for: video) {
            if !video.keyframe { lock.unlock(); return }
            // A keyframe that cannot start (no SPS/PPS) asks again.
            if H264.spsPps(video.data, offset: video.offset).sps == nil {
                lock.unlock(); session?.needKeyframe(); return
            }
            size = (video.width, video.height)
        }
        pending.append(video)
        // A backlog means the decoder fell behind: drop to the newest keyframe if one is queued.
        if pending.count > 4, let lastKey = pending.lastIndex(where: { $0.keyframe }), lastKey > 0 {
            pending.removeFirst(lastKey)
        }
        let batch = pending; pending.removeAll(); lock.unlock()
        for v in batch { emit(v) }
    }

    private func readyFormat(for video: Video) -> Bool {
        size != (0, 0) && !(video.keyframe && size != (video.width, video.height))
    }

    private func emit(_ video: Video) {
        let avcc = makeAvcc?(video.data, video.offset) ?? []
        display?.present(frame: video.frame, keyframe: video.keyframe, width: video.width, height: video.height,
                         annexB: video.data, offset: video.offset, avcc: avcc)
        let now = UdpLink.monotonicUs()
        lock.lock(); _decoded += 1; lock.unlock()
        session?.decoded(frame: video.frame, decodedUs: now)
        // Without a real display's render callback, rendered ≈ decoded (LatencyMeter still works).
        session?.rendered(frame: video.frame, renderedUs: now)
    }

    /// A display that drew `frame` at `renderedUs` (monotonic µs); replaces the approximate stamp.
    public func didRender(frame: Int64, renderedUs: Int64) {
        session?.rendered(frame: frame, renderedUs: renderedUs)
    }

    public func reset() {
        lock.lock(); size = (0, 0); pending.removeAll(); lock.unlock()
        display?.flush()
        session?.needKeyframe()
    }

    public func close() { detach(); session = nil; display = nil }
}

/// Preferences for the remote desktop (Android `DesktopSettings`), pure data; the app persists them.
public struct DesktopPreferences: Equatable, Sendable {
    /// Experimental until the feature is stable: off by default; session cards show no button while off.
    public var enabled = false
    /// How long a desktop left in the background stays connected, in minutes: 5, 10 or 30.
    public var keepAliveMinutes = 10
    /// The latency, frame rate and bit rate over the picture's top left corner.
    public var showStats = false
    /// Debug: a base URL that replaces the pinned release.
    public var pluginBaseUrl = ""
    /// Debug: where UDP goes instead of the host's address.
    public var udpHostOverride = ""
    /// Debug: share of UDP datagrams dropped both ways.
    public var testLoss = 0.0

    public static let keepAliveOptions = [5, 10, 30]
    public static let qualities = ["auto", "smooth", "clear", "original"]
    public static let fpsOptions = [30, 60, 90, 120]

    public init() {}

    public mutating func clamp() {
        if !Self.keepAliveOptions.contains(keepAliveMinutes) { keepAliveMinutes = 10 }
        testLoss = min(1, max(0, testLoss))
        pluginBaseUrl = pluginBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        udpHostOverride = udpHostOverride.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Per-host desktop preferences (pointer mode, quality, fps, lock on close).
public struct DesktopHostPreferences: Equatable, Sendable {
    public var pointerMode: PointerMode = .touch
    public var quality = "auto"
    public var fps = 60
    public var lockOnClose = false
    public init() {}
    public init(pointerMode: PointerMode = .touch, quality: String = "auto", fps: Int = 60, lockOnClose: Bool = false) {
        self.pointerMode = pointerMode; self.quality = quality; self.fps = fps; self.lockOnClose = lockOnClose
    }
}

/// Whether a host's stored `system` has a pinned plugin build (Android `desktopSupported`).
public enum DesktopSupport {
    public static func osSupported(_ system: String, targets: Set<String>) -> Bool {
        switch system.uppercased() {
        case "MACOS": return targets.contains("macos-universal")
        case "WINDOWS": return targets.contains { $0.hasPrefix("windows-") }
        default:
            // Linux and its distros: any linux-* target.
            return targets.contains { $0.hasPrefix("linux-") } && system.uppercased() != "UNKNOWN" && system.uppercased() != "OTHER"
        }
    }

    public static func osSupported(_ system: String, manifest: PluginManifest) -> Bool {
        osSupported(system, targets: Set(manifest.targets.keys))
    }

    /// The `DesktopButton.derive` `os` argument: MACOS / WINDOWS / LINUX.
    public static func buttonOS(_ system: String) -> String {
        switch system.uppercased() {
        case "MACOS": return "MACOS"
        case "WINDOWS": return "WINDOWS"
        default: return "LINUX"
        }
    }
}
