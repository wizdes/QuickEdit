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

    /// File > Revert To > Last Saved: the typed edit goes away, the window
    /// shows the saved text, and the file holds the saved bytes.
    func testRevertToLastSaved() throws {
        let url = try fixtureFolder("revert").appendingPathComponent("revert.txt")
        let saved = Array("saved text\n".utf8)
        launch(opening: url.path)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("junk")
        XCTAssertEqual(text, "saved text\njunk")

        // With autosave in place, AppKit makes "Revert To" a submenu; its
        // first item names the last saved (or opened) version.
        app.menuBars.menuBarItems["File"].click()
        let revertTo = app.menuBars.menuBarItems["File"].menuItems["Revert To"]
        XCTAssertTrue(revertTo.waitForExistence(timeout: 5), "no Revert To submenu")
        revertTo.hover()
        let last = revertTo.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Last'")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 5),
                      "items: \(revertTo.menuItems.allElementsBoundByIndex.map(\.title))")
        last.click()
        // AppKit may confirm first.
        let sheet = app.sheets.firstMatch
        if sheet.waitForExistence(timeout: 2), sheet.buttons["Revert"].exists {
            attachScreenshot("revert-confirm", app.windows.firstMatch.screenshot())
            sheet.buttons["Revert"].click()
        }
        waitUntil(10, "the window shows \(text.debugDescription)") { self.text == "saved text\n" }
        waitForBytes(url, saved)
    }

    /// Duplicate, then Rename…, then Move To… on a named file (the File menu
    /// order): files end where expected with the same bytes.
    func testDuplicateRenameAndMoveTo() throws {
        let folder = try fixtureFolder("rename-move")
        let original = folder.appendingPathComponent("original.txt")
        let renamed = folder.appendingPathComponent("renamed.txt")
        let dest = folder.appendingPathComponent("dest")
        let moved = dest.appendingPathComponent("renamed.txt")
        let content = Array("move me\n".utf8)
        launch(opening: original.path)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))

        // Duplicate: an untitled copy with the same text, saved next to it,
        // then closed so the original's window is in front again.
        app.typeKey("s", modifierFlags: [.command, .shift])
        waitUntil(10, "no duplicate window") { self.app.windows.count == 2 }
        app.typeKey("s", modifierFlags: .command)
        fillSavePanel(name: "copy", folder: folder)
        waitForBytes(folder.appendingPathComponent("copy.txt"), content)
        app.typeKey("w", modifierFlags: .command)
        waitUntil(10, "the duplicate window did not close") { self.app.windows.count == 1 }
        XCTAssertEqual(bytes(original), content, "Duplicate leaves the original unchanged")

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
        XCTAssertEqual(bytes(folder.appendingPathComponent("copy.txt")), content, "the copy is unchanged")
    }
}
