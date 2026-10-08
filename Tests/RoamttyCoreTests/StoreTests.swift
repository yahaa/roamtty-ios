import XCTest
import CNative
@testable import RoamttyCore

final class StoreTests: XCTestCase {
    func testDeletionRemovesJournalButRetainsIndependentTrust() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AppStore(url: root.appendingPathComponent("test.sqlite"))
        let host = Host(name: "Test", address: "example.org", username: "alice")
        try store.saveHost(host)
        var journal = SessionJournal()
        _ = try journal.create(hostID: host.id, mode: .tmux)
        try store.saveJournal(journal)
        let pin = HostPin(endpoint: host.endpoint, algorithm: "ssh-ed25519", key: Data([1, 2, 3]))
        _ = try store.putIfAbsent(pin)
        try store.deleteHost(id: host.id)
        XCTAssertTrue(try store.hosts().isEmpty)
        XCTAssertTrue(try store.loadJournal().records.isEmpty)
        XCTAssertEqual(try store.pin(endpoint: host.endpoint), pin)
    }
    func testFirstWriterWinsAndMismatchCannotReplacePin() throws {
        let store = try AppStore(url: URL(fileURLWithPath: ":memory:"))
        let first = HostPin(endpoint: "[a]:22", algorithm: "ssh-ed25519", key: Data([1]))
        let second = HostPin(endpoint: "[a]:22", algorithm: "ssh-ed25519", key: Data([2]))
        try TrustPolicy(store: store).verify(first) { true }
        XCTAssertThrowsError(try TrustPolicy(store: store).verify(second) { true })
        XCTAssertEqual(try store.putIfAbsent(second), first)
        try store.forgetPin(endpoint: first.endpoint)
        XCTAssertThrowsError(try TrustPolicy(store: store).verify(second) { false })
        XCTAssertNil(try store.pin(endpoint: first.endpoint))
    }
    func testSettingsAndHostRoundTripWithoutSecrets() throws {
        let store = try AppStore(url: URL(fileURLWithPath: ":memory:"))
        var host = Host(name: "中国", address: "::1", username: "test")
        host.savePassword = true
        try store.saveHost(host)
        XCTAssertEqual(try store.hosts(), [host])
        var settings = AppSettings(); settings.language = "en"; settings.theme = .light
        try store.saveSettings(settings)
        XCTAssertEqual(try store.loadSettings(), settings)
    }
    func testFingerprintMatchesKnownSHA256() {
        let pin = HostPin(endpoint: "x", algorithm: "x", key: Data("abc".utf8))
        XCTAssertEqual(pin.fingerprint, "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0")
    }
    func testLegacySQLiteSettingsKeepAllExistingPreferencesAfterUpgrade() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.sqlite")
        let store = try AppStore(url: url)
        let legacy = #"{"theme":"light","language":"en","font":"FiraCode-Regular","fontSize":19,"showHiddenFiles":true,"toolboxPinned":true,"downloadBookmark":"AQID"}"#
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO settings(id,json) VALUES(1,'" + legacy + "')", nil, nil, nil), SQLITE_OK)
        var settings = try store.loadSettings()
        XCTAssertEqual(settings.theme, .light)
        XCTAssertEqual(settings.language, "en")
        XCTAssertEqual(settings.font, "FiraCode-Regular")
        XCTAssertEqual(settings.fontSize, 19)
        XCTAssertTrue(settings.showHiddenFiles)
        XCTAssertTrue(settings.toolboxPinned)
        XCTAssertEqual(settings.downloadBookmark, Data([1, 2, 3]))
        XCTAssertEqual(settings.fileSort, .name)
        XCTAssertFalse(settings.fileSortDescending)
        XCTAssertFalse(settings.codeWrap)
        XCTAssertEqual(settings.codeFontSize, 13, "Preview size is independent of the terminal's size")
        settings.chooseFileSort(.type); settings.fileSortDescending = true
        settings.codeWrap = true; settings.codeFontSize = 17
        try store.saveSettings(settings)
        XCTAssertEqual(try AppStore(url: url).loadSettings(), settings)
    }
    func testMissingAndUnknownSettingsDefaultOnlyTheirOwnFields() throws {
        let data = Data(#"{"theme":"light","language":"en","fontSize":18,"fileSort":"future-order","codeFontSize":90,"codeWrap":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.theme, .light)
        XCTAssertEqual(settings.language, "en")
        XCTAssertEqual(settings.fontSize, 18)
        XCTAssertEqual(settings.font, "JetBrainsMono-Regular")
        XCTAssertEqual(settings.fileSort, .name)
        XCTAssertTrue(settings.codeWrap)
        XCTAssertEqual(settings.codeFontSize, 22)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"codeFontSize":3}"#.utf8)).codeFontSize, 9)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)), AppSettings())
    }
}
