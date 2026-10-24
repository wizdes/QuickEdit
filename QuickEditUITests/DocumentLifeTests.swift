import XCTest

/// M2 n4: locked files and closing, all from NSDocument. Each test ends with
/// a byte or window check.
final class DocumentLifeTests: QuickEditUITestCase {
    /// A file locked in Finder (chflags uchg, made by build.sh): the first
    /// keystroke asks Unlock / Duplicate / Cancel; Duplicate opens an untitled
    /// copy and the locked file never changes.
    func testLockedFileOffersDuplicateAndKeepsBytes() throws {
        let url = try fixtureFolder("locked").appendingPathComponent("locked.txt")
        let original = Array("locked text\n".utf8)
        XCTAssertEqual(bytes(url), original)
        launch(opening: url.path)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("x")
        let alert = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5) || app.dialogs.firstMatch.waitForExistence(timeout: 2),
                      "no locked-file alert")
        attachScreenshot("locked-alert", app.windows.firstMatch.screenshot())
        for title in ["Unlock", "Duplicate", "Cancel"] {
            XCTAssertTrue(alert.buttons[title].exists || app.buttons[title].exists, "no \(title) button")
        }
        app.buttons["Duplicate"].firstMatch.click()
        waitUntil(10, "no duplicate window; windows: \(app.windows.allElementsBoundByIndex.map(\.title))") {
            self.app.windows.count == 2
        }
        XCTAssertEqual(app.windows.firstMatch.textViews.firstMatch.value as? String, "locked text\n")
        XCTAssertEqual(bytes(url), original, "the locked file must not change")
    }

    /// Close (Cmd+W) a named, edited document: no prompt; autosave in place
    /// writes the edit.
    func testClosingANamedEditedDocumentSavesWithoutAsking() throws {
        let url = try fixtureFolder("close-named").appendingPathComponent("named.txt")
        launch(opening: url.path)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("edit")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 2), "closing asked a question")
        waitUntil(10, "the window did not close") { self.app.windows.count == 0 }
        waitForBytes(url, Array("named\nedit".utf8))
    }

    /// Close an edited untitled document: the save sheet appears; Delete
    /// closes the window without saving.
    func testClosingAnEditedUntitledDocumentAsksAndDeleteCloses() throws {
        launch()
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        app.typeText("draft")
        app.typeKey("w", modifierFlags: .command)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "no save sheet for an edited untitled document")
        attachScreenshot("close-untitled-sheet", app.windows.firstMatch.screenshot())
        let delete = sheet.buttons["Delete"]
        XCTAssertTrue(delete.exists, "buttons: \(sheet.buttons.allElementsBoundByIndex.map(\.title))")
        delete.click()
        waitUntil(10, "the window did not close") { self.app.windows.count == 0 }
    }

    /// Rename… then Move To… then Duplicate on a named file: files end where
    /// expected with the same bytes.
    func testRenameMoveToAndDuplicate() throws {
        let folder = try fixtureFolder("rename-move")
        let original = folder.appendingPathComponent("original.txt")
        let renamed = folder.appendingPathComponent("renamed.txt")
        let dest = folder.appendingPathComponent("dest")
        let moved = dest.appendingPathComponent("renamed.txt")
        let content = Array("move me\n".utf8)
        launch(opening: original.path)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))

        // Rename…: the title becomes an editable field.
        chooseMenu("File", "Rename\u{2026}")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        app.typeKey("a", modifierFlags: .command)
        app.typeText("renamed.txt")
        app.typeKey(.return, modifierFlags: [])
        waitUntil(10, "rename did not happen") { self.bytes(renamed) == content && self.bytes(original) == nil }

        // Move To…: the popover's location menu, Other…, then Go to Folder.
        chooseMenu("File", "Move To\u{2026}")
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "no Move To popover")
        popover.popUpButtons.firstMatch.click()
        app.menuItems["Other\u{2026}"].firstMatch.click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        app.typeText(dest.path)
        app.typeKey(.return, modifierFlags: [])
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        app.typeKey(.return, modifierFlags: [])
        if popover.exists { popover.buttons["Move"].firstMatch.click() }
        waitUntil(10, "move did not happen") { self.bytes(moved) == content && self.bytes(renamed) == nil }

        // Duplicate: an untitled copy with the same text, saved next to it.
        app.typeKey("s", modifierFlags: [.command, .shift])
        waitUntil(10, "no duplicate window") { self.app.windows.count == 2 }
        app.typeKey("s", modifierFlags: .command)
        fillSavePanel(name: "copy", folder: dest)
        waitForBytes(dest.appendingPathComponent("copy.txt"), content)
        XCTAssertEqual(bytes(moved), content, "the original is unchanged")
    }
}
