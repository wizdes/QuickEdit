import XCTest

/// End to end: open, type, save, and the bytes on disk match.
final class OpenTypeSaveTests: QuickEditUITestCase {
    /// Plan n3 step 3, first test.
    func testOpenTypeSaveExistingFile() throws {
        let url = try fixtureFolder("open-type-save").appendingPathComponent("hello.txt")
        waitForBytes(url, Array("abc\n".utf8))
        launch(opening: url.path)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        XCTAssertEqual(text, "abc\n")
        app.typeKey(.downArrow, modifierFlags: .command) // end of document
        app.typeText("XYZ")
        app.typeKey("s", modifierFlags: .command)
        waitForBytes(url, Array("abc\nXYZ".utf8))
    }

    /// Plan n3 step 3, second test.
    func testNewDocumentSaveAs() throws {
        let folder = try fixtureFolder("new-save")
        launch()
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        app.typeText("hi")
        app.typeKey("s", modifierFlags: .command)
        fillSavePanel(name: "greeting", folder: folder)
        waitForBytes(folder.appendingPathComponent("greeting.txt"), Array("hi".utf8))
    }

    /// Root item 1: save is an undo boundary, and edits after a save survive quit.
    func testSaveBoundaryUndoAndQuitKeepsEdits() throws {
        let url = try fixtureFolder("boundary").appendingPathComponent("boundary.txt")
        waitForBytes(url, Array("start\n".utf8))
        launch(opening: url.path)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("saved")
        app.typeKey("s", modifierFlags: .command)
        waitForBytes(url, Array("start\nsaved".utf8))
        XCTAssertFalse(isEdited(), "document still marked edited right after Cmd+S")

        app.typeText(" more")
        XCTAssertEqual(text, "start\nsaved more")
        XCTAssertTrue(isEdited(), "typing after a save must mark the document edited")

        // One Undo goes back to the text as saved, not further.
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(text, "start\nsaved", "one Undo after the save restores the post-save text")
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(text, "start\nsaved more")

        app.typeText(" end")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "QuickEdit did not quit")
        waitForBytes(url, Array("start\nsaved more end".utf8))

        launch(opening: url.path)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        XCTAssertEqual(text, "start\nsaved more end")
        waitForBytes(url, Array("start\nsaved more end".utf8))
    }

    /// Root item 4: the ".txt" checkbox in the Save panel.
    func testSavePanelExtensionCheckboxOnAddsTxt() throws {
        let folder = try fixtureFolder("ext-on")
        try saveNewDocument(text: "on", name: "plain", folder: folder, addTxtExtension: true)
        waitForBytes(folder.appendingPathComponent("plain.txt"), Array("on".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("plain").path))
    }

    func testSavePanelExtensionCheckboxOffAddsNothing() throws {
        let folder = try fixtureFolder("ext-off")
        try saveNewDocument(text: "off", name: "bare", folder: folder, addTxtExtension: false)
        waitForBytes(folder.appendingPathComponent("bare"), Array("off".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("bare.txt").path))
    }

    func testSavePanelKeepsTypedExtension() throws {
        let folder = try fixtureFolder("ext-md")
        try saveNewDocument(text: "md", name: "x.md", folder: folder, addTxtExtension: true)
        waitForBytes(folder.appendingPathComponent("x.md"), Array("md".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("x.md.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("x.txt").path))
    }

    /// Root item 5: File > Open with a typed path.
    func testOpenPanelOpensFile() throws {
        let url = try fixtureFolder("open-panel").appendingPathComponent("openme.txt")
        launch()
        app.typeKey("o", modifierFlags: .command)
        let panel = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10) || app.windows["Open"].waitForExistence(timeout: 5),
                      "no Open panel")
        app.typeKey("g", modifierFlags: [.command, .shift])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        app.typeText(url.path)
        app.typeKey(.return, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        app.typeKey(.return, modifierFlags: [])
        let window = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'openme'")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10),
                      "no window titled openme; titles: \(app.windows.allElementsBoundByIndex.map { $0.title })")
        XCTAssertEqual(window.textViews.firstMatch.value as? String, "opened by the Open panel\n")
    }

    // MARK: Helpers

    private func saveNewDocument(text typed: String, name: String, folder: URL, addTxtExtension: Bool) throws {
        launch()
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.click()
        app.typeText(typed)
        app.typeKey("s", modifierFlags: .command)
        fillSavePanel(name: name, folder: folder, addTxtExtension: addTxtExtension)
    }

    /// The front window's "edited" state, read from its close button the way
    /// VoiceOver does, or from the "Edited" marker in the title.
    private func isEdited() -> Bool {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let window = app.windows.firstMatch
        if window.title.contains("Edited") { return true }
        let close = window.buttons[XCUIIdentifierCloseWindow]
        if close.exists, let value = close.value as? String, value.localizedCaseInsensitiveContains("edited") {
            return true
        }
        return window.staticTexts["Edited"].exists
    }
}
