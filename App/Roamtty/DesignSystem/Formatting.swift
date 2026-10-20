import Foundation

func formattedBytes(_ bytes: Int64?) -> String {
    guard let bytes else { return "—" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
}
func formattedPercent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
