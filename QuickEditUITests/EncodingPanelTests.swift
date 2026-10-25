import XCTest

/// M3 end to end: the Open and Save panel encoding pop-ups, the "can no
/// longer be saved" sheet, and Return in a CRLF file. Fixtures come from
/// build.sh (folder "encodings").
final class EncodingPanelTests: QuickEditUITestCase {
    private func choose(_ title: String, in popUp: XCUIElement) {
        XCTAssertTrue(popUp.waitForExistence(timeout: 5), "no encoding pop-up")
        popUp.click()
        let item = popUp.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no item \(title)")
        item.click()
    }

    /// The Open panel's choice decodes that file: UTF-8 bytes read as
    /// Windows Latin 1 show "cafÃ©".
    func testOpenPanelEncodingChoiceAppliesToTheFile() throws {
        let url = try fixtureFolder("encodings").appendingPathComponent("utf8.txt")
        launch()
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        safePress("o", .command)
        // On macOS 27 the Open panel is a window titled "Open" (identifier
        // "open-panel"), not a sheet or a dialog.
        let openWindow = app.windows["Open"]
        XCTAssertTrue(openWindow.waitForExistence(timeout: 5) || app.sheets.firstMatch.exists || app.dialogs.firstMatch.exists,
                      "no Open panel")
        let panel = openWindow.exists ? openWindow
            : (app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch)
        let popUp = panel.popUpButtons["openEncoding"]
        XCTAssertEqual(popUp.value as? String, "Automatic", "the pop-up starts at Automatic")
        attachScreenshot("open-panel-encoding", app.windows.firstMatch.screenshot())
        choose("Western (Windows Latin 1)", in: popUp)
        safePress("g", [.command, .shift])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        safeType(url.path)
        safePress(.return, [])
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        safePress(.return, [])
        let window = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'utf8'")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertEqual(window.textViews.firstMatch.value as? String, "caf\u{C3}\u{A9}\n")
    }

    /// The Save panel's choice is what lands on disk.
    func testSavePanelEncodingChangeWritesThatEncoding() throws {
        let folder = try fixtureFolder("encodings")
        launch()
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        safeType("caf\u{E9}")
        safePress("s", .command)
        let sheet = savePanel()
        let popUp = sheet.popUpButtons["saveEncoding"]
        XCTAssertEqual(popUp.value as? String, "Unicode (UTF-8)", "a new document starts at UTF-8")
        attachScreenshot("save-panel-encoding", app.windows.firstMatch.screenshot())
        choose("Western (Windows Latin 1)", in: popUp)
        fillSavePanel(name: "latin-out.txt", folder: folder, addTxtExtension: true)
        waitForBytes(folder.appendingPathComponent("latin-out.txt"), [0x63, 0x61, 0x66, 0xE9])
    }

    /// Typing a character Windows Latin 1 cannot hold shows TextEdit's
    /// sheet; Cancel takes the character back.
    func testEncodingNoLongerFitsSheetCancelUndoes() throws {
        let url = try fixtureFolder("encodings").appendingPathComponent("latin.txt")
        launch(opening: url.path)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        XCTAssertEqual(text, "caf\u{E9}\n")
        safePress(.downArrow, .command)
        safeType("\u{3A9}") // Greek capital omega: not in Windows Latin 1
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "no encoding sheet")
        let sheetText = sheet.staticTexts.allElementsBoundByIndex.compactMap { $0.value as? String }.joined(separator: " ")
        XCTAssertTrue(sheetText.contains("can no longer be saved using its original Western (Windows Latin 1) encoding"),
                      "sheet says: \(sheetText)")
        attachScreenshot("encoding-sheet", app.windows.firstMatch.screenshot())
        sheet.buttons["Cancel"].click()
        waitUntil(5, "text is \(text.debugDescription)") { self.text == "caf\u{E9}\n" }
        XCTAssertEqual(bytes(url), [0x63, 0x61, 0x66, 0xE9, 0x0A], "nothing written")
    }

    /// Return in a CRLF file types CRLF; the file stays CRLF only.
    func testReturnInACRLFFileKeepsCRLF() throws {
        let url = try fixtureFolder("encodings").appendingPathComponent("crlf.txt")
        launch(opening: url.path)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        safePress(.downArrow, .command)
        safeType("x")
        safePress(.return, [])
        safeType("y")
        safePress("s", .command)
        waitForBytes(url, Array("one\r\ntwo\r\nx\r\ny".utf8))
    }
}
