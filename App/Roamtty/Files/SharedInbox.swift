import Foundation

enum SharedInbox {
    static let group = "group.com.roamtty.shared"
    private static var imports: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           let name = ProcessInfo.processInfo.environment["ROAMTTY_STORAGE_NAME"],
           name.hasPrefix("UI-"), !name.contains("/"), !name.contains("\\") {
            // Keep each test's recovered queue separate from previous runs and real imports.
            return documents.appendingPathComponent("UITestImports", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        }
        #endif
        return documents.appendingPathComponent("Imports", isDirectory: true)
    }
    static func acknowledge(_ urls: [URL]) throws { try ShareImportLedger.acknowledge(urls, in: imports) }
    static func consume() -> [URL] {
        _ = ShareInboxStore.consume(into: imports)
        guard let shared = ShareInboxStore.groupContainer?.appendingPathComponent("Inbox", isDirectory: true), let transactions = try? FileManager.default.contentsOfDirectory(at: shared, includingPropertiesForKeys: nil) else { return ShareImportLedger.pending(in: imports) }
        for transaction in transactions {
            guard FileManager.default.fileExists(atPath: transaction.appendingPathComponent(".ready").path), let files = try? FileManager.default.contentsOfDirectory(at: transaction, includingPropertiesForKeys: nil) else { continue }
            let members = files.filter { $0.lastPathComponent != ".ready" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            do {
                try ShareImportLedger.commit(into: imports, id: transaction.lastPathComponent, names: members.map(\.lastPathComponent)) { stage in
                    for file in members { try FileManager.default.copyItem(at: file, to: stage.appendingPathComponent(file.lastPathComponent)) }
                }
                // Local receipt commits before source cleanup; repeated consumption is idempotent.
                try? FileManager.default.removeItem(at: transaction)
            } catch { /* A partial import remains unpublished, and the source remains retryable. */ }
        }
        return ShareImportLedger.pending(in: imports)
    }
    static func copyIncoming(_ url: URL) throws -> URL {
        let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try ShareImportLedger.commit(into: imports, id: UUID().uuidString, names: [url.lastPathComponent]) { stage in
            try FileManager.default.copyItem(at: url, to: stage.appendingPathComponent(url.lastPathComponent))
        }
        guard let destination = values.first else { throw NSError(domain: "RoamttyShare", code: 1, userInfo: [NSLocalizedDescriptionKey: "Shared file could not be imported"]) }
        return destination
    }
}
