import Foundation

public struct InputQueue {
    private var items: [Data] = []
    public private(set) var generation = 0
    public init() {}
    public mutating func enqueue(_ data: Data) -> Bool {
        guard data.count <= Self.itemLimit else { return false }
        // A write joins the one still waiting, so a burst of small writes takes one place: dictation revises its text
        // with one write per deleted character (issue #108). Items stay within the limit, so the bound is unchanged.
        if let last = items.indices.last, items[last].count + data.count <= Self.itemLimit {
            items[last].append(data); return true
        }
        guard items.count < 64 else { return false }
        items.append(data); return true
    }
    static let itemLimit = 256 * 1024
    public mutating func pop() -> Data? { items.isEmpty ? nil : items.removeFirst() }
    public mutating func reset() { items.removeAll(keepingCapacity: true); generation += 1 }
}
