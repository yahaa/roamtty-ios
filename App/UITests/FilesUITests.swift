import XCTest

final class FilesUITests: RoamttyLiveUITestCase {
    let tinyPNG = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGP4z8DAAMIM/4EAAB/uBfsL2WiLAAAAAElFTkSuQmCC"

    func testNativePhotoPickerUploadsPNGAndInsertsWithoutEnter() throws {
        let surface = try openTerminal()
        // A saved host edit must not retarget file actions from its already-connected
        // terminal. Port 1 cannot serve the fixture; all following uploads and remote
        // PNG checks must keep using the initiating session's original SSH connection.
        leaveTerminal()
        hostMenu("host-detail-edit")
        let port = app.textFields["host-port"]
        XCTAssertTrue(port.waitForExistence(timeout: 5)); replace(port, with: "1")
        app.buttons["save-host"].tap()
        waitUntilGone(app.buttons["save-host"])
        let existingSession = homeSessionCards().firstMatch
        XCTAssertTrue(existingSession.waitForExistence(timeout: 8))
        let sessionIdentifier = existingSession.identifier
        let retainedSession = app.descendants(matching: .any)[sessionIdentifier].firstMatch
        XCTAssertTrue(sessionConnected(sessionIdentifier), "Editing the saved endpoint must retain the original connected session")
        retainedSession.tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 8))
        XCTAssertTrue(phase("已连接").waitForExistence(timeout: 8))
        let submitted = "PHOTO_SENT_" + shortID()
        typeIntoTerminal(emit(submitted) + "; :")
        app.buttons.matching(NSPredicate(format: "label == '收起' OR label == 'Hide'")).firstMatch.tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 8))

        openTools(); app.buttons["select-image"].tap()
        // The dedicated simulator contains a real PNG seeded using `simctl addmedia`.
        let photos = app.scrollViews["photosView_content_scroll_view"]
        XCTAssertTrue(photos.waitForExistence(timeout: 15), "The native Photos picker must open")
        let photo = photos.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "The native Photos picker must expose seeded media")
        capture("Native Photos picker")
        // Photos exposes the visible thumbnail but returns an invalid AX hit point.
        // Tap its verified on-screen center, then require Done to become enabled.
        let center = CGPoint(x: photo.frame.midX, y: photo.frame.midY)
        XCTAssertGreaterThan(photo.frame.width, 0); XCTAssertGreaterThan(photo.frame.height, 0)
        XCTAssertTrue(photos.frame.contains(center)); XCTAssertTrue(app.frame.contains(center))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let add = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add' OR label BEGINSWITH '添加' OR label == 'Done' OR label == '完成'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: add)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        add.tap()

        // As on Android, a progress dialog follows the upload and gives way to a short top notice once the path is in.
        let dialog = app.descendants(matching: .any)["image-insert-dialog"]
        // The notice lives two seconds, so watch for it directly rather than after the dialog's slower poll.
        XCTAssertTrue(app.descendants(matching: .any)["top-notice"].waitForExistence(timeout: 30))
        XCTAssertFalse(dialog.exists)
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        // The inserted path names the upload: /tmp/roamtty-img-<UUID>.png.
        var path = ""
        expectation(for: NSPredicate { object, _ in
            guard let value = (object as? XCUIElement)?.value as? String,
                  let range = value.filter({ !$0.isWhitespace }).range(of: #"/tmp/roamtty-img-[0-9A-Fa-f-]{36}\.png"#, options: .regularExpression) else { return false }
            path = String(value.filter { !$0.isWhitespace }[range]); return true
        }, evaluatedWith: surface)
        waitForExpectations(timeout: 40)
        XCTAssertNotNil(UUID(uuidString: String(path.dropFirst("/tmp/roamtty-img-".count).dropLast(4))))
        let prematureSubmit = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", submitted), object: surface)
        prematureSubmit.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [prematureSubmit], timeout: 2), .completed, "Attaching an image must not press Enter")
        capture("PNG path inserted without submitting")

        showTerminalKeyboard()
        surface.typeText("\n")
        waitForOutput(submitted, surface: surface)
        let verified = "PNG_VALID_" + shortID()
        let verifiedSurface = try runCommand("test \"$(od -An -tx1 -N8 " + quote(path) + " | tr -d ' \\n')\" = 89504e470d0a1a0a && " + emit(verified))
        waitForOutput(verified, surface: verifiedSurface)
        let removed = "PNG_REMOVED_" + shortID()
        let cleaned = try runCommand("rm -- " + quote(path) + " && " + emit(removed))
        waitForOutput(removed, surface: cleaned)

        // The retained tmux card must reconnect to the same original host, even
        // though the edited saved profile still has its deliberately invalid port.
        try detachTerminal()
        _ = homeSessionCards()
        XCTAssertTrue(retainedSession.waitForExistence(timeout: 8)); retainedSession.tap()
        let reconnect = app.buttons["terminal-reconnect"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 8)); reconnect.tap()
        XCTAssertTrue(phase("已连接").waitForExistence(timeout: 20))
        let resumed = "ORIGINAL_SESSION_" + shortID()
        let replacementSurface = try runCommand(emit(resumed))
        waitForOutput(resumed, surface: replacementSurface)
        capture("Original session reconnected after the saved endpoint changed")
    }

    func testRemoteManagementHiddenFuzzySearchAndBatchDownloads() throws {
        _ = try openTerminal()
        let base = fixturePath("files")
        let ready = "FILES_READY_" + shortID()
        let create = "mkdir -m 700 " + quote(base) + " && mkdir " + quote(base + "/nested-one") + " " + quote(base + "/nested-two")
            + " && " + write("one\n", to: base + "/nested-one/result.txt")
            + " && " + write("two\n", to: base + "/nested-two/result.txt")
            + " && " + write("hidden\n", to: base + "/.hidden.txt") + " && " + emit(ready)
        let surface = try runCommand(create); waitForOutput(ready, surface: surface)
        openRemoteFolder(base)

        menu("files-options").tap(); app.buttons["files-new-folder"].tap()
        let createAlert = app.alerts.firstMatch
        XCTAssertTrue(createAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(["新建文件夹", "New folder"].contains(createAlert.label), "Folder creation must open its native confirmation alert")
        // Native SwiftUI alert text fields do not retain their SwiftUI IDs on this runtime.
        let folderName = createAlert.textFields.firstMatch
        XCTAssertTrue(folderName.waitForExistence(timeout: 5)); folderName.typeText("created-folder")
        createAlert.buttons.matching(identifier: "files-create-folder").firstMatch.tap()
        let created = entry(base + "/created-folder")
        XCTAssertTrue(created.waitForExistence(timeout: 10)); created.press(forDuration: 0.8)
        app.buttons["files-action-rename"].tap()
        let renameAlert = app.alerts.firstMatch
        XCTAssertTrue(renameAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(["重命名", "Rename"].contains(renameAlert.label), "Renaming must open its native confirmation alert")
        let rename = renameAlert.textFields.firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        XCTAssertEqual(rename.value as? String, "created-folder")
        // UIAlertController already focuses this field at the end or with its
        // contents selected. Preserve that focus instead of opening its transient
        // edit menu, whose accessibility representation can disappear mid-tap.
        rename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "created-folder".utf16.count))
        rename.typeText("renamed-folder")
        XCTAssertEqual(rename.value as? String, "renamed-folder")
        renameAlert.buttons.matching(identifier: "files-rename-save").firstMatch.tap()
        let renamed = entry(base + "/renamed-folder")
        XCTAssertTrue(renamed.waitForExistence(timeout: 10)); XCTAssertFalse(created.exists)

        entry(base + "/nested-one").press(forDuration: 0.8)
        app.buttons["files-action-download"].tap()
        waitUntilCompleted(app.staticTexts["transfer-status-download-nested-one"])
        XCTAssertTrue(app.buttons["transfer-share-nested-one"].exists, "The recursive directory must be published as a shareable local artifact")
        app.buttons["transfer-done"].tap()
        XCTAssertTrue(renamed.waitForExistence(timeout: 8)); renamed.press(forDuration: 0.8)
        app.buttons["files-action-delete"].tap()
        let delete = app.buttons.matching(identifier: "files-delete-confirm").firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); delete.tap()
        waitUntilGone(renamed)

        let hidden = entry(base + "/.hidden.txt")
        XCTAssertFalse(hidden.exists)
        menu("files-options").tap()
        let toggleHidden = app.descendants(matching: .any)["files-show-hidden"].firstMatch
        XCTAssertTrue(toggleHidden.waitForExistence(timeout: 5)); toggleHidden.tap()
        XCTAssertTrue(hidden.waitForExistence(timeout: 8))
        searchRemote(base + "/nst-/rst")
        let first = entry(base + "/nested-one/result.txt"), second = entry(base + "/nested-two/result.txt")
        XCTAssertTrue(first.waitForExistence(timeout: 15)); XCTAssertTrue(second.exists)
        filesMenu("files-select"); first.tap(); second.tap()
        for selected in [first, second] { XCTAssertTrue(["Selected", "已选择"].contains(selected.value as? String ?? "")) }
        capture("Fuzzy paths with selections from two folders")
        let batch = app.buttons["files-download-selected"]
        XCTAssertTrue(batch.isEnabled); XCTAssertTrue(batch.label.contains("2")); batch.tap()
        waitUntilCompleted(app.staticTexts["transfer-status-download-result.txt"])
        waitUntilCompleted(app.staticTexts["transfer-status-download-result (2).txt"])
        XCTAssertTrue(app.buttons["transfer-share-result.txt"].exists)
        XCTAssertTrue(app.buttons["transfer-share-result (2).txt"].exists)
        app.buttons["transfer-done"].tap(); closeRemoteBrowser()

        let verified = "FILES_CHECK_" + shortID()
        let check = "test ! -e " + quote(base + "/created-folder") + " && test ! -e " + quote(base + "/renamed-folder")
            + " && test \"$(cat " + quote(base + "/nested-one/result.txt") + ")\" = one"
            + " && test \"$(cat " + quote(base + "/nested-two/result.txt") + ")\" = two && " + emit(verified)
        let checked = try runCommand(check); waitForOutput(verified, surface: checked)
        try removeFixture(base)
    }

    func testTextMarkdownAndImagePreviewControls() throws {
        _ = try openTerminal()
        let base = fixturePath("previews"), ready = "PREVIEW_READY_" + shortID()
        let source = "let answer = 42 // NEEDLE\n" + String(repeating: "// Long preview line with several words and NEEDLE that should wrap on a narrow phone display.\n", count: 3)
        let relativeImageAlt = "Relative PNG fixture " + shortID()
        let webImageAlt = "Web PNG fixture " + shortID()
        let imageReference = "![\(relativeImageAlt)](./nested/../image.png?raw=1#preview)"
        let webImageReference = "![\(webImageAlt)](http://127.0.0.1:1/roamtty-no-autoload.png)"
        let markdown = "# File preview heading\n\n**Rendered content** and `inline code`.\n\n" + webImageReference + "\n\n" + imageReference + "\n\n- First item\n- Second item\n"
        let create = "mkdir -m 700 " + quote(base) + " && " + write(source, to: base + "/sample.swift")
            + " && " + write(markdown, to: base + "/readme.md")
            + " && printf '%s' " + quote(tinyPNG) + " | base64 -d > " + quote(base + "/image.png") + " && " + emit(ready)
        let surface = try runCommand(create); waitForOutput(ready, surface: surface)
        openRemoteFolder(base)
        entry(base + "/sample.swift").tap()
        let code = app.textViews["file-code-preview"]
        XCTAssertTrue(code.waitForExistence(timeout: 15)); XCTAssertTrue((code.value as? String ?? "").contains("let answer = 42"))
        menu("preview-options").tap(); app.buttons["preview-find"].tap()
        let find = app.textFields["preview-search"]
        XCTAssertTrue(find.waitForExistence(timeout: 5)); find.tap(); find.typeText("NEEDLE")
        app.buttons["preview-search-next"].tap(); app.buttons["preview-search-previous"].tap()
        XCTAssertEqual(find.value as? String, "NEEDLE")
        capture("Source preview search highlighting")
        app.buttons["preview-search-close"].tap()
        menu("preview-options").tap(); app.descendants(matching: .any)["preview-wrap"].firstMatch.tap()
        menu("preview-options").tap(); app.buttons["preview-font-larger"].tap()
        menu("preview-options").tap(); app.buttons["preview-font-smaller"].tap()
        XCTAssertTrue((code.value as? String ?? "").contains("let answer = 42"))
        capture("Wrapped syntax preview")
        app.buttons["preview-done"].tap()

        XCTAssertTrue(entry(base + "/readme.md").waitForExistence(timeout: 8)); entry(base + "/readme.md").tap()
        XCTAssertTrue(app.staticTexts["File preview heading"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.textViews["file-code-preview"].exists)
        menu("preview-options").tap(); app.descendants(matching: .any)["preview-render-markdown"].firstMatch.tap()
        XCTAssertTrue(code.waitForExistence(timeout: 5)); XCTAssertTrue((code.value as? String ?? "").contains("# File preview heading"))
        XCTAssertTrue((code.value as? String ?? "").contains(imageReference))
        XCTAssertTrue((code.value as? String ?? "").contains(webImageReference))
        menu("preview-options").tap(); app.descendants(matching: .any)["preview-render-markdown"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["File preview heading"].waitForExistence(timeout: 5))
        let markdownPreview = app.scrollViews["file-markdown-preview"].firstMatch
        XCTAssertTrue(markdownPreview.waitForExistence(timeout: 5))
        let relativeImage = markdownPreview.images.matching(NSPredicate(format: "label == %@", relativeImageAlt)).firstMatch
        // RemoteMarkdownImage's loaded branch exposes an Image with this alt
        // label. Its unloaded Label/icon cannot satisfy the large square frame.
        let decodedImage = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard relativeImage.exists, relativeImage.isHittable else { return false }
            let frame = relativeImage.frame
            return frame.width > 100 && frame.height > 100 && frame.height <= 480 && abs(frame.width - frame.height) <= 1
                && markdownPreview.frame.contains(frame)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [decodedImage], timeout: 15), .completed, "The relative PNG must load from the README's remote directory and render as an actual image")
        // SwiftUI Link exposes a native Button in the iOS accessibility tree.
        let webImageLink = markdownPreview.buttons.matching(NSPredicate(format: "label == %@", webImageAlt)).firstMatch
        XCTAssertTrue(webImageLink.waitForExistence(timeout: 5), "Web images must remain explicit native links; previewing a document must not fetch them")
        XCTAssertTrue(webImageLink.isHittable)
        XCTAssertLessThan(webImageLink.frame.height, 80, "The web image stays a compact placeholder after the relative image has loaded")
        capture("Rendered remote Markdown")
        app.buttons["preview-done"].tap()

        XCTAssertTrue(entry(base + "/image.png").waitForExistence(timeout: 8)); entry(base + "/image.png").tap()
        let image = app.descendants(matching: .any)["file-image-preview"].firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["preview-image-dimensions"].label, "2 × 2")
        image.pinch(withScale: 2, velocity: 1)
        image.doubleTap()
        let full = app.descendants(matching: .any)["file-image-fullscreen"].firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 8))
        capture("Full screen remote PNG")
        app.buttons["preview-image-close"].tap()
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        app.buttons["preview-done"].tap(); closeRemoteBrowser()
        try removeFixture(base)
    }
}
