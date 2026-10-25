import XCTest

/// M2 n3: a file changed by another app. The write comes from a separate
/// /bin/sh process that the Debug app starts (-QETestExternalWrite), because
/// the sandboxed test runner cannot write the fixture files. Each value
/// follows its own flag (AppKit opens a bare launch argument as a document),
/// and the text has backslash-n for a newline (see QuickEdit/App/TestHooks.swift).
final class ExternalChangeTests: QuickEditUITestCase {
    func testCleanDocumentReloads() throws {
        let url = try fixtureFolder("external-clean").appendingPathComponent("outside.txt")
        launch(opening: url.path, extraArguments: ["-QETestExternalWrite", url.path, "-QETestExternalWriteText", "after\\n", "-QETestExternalWriteDelay", "3"])
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        XCTAssertEqual(text, "before\n")
        waitForBytes(url, Array("after\n".utf8), timeout: 10)
        // macOS tells the app about 3.15 s after an uncoordinated write
        // (measured 2026-10-23), so allow 5 s.
        waitUntil(5, "the window still shows \(text.debugDescription)") { self.text == "after\n" }
    }

    func testEditedDocumentShowsConflictOnSave() throws {
        let url = try fixtureFolder("external-edited").appendingPathComponent("outside.txt")
        launch(opening: url.path, extraArguments: ["-QETestExternalWrite", url.path, "-QETestExternalWriteText", "theirs\\n", "-QETestExternalWriteDelay", "4"])
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        safePress(.downArrow, .command)
        safeType("mine")
        waitForBytes(url, Array("theirs\n".utf8), timeout: 10)
        RunLoop.current.run(until: Date().addingTimeInterval(4)) // past the ~3 s notice
        XCTAssertEqual(text, "before\nmine", "an edited document must not reload")
        safePress("s", .command)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "no conflict sheet on Save")
        let sheetText = sheet.staticTexts.allElementsBoundByIndex.map(\.value).compactMap { $0 as? String }.joined(separator: " ")
        XCTAssertTrue(sheetText.localizedCaseInsensitiveContains("changed by another application"),
                      "sheet says: \(sheetText)")
        attachScreenshot("external-change-conflict", app.windows.firstMatch.screenshot())
        XCTAssertEqual(bytes(url), Array("theirs\n".utf8), "nothing written before the user chooses")
        // Leave nothing to save. macOS 27's sheet has Save As…, Revert and
        // Save Anyway, and no Cancel; Revert keeps the other app's bytes.
        if sheet.buttons["Cancel"].exists {
            sheet.buttons["Cancel"].click()
            safePress("z", .command)
        } else {
            sheet.buttons["Revert"].click()
        }
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "the conflict sheet did not close")
    }
}
