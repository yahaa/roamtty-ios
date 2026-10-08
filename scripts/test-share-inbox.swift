import Foundation

@main enum ShareInboxChecks {
    struct Failed: Error { let message: String }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failed(message: message) }
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("share-ledger-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        let first = try ShareImportLedger.commit(into: root, id: id, names: ["a.txt", "b.txt"]) { stage in
            try Data("alpha".utf8).write(to: stage.appendingPathComponent("a.txt"))
            try Data("beta".utf8).write(to: stage.appendingPathComponent("b.txt"))
        }
        try expect(ShareImportLedger.pending(in: root) == first, "Committed imports must survive rediscovery")
        let recovered = try ShareImportLedger.commit(into: root, id: id, names: ["a.txt", "b.txt"]) { _ in
            throw Failed(message: "Committed transactions must not reopen a missing source")
        }
        try expect(recovered == first, "Source cleanup retries must reuse the committed files")
        try ShareImportLedger.acknowledge([first[0]], in: root)
        try expect(ShareImportLedger.pending(in: root) == [first[1]], "Acknowledging one file must preserve remaining files")
        try expect(!FileManager.default.fileExists(atPath: first[0].path), "Acknowledged private copies should be removed")
        try ShareImportLedger.acknowledge([first[1]], in: root)
        try expect(ShareImportLedger.pending(in: root).isEmpty, "Completed imports must not be offered again")
        let retry = try ShareImportLedger.commit(into: root, id: id, names: ["a.txt", "b.txt"]) { _ in
            throw Failed(message: "An acknowledged receipt must prevent duplicate re-import")
        }
        try expect(retry.isEmpty, "Cleanup retries must respect acknowledgements")
        let noSource = try ShareImportLedger.commit(into: root, id: id, names: []) { _ in throw Failed(message: "Acknowledged content must not be read again") }
        try expect(noSource.isEmpty, "Cleanup retries must work even after every source file was removed")

        let failedID = UUID().uuidString
        do {
            _ = try ShareImportLedger.commit(into: root, id: failedID, names: ["partial.txt"]) { stage in
                try Data("partial".utf8).write(to: stage.appendingPathComponent("partial.txt"))
                throw Failed(message: "Interrupted source read")
            }
            throw Failed(message: "Interrupted imports must throw")
        } catch let error as Failed where error.message == "Interrupted source read" { }
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(failedID).path), "A failed import must never publish its destination")
        try expect(ShareImportLedger.pending(in: root).isEmpty, "Partial imports must stay invisible")

        let protectedID = UUID().uuidString
        let protectedFolder = root.appendingPathComponent(protectedID)
        try FileManager.default.createDirectory(at: protectedFolder, withIntermediateDirectories: true)
        let existing = protectedFolder.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: existing)
        do {
            _ = try ShareImportLedger.commit(into: root, id: protectedID, names: ["keep.txt"]) { _ in }
            throw Failed(message: "Unrecognized existing import must not be overwritten")
        } catch is Failed { throw Failed(message: "Unrecognized existing import was accepted") }
        catch { }
        try expect(try Data(contentsOf: existing) == Data("keep".utf8), "Recovery must not delete an existing import")

        do {
            _ = try ShareImportLedger.commit(into: root, id: UUID().uuidString, names: ["../escape"]) { _ in }
            throw Failed(message: "Unsafe file names must be rejected")
        } catch is Failed { throw Failed(message: "Unsafe file name was accepted") }
        catch { }
        try ShareImportLedger.acknowledge([existing], in: root)
        try expect(FileManager.default.fileExists(atPath: existing.path), "Acknowledgement must not remove files without a valid receipt")

        let cancelled = ShareInboxCancellation()
        try expect(cancelled.cancel(), "Cancellation should win before publication")
        var published = false
        do { try cancelled.publish { published = true }; throw Failed(message: "Cancelled publication should throw") }
        catch is Failed { throw Failed(message: "Cancelled publication was accepted") }
        catch { }
        try expect(!published, "Cancelled work must not publish")
        let completed = ShareInboxCancellation()
        try completed.publish { published = true }
        try expect(!completed.cancel(), "A completed atomic publication cannot be reported as cancelled")
        print("Share inbox recovery, acknowledgement, partial-write and cancellation checks passed")
    }
}
