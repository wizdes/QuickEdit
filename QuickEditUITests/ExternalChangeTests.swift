import XCTest

/// M2 n3: a file changed by another app. The write comes from a separate
/// /bin/sh process that the Debug app starts (-QETestExternalWrite), because
/// the sandboxed test runner cannot write the fixture files.
final class ExternalChangeTests: QuickEditUITestCase {
    func testCleanDocumentReloads() throws {
        let url = try fixtureFolder("external-clean").appendingPathComponent("outside.txt")
        launch(opening: url.path, extraArguments: ["-QETestExternalWrite", url.path, "after\n", "3"])
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        XCTAssertEqual(text, "before\n")
        waitForBytes(url, Array("after\n".utf8), timeout: 10)
        // macOS tells the app about ~3 s after an uncoordinated write.
        waitUntil(10, "the window still shows \(text.debugDescription)") { self.text == "after\n" }
    }

    func testEditedDocumentShowsConflictOnSave() throws {
        let url = try fixtureFolder("external-edited").appendingPathComponent("outside.txt")
        launch(opening: url.path, extraArguments: ["-QETestExternalWrite", url.path, "theirs\n", "4"])
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("mine")
        waitForBytes(url, Array("theirs\n".utf8), timeout: 10)
        RunLoop.current.run(until: Date().addingTimeInterval(4)) // past the ~3 s notice
        XCTAssertEqual(text, "before\nmine", "an edited document must not reload")
        app.typeKey("s", modifierFlags: .command)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "no conflict sheet on Save")
        let sheetText = sheet.staticTexts.allElementsBoundByIndex.map(\.value).compactMap { $0 as? String }.joined(separator: " ")
        XCTAssertTrue(sheetText.localizedCaseInsensitiveContains("changed by another application"),
                      "sheet says: \(sheetText)")
        attachScreenshot("external-change-conflict", app.windows.firstMatch.screenshot())
        XCTAssertEqual(bytes(url), Array("theirs\n".utf8), "nothing written before the user chooses")
        sheet.buttons["Cancel"].click()
        app.typeKey("z", modifierFlags: .command)
    }
}
