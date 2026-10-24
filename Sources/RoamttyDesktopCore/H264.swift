import Foundation

/// Annex-B H.264 helpers shared by the VideoToolbox path and the Linux tests.
/// Port of Android `VideoDecoder.nalUnits` (roamtty #218).
public enum H264 {
    /// One NAL unit with its start code still attached, and its type (low 5 bits of the header).
    public struct NAL: Equatable, Sendable {
        public let bytes: [UInt8]
        public let type: Int
        public init(bytes: [UInt8], type: Int) { self.bytes = bytes; self.type = type }
        public var isSPS: Bool { type == 7 }
        public var isPPS: Bool { type == 8 }
        /// Payload after the 3- or 4-byte start code.
        public var payload: ArraySlice<UInt8> {
            if bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 1 { return bytes[4...] }
            if bytes.count >= 3, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1 { return bytes[3...] }
            return bytes[...]
        }
    }

    /// The Annex-B NAL units of an access unit, each with its start code, and its type.
    public static func nalUnits(_ data: [UInt8], offset: Int = 0) -> [NAL] {
        guard offset < data.count else { return [] }
        var starts: [Int] = []
        var i = offset
        while i + 3 <= data.count {
            if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
                starts.append(i > offset && data[i - 1] == 0 ? i - 1 : i)
                i += 3
            } else { i += 1 }
        }
        return starts.enumerated().map { n, start in
            let end = n + 1 < starts.count ? starts[n + 1] : data.count
            let bytes = Array(data[start..<end])
            let header = (bytes.firstIndex(of: 1).map { $0 + 1 }) ?? bytes.count
            let type = Int(bytes.indices.contains(header) ? bytes[header] & 0x1F : 0)
            return NAL(bytes: bytes, type: type)
        }
    }

    /// Length-prefixed (AVCC) form of the access unit, for `CMSampleBuffer` / VideoToolbox.
    public static func avcc(_ data: [UInt8], offset: Int = 0) -> [UInt8] {
        var out: [UInt8] = []
        for nal in nalUnits(data, offset: offset) {
            let payload = Array(nal.payload)
            let n = UInt32(payload.count)
            // Each byte stores only its part of the 32-bit big-endian length.
            // Checked UInt8 conversion traps for ordinary video NALs larger than 255 bytes.
            out += [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                    UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]
            out += payload
        }
        return out
    }

    public static func spsPps(_ data: [UInt8], offset: Int = 0) -> (sps: [UInt8]?, pps: [UInt8]?) {
        let units = nalUnits(data, offset: offset)
        return (units.first { $0.isSPS }?.bytes, units.first { $0.isPPS }?.bytes)
    }
}
