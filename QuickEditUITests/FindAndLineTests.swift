import XCTest

/// M4 n2 and n3: the find bar and Select Line, end to end in an untitled window.
///
/// The tests read the selection without the pasteboard: Use Selection for
/// Find (Cmd+E) copies it into the find field, or typing replaces it. Texts
/// start with a digit or are all capitals so automatic capitalization cannot
/// change what was typed.
final class FindAndLineTests: QuickEditUITestCase {
    /// Launches with an empty untitled window and types `text` into it.
    private func launchWithText(_ text: String, extraArguments: [String] = []) {
        launch(extraArguments: extraArguments)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.click()
        safeType(text)
        XCTAssertEqual(self.text, text, "typing changed the text")
    }

    /// The current selection, read through Cmd+E and the find field. Leaves
    /// the find bar closed and the text view focused.
    private func selectedText(file: StaticString = #filePath, line: UInt = #line) -> String? {
        safePress("e", .command)
        safePress("f", .command)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "no find bar", file: file, line: line)
        let value = search.value as? String
        safePress(.escape, [])
        return value
    }

    // MARK: n3: find bar

    /// Cmd+F shows the find bar; typing in it finds a match and selects it.
    func testTypingInFindBarFindsAMatch() {
        launchWithText("1 owl 2 owl")
        safePress(.upArrow, .command)
        safePress("f", .command)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Cmd+F did not show the find bar")
        safeType("owl", into: search)
        safePress(.return, [], on: search)
        // Escape closes the bar and keeps the match selected; typing replaces it.
        safePress(.escape, [])
        safeType("Z")
        XCTAssertTrue(["1 Z 2 owl", "1 owl 2 Z"].contains(text), "the find bar selected no match: \(text)")
        attachScreenshot("find-typing", app.windows.firstMatch.screenshot())
    }

    /// Cmd+E then Cmd+G finds the selection's next copy; Cmd+G moves on and
    /// wraps around to the first match.
    func testUseSelectionThenFindNextAndWrap() {
        launchWithText("1 dog 2 dog 3 dog")
        safePress(.upArrow, .command)
        safePress(.rightArrow, [])
        safePress(.rightArrow, [])
        safePress(.rightArrow, [.option, .shift]) // selects the first "dog"
        safePress("e", .command)
        safePress("g", .command)
        safeType("B")
        XCTAssertEqual(text, "1 dog 2 B 3 dog")
        safePress("g", .command)
        safeType("C")
        XCTAssertEqual(text, "1 dog 2 B 3 C")
        safePress("g", .command) // wraps to the start
        safeType("A")
        XCTAssertEqual(text, "1 A 2 B 3 C")
    }

    /// Shift+Cmd+G moves backwards and wraps around to the last match.
    func testFindPreviousAndWrap() {
        launchWithText("1 fox 2 fox 3 fox")
        safePress(.downArrow, .command)
        safePress(.leftArrow, [.option, .shift]) // selects the last "fox"
        safePress("e", .command)
        safePress("g", [.command, .shift])
        safeType("B")
        XCTAssertEqual(text, "1 fox 2 B 3 fox")
        safePress("g", [.command, .shift])
        safeType("A")
        XCTAssertEqual(text, "1 A 2 B 3 fox")
        safePress("g", [.command, .shift]) // wraps to the end
        safeType("C")
        XCTAssertEqual(text, "1 A 2 B 3 C")
    }

    /// Opt+Cmd+F, then Replace All with Ignore Case (the find bar's default)
    /// replaces every match whatever its case.
    func testReplaceAllIgnoringCase() {
        launchWithText("1 Fox 2 fox 3 FOX")
        safePress("f", [.command, .option])
        let find = app.searchFields.firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 5), "Opt+Cmd+F did not show the find bar")
        // Opt+Cmd+F puts the focus in the replace field, and the find field
        // may hold an earlier search (the find pasteboard is shared), so
        // focus the find field and replace what is in it.
        find.click()
        safePress("a", .command, on: find)
        safeType("fox", into: find)
        // The replace field is the second field of the bar.
        let replace = app.searchFields.count > 1 ? app.searchFields.element(boundBy: 1) : app.textFields.firstMatch
        XCTAssertTrue(replace.waitForExistence(timeout: 5), "no replace field")
        replace.click()
        safeType("cat", into: replace)
        let all = app.buttons["All"].exists ? app.buttons["All"] : app.buttons["Replace All"]
        XCTAssertTrue(all.waitForExistence(timeout: 5), "no Replace All button; buttons: \(app.buttons.allElementsBoundByIndex.map(\.title))")
        attachScreenshot("replace-bar", app.windows.firstMatch.screenshot())
        all.click()
        waitUntil(5, "Replace All left: \(text)") { self.text == "1 cat 2 cat 3 cat" }
    }

    // MARK: M4 review row 2: edits through the key window

    /// Copy, Paste, Undo, Redo and Cut from their keys: the menu sends each
    /// with no target, and the key window's text view does it.
    func testCopyPasteUndoRedoCutInTheKeyWindow() {
        launchWithText("1 alpha 2 beta")
        safePress(.upArrow, .command)
        safePress(.rightArrow, [])
        safePress(.rightArrow, [])
        safePress(.rightArrow, [.option, .shift]) // selects "alpha"
        safePress("c", .command)
        XCTAssertEqual(text, "1 alpha 2 beta", "Copy changed the text")
        safePress(.downArrow, .command)
        safePress("v", .command)
        XCTAssertEqual(text, "1 alpha 2 betaalpha", "Paste did not insert the copied word")
        safePress("z", .command)
        XCTAssertEqual(text, "1 alpha 2 beta", "Undo did not take back Paste")
        safePress("z", [.command, .shift])
        XCTAssertEqual(text, "1 alpha 2 betaalpha", "Redo did not paste again")

        safePress(.upArrow, .command)
        safePress(.rightArrow, [])
        safePress(.rightArrow, [])
        safePress(.rightArrow, [.option, .shift])
        safePress("x", .command)
        XCTAssertEqual(text, "1  2 betaalpha", "Cut did not remove the word")
        safePress(.downArrow, .command)
        safePress("v", .command)
        XCTAssertEqual(text, "1  2 betaalphaalpha", "Paste after Cut did not insert the cut word")
        safePress("z", .command)
        safePress("z", .command)
        XCTAssertEqual(text, "1 alpha 2 betaalpha", "Undo did not take back Paste and Cut")
    }

    // MARK: n2: Select Line

    private static let twentyLines = (1...20).map { "L\($0)" }.joined(separator: "\n")

    /// The Select Line panel. macOS 27 reports this NSPanel as a dialog,
    /// not a window, so app.windows never finds it.
    private var selectLinePanel: XCUIElement { app.dialogs["Select Line"] }

    /// Cmd+L, type 20, Return: line 20 is selected and the panel closes.
    func testSelectLineSelectsTheLine() {
        launchWithText(Self.twentyLines)
        safePress(.upArrow, .command)
        safePress("l", .command)
        let panel = selectLinePanel
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "Cmd+L did not open the Select Line panel")
        let field = panel.textFields.firstMatch
        XCTAssertEqual(field.placeholderValue, "Line number")
        attachScreenshot("select-line-panel", panel.screenshot())
        safeType("20")
        safePress(.return, [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "Return did not close the panel after a good entry")
        XCTAssertEqual(selectedText(), "L20")

        // A range, chosen with the Select button: the panel stays open.
        safePress("l", .command)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        safePress("a", .command, on: field)
        safeType("3-4")
        panel.buttons["Select"].click()
        XCTAssertTrue(panel.exists, "the Select button closed the panel")
        safePress("w", .command, on: panel)
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        safeType("X")
        XCTAssertTrue(text.hasPrefix("L1\nL2\nXL5\n"), "lines 3 to 4 were not selected: \(text.prefix(20).debugDescription)")
    }

    /// M4 review row 5: with two windows, Select Line changes the front
    /// (main) window only.
    func testSelectLineActsOnTheFrontWindowOnly() {
        launchWithText(Self.twentyLines)
        safePress("n", .command)
        waitUntil(5, "Cmd+N did not open a second window") { self.app.windows.count >= 2 }
        safeType("1\n2\n3")
        safePress("l", .command)
        let panel = selectLinePanel
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        safeType("2")
        safePress(.return, [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        safeType("X")
        let texts = app.textViews.allElementsBoundByIndex.map { ($0.value as? String) ?? "" }
        XCTAssertTrue(texts.contains("1\nX3"), "line 2 of the front window was not selected: \(texts)")
        XCTAssertTrue(texts.contains(Self.twentyLines), "the back window changed: \(texts)")
    }

    /// M4 review row 8: with the find bar's field focused, Select Line still
    /// selects in the document, not in the find field.
    func testSelectLineWithTheFindFieldFocused() {
        // The Debug app copies the document's selection into the text view's
        // label (QuickEdit/App/TestHooks.swift), so the test reads it without
        // keys: Cmd+E would act on the focused find field.
        launchWithText(Self.twentyLines, extraArguments: ["-QETestExposeSelection", "YES"])
        safePress(.upArrow, .command)
        safePress("f", .command)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Cmd+F did not show the find bar")
        safeType("L1", into: search)
        safePress("l", .command)
        let panel = selectLinePanel
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        safeType("20")
        safePress(.return, [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "Return did not close the panel after a good entry")
        XCTAssertFalse(app.staticTexts["Invalid line specification \u{201C}20\u{201D}."].exists,
                       "Select Line looked for line 20 in the find field")
        XCTAssertEqual(search.value as? String, "L1", "Select Line changed the find field")
        // Read the selection while the find bar is still open: Escape in the
        // find field selects the bar's current match ("L1"), as AppKit's
        // incremental find does.
        XCTAssertTrue(search.exists, "the find bar closed")
        waitUntil(5, "the selection is \(self.textView.label.debugDescription)") {
            self.textView.label == "selection:L20"
        }
        safePress(.escape, [])
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: textView)], timeout: 5),
                       .completed, "the text view did not get the focus back after Escape")
    }

    /// A bad entry shows TextEdit's message on the panel.
    func testSelectLineRejectsBadEntry() {
        launchWithText(Self.twentyLines)
        safePress("l", .command)
        let panel = selectLinePanel
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        safeType("99")
        safePress(.return, [])
        let message = app.staticTexts["Invalid line specification \u{201C}99\u{201D}."]
        XCTAssertTrue(message.waitForExistence(timeout: 5), "no error for line 99 of 20")
        XCTAssertTrue(app.staticTexts["Enter a line number or a range of line numbers to select."].exists)
        attachScreenshot("select-line-error", panel.screenshot())
        safePress(.return, []) // OK
        XCTAssertTrue(message.waitForNonExistence(timeout: 5))
        XCTAssertTrue(panel.exists, "the panel closed after a bad entry")
    }
}
