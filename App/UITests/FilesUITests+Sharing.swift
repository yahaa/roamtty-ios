import XCTest

/// Files shared into the app, and the landscape layouts.
extension FilesUITests {
    func testSharedUploadRejectsCollisionAndUsesChosenDirectory() throws {
        _ = try openTerminal()
        let base = fixturePath("upload"), ready = "UPLOAD_READY_" + shortID()
        let original = "ORIGINAL_" + shortID()
        let create = "mkdir -m 700 " + quote(base) + " && mkdir " + quote(base + "/destination")
            + " && " + write(original + "\n", to: base + "/collision.txt") + " && " + emit(ready)
        let surface = try runCommand(create); waitForOutput(ready, surface: surface)
        openRemoteFolder(base); entry(base + "/collision.txt").tap()
        XCTAssertTrue(app.textViews["file-code-preview"].waitForExistence(timeout: 15))
        app.buttons["preview-download"].tap()
        waitUntilCompleted(app.staticTexts["transfer-status-download-collision.txt"])
        shareDownloadedFile("collision.txt")
        for identifier in ["transfer-done", "preview-done", "files-picker-done"] {
            XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 8)); app.buttons[identifier].tap()
        }
        waitUntilGone(app.buttons["files-picker-done"])
        XCUIDevice.shared.press(.home); app.activate()
        let host = app.buttons["share-host-ui-live-host"]
        XCTAssertTrue(host.waitForExistence(timeout: 15)); host.tap()
        let destination = app.textFields["files-upload-destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 15)); replace(destination, with: base)
        replace(app.textFields["files-upload-name-0"], with: "collision.txt")
        app.buttons["files-start-upload"].tap()
        let error = app.staticTexts["files-upload-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10)); XCTAssertTrue(error.label.contains("already exists"))
        XCTAssertTrue(destination.exists)
        XCTAssertFalse(app.staticTexts["transfer-status-upload-collision.txt"].exists)
        capture("Existing remote file rejected before upload")

        let collisionDetail = error.label
        replace(destination, with: base + "/missing-folder")
        app.buttons["files-start-upload"].tap()
        expectation(for: NSPredicate(format: "exists == true AND label != %@", collisionDetail), evaluatedWith: error)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(destination.exists)
        XCTAssertFalse(app.staticTexts["transfer-status-upload-collision.txt"].exists)
        app.buttons["files-upload-browse"].tap()
        let folder = app.textFields["files-upload-folder-path"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10)); replace(folder, with: base + "/destination"); folder.typeText("\n")
        let useFolder = app.buttons["files-upload-use-folder"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: useFolder); waitForExpectations(timeout: 15)
        XCTAssertEqual(folder.value as? String, base + "/destination"); useFolder.tap()
        XCTAssertTrue(destination.waitForExistence(timeout: 5)); XCTAssertEqual(destination.value as? String, base + "/destination")
        replace(app.textFields["files-upload-name-0"], with: "uploaded.txt")
        app.buttons["files-start-upload"].tap()
        waitUntilCompleted(app.staticTexts["transfer-status-upload-uploaded.txt"])
        capture("Shared upload completed in chosen remote folder")
        app.buttons["transfer-done"].tap()
        waitUntilGone(app.buttons["transfer-done"])
        XCTAssertTrue(menu("files-options").waitForExistence(timeout: 8))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // Verify the receipt stays acknowledged across process restart before
        // checking the remote bytes, so relaunch cannot rediscover a completed upload.
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["home-tab-sessions"].waitForExistence(timeout: 10))
        let incoming = app.navigationBars.matching(NSPredicate(format: "identifier == '共享文件' OR identifier == 'Shared files'")).firstMatch
        let noRepeatedReceipt = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: incoming)
        noRepeatedReceipt.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [noRepeatedReceipt], timeout: 3), .completed,
                       "A completed shared upload must remain acknowledged after relaunch")
        let session = homeSessionCards().firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 8)); session.tap()
        let verified = "UPLOAD_CHECK_" + shortID()
        let check = "test \"$(cat " + quote(base + "/collision.txt") + ")\" = " + quote(original)
            + " && cmp -s " + quote(base + "/collision.txt") + " " + quote(base + "/destination/uploaded.txt") + " && " + emit(verified)
        let checked = try runCommand(check); waitForOutput(verified, surface: checked)
        try removeFixture(base)
    }

    func openRemoteFolder(_ path: String) {
        openTools(); app.buttons["download-file"].tap()
        // Direct download starts with selection enabled; management and preview need normal row actions.
        filesMenu("files-select")
        searchRemote(path)
        let folder = entry(path)
        XCTAssertTrue(folder.waitForExistence(timeout: 15)); folder.tap()
        XCTAssertTrue(app.buttons["files-breadcrumb-" + path].waitForExistence(timeout: 15), "Wait for the requested directory listing before performing mutations")
        XCTAssertTrue(menu("files-options").waitForExistence(timeout: 8), "Opening a search result folder must restore the browser toolbar")
        XCTAssertTrue(app.buttons["files-picker-done"].exists, "Opening a folder must leave the picker dismissible")
    }
    func closeRemoteBrowser() {
        let done = app.buttons["files-picker-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 8)); done.tap(); waitUntilGone(done)
    }
    func searchRemote(_ text: String) {
        let search = app.searchFields.firstMatch
        if !search.exists { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5)); replace(search, with: text)
        search.typeText("\n")
    }
    func entry(_ path: String) -> XCUIElement { app.buttons["files-entry-" + path] }
    func menu(_ identifier: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: identifier).firstMatch }
    func waitUntilCompleted(_ status: XCUIElement) {
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "label == '已完成' OR label == 'Completed'"), evaluatedWith: status)
        waitForExpectations(timeout: 30)
    }
    func waitUntilGone(_ element: XCUIElement) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element); waitForExpectations(timeout: 10)
    }
    func showTerminalKeyboard() {
        if app.keyboards.count == 0 {
            // As on Android, a tap on the cursor's line opens the keyboard.
            let surface = app.descendants(matching: .any)["terminal-surface"].firstMatch
            let cursor = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cursor-'")).firstMatch
            XCTAssertTrue(cursor.waitForExistence(timeout: 6))
            surface.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: surface.frame.width * 0.3, dy: cursor.frame.midY - surface.frame.minY)).tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }
    func shareDownloadedFile(_ name: String) {
        let share = app.buttons["transfer-share-" + name]
        XCTAssertTrue(share.waitForExistence(timeout: 10)); share.tap()
        let target = app.cells.matching(NSPredicate(format: "label == 'Roamtty'")).firstMatch
        if !target.waitForExistence(timeout: 4) {
            let more = app.cells.matching(NSPredicate(format: "label == 'More' OR label == '更多' OR label == 'More…'")).firstMatch
            XCTAssertTrue(more.exists); more.tap()
        }
        XCTAssertTrue(target.waitForExistence(timeout: 8)); target.tap()
        let save = app.buttons["share-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10)); save.tap(); waitUntilGone(save)
    }
    func removeFixture(_ path: String) throws {
        XCTAssertTrue(path.hasPrefix("/tmp/roamtty-ios-ui-"))
        let marker = "CLEANED_" + shortID()
        let surface = try runCommand("rm -rf -- " + quote(path) + " && " + emit(marker))
        waitForOutput(marker, surface: surface)
    }
    func shortID() -> String { String(UUID().uuidString.prefix(8)) }
    func fixturePath(_ purpose: String) -> String { "/tmp/roamtty-ios-ui-" + purpose + "-" + shortID() }
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    func write(_ content: String, to path: String) -> String { "printf '%s' " + quote(Data(content.utf8).base64EncodedString()) + " | base64 -d > " + quote(path) }
    // The full marker never appears in the echoed command, so it proves remote execution.
    func emit(_ marker: String) -> String {
        let middle = marker.index(marker.startIndex, offsetBy: marker.count / 2)
        return "printf '%s' " + quote(String(marker[..<middle])) + "; printf '%s\\n' " + quote(String(marker[middle...]))
    }

    /// In landscape the launch sheet and the file browser use the whole screen, like the host page there: one flat bar
    /// on top, the folders in full height beside a side column with the recent folders, the pickers and the button,
    /// and the files under a bar that carries the path, the sort, the search and the menu in place of the system ones.
    func testLandscapeLaunchSheetAndFilesUseTheWholeScreen() throws {
        try openHost()
        XCTAssertTrue(app.buttons["host-detail-terminal"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for _ in 0..<10 where app.windows.firstMatch.frame.width < app.windows.firstMatch.frame.height { sleep(1) }
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height)

        app.buttons["host-detail-agent"].tap()
        let folders = app.descendants(matching: .any)["launch-folders"]
        XCTAssertTrue(folders.waitForExistence(timeout: 15))
        let close = app.buttons["launch-cancel"], launch = app.buttons["launch-session"]
        XCTAssertTrue(close.isHittable && launch.isHittable, "The bar and the button are both on screen")
        XCTAssertLessThan(close.frame.maxY, folders.frame.minY, "The bar is over the folders")
        XCTAssertLessThan(folders.frame.maxX, launch.frame.minX, "The button sits in the side column")
        XCTAssertLessThan(launch.frame.maxY, window.maxY, "The button is not cut off")
        XCTAssertGreaterThan(folders.frame.height, window.height * 0.6, "The folders take the height")
        capture("Launch sheet — landscape")
        close.tap()

        XCTAssertFalse(app.buttons["host-detail-continue"].exists, "No 继续 on the host page")

        app.buttons["host-detail-files"].tap()
        let search = app.textFields["files-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        XCTAssertFalse(app.navigationBars.firstMatch.exists, "The system bar is hidden in landscape")
        XCTAssertFalse(app.searchFields.firstMatch.exists, "The search is in the bar, not the system's")
        for id in ["files-back", "files-sort", "files-options"] {
            XCTAssertLessThan(abs(app.descendants(matching: .any)[id].firstMatch.frame.midY - search.frame.midY), 3, "\(id) is in the bar")
        }
        capture("Files — landscape")
        app.buttons["files-back"].tap()
        XCTAssertTrue(app.buttons["host-detail-files"].waitForExistence(timeout: 5), "Back returns to the host")
    }
}
