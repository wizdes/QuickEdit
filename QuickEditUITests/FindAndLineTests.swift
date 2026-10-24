import XCTest

/// M4 n2 and n3: the find bar and Select Line, end to end in an untitled window.
///
/// The tests read the selection without the pasteboard: Use Selection for
/// Find (Cmd+E) copies it into the find field, or typing replaces it. Texts
/// start with a digit or are all capitals so automatic capitalization cannot
/// change what was typed.
final class FindAndLineTests: QuickEditUITestCase {
    /// Launches with an empty untitled window and types `text` into it.
    private func launchWithText(_ text: String) {
        launch()
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.click()
        app.typeText(text)
        XCTAssertEqual(self.text, text, "typing changed the text")
    }

    /// The current selection, read through Cmd+E and the find field. Leaves
    /// the find bar closed and the text view focused.
    private func selectedText(file: StaticString = #filePath, line: UInt = #line) -> String? {
        app.typeKey("e", modifierFlags: .command)
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "no find bar", file: file, line: line)
        let value = search.value as? String
        app.typeKey(.escape, modifierFlags: [])
        return value
    }

    // MARK: n3: find bar

    /// Cmd+F shows the find bar; typing in it finds a match and selects it.
    func testTypingInFindBarFindsAMatch() {
        launchWithText("1 owl 2 owl")
        app.typeKey(.upArrow, modifierFlags: .command)
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Cmd+F did not show the find bar")
        search.typeText("owl")
        search.typeKey(.return, modifierFlags: [])
        // Escape closes the bar and keeps the match selected; typing replaces it.
        app.typeKey(.escape, modifierFlags: [])
        app.typeText("Z")
        XCTAssertTrue(["1 Z 2 owl", "1 owl 2 Z"].contains(text), "the find bar selected no match: \(text)")
        attachScreenshot("find-typing", app.windows.firstMatch.screenshot())
    }

    /// Cmd+E then Cmd+G finds the selection's next copy; Cmd+G moves on and
    /// wraps around to the first match.
    func testUseSelectionThenFindNextAndWrap() {
        launchWithText("1 dog 2 dog 3 dog")
        app.typeKey(.upArrow, modifierFlags: .command)
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [.option, .shift]) // selects the first "dog"
        app.typeKey("e", modifierFlags: .command)
        app.typeKey("g", modifierFlags: .command)
        app.typeText("B")
        XCTAssertEqual(text, "1 dog 2 B 3 dog")
        app.typeKey("g", modifierFlags: .command)
        app.typeText("C")
        XCTAssertEqual(text, "1 dog 2 B 3 C")
        app.typeKey("g", modifierFlags: .command) // wraps to the start
        app.typeText("A")
        XCTAssertEqual(text, "1 A 2 B 3 C")
    }

    /// Shift+Cmd+G moves backwards and wraps around to the last match.
    func testFindPreviousAndWrap() {
        launchWithText("1 fox 2 fox 3 fox")
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeKey(.leftArrow, modifierFlags: [.option, .shift]) // selects the last "fox"
        app.typeKey("e", modifierFlags: .command)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText("B")
        XCTAssertEqual(text, "1 fox 2 B 3 fox")
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText("A")
        XCTAssertEqual(text, "1 A 2 B 3 fox")
        app.typeKey("g", modifierFlags: [.command, .shift]) // wraps to the end
        app.typeText("C")
        XCTAssertEqual(text, "1 A 2 B 3 C")
    }

    /// Opt+Cmd+F, then Replace All with Ignore Case (the find bar's default)
    /// replaces every match whatever its case.
    func testReplaceAllIgnoringCase() {
        launchWithText("1 Fox 2 fox 3 FOX")
        app.typeKey("f", modifierFlags: [.command, .option])
        let find = app.searchFields.firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 5), "Opt+Cmd+F did not show the find bar")
        find.typeText("fox")
        // The replace field is the second field of the bar.
        let replace = app.searchFields.count > 1 ? app.searchFields.element(boundBy: 1) : app.textFields.firstMatch
        XCTAssertTrue(replace.waitForExistence(timeout: 5), "no replace field")
        replace.click()
        replace.typeText("cat")
        let all = app.buttons["All"].exists ? app.buttons["All"] : app.buttons["Replace All"]
        XCTAssertTrue(all.waitForExistence(timeout: 5), "no Replace All button; buttons: \(app.buttons.allElementsBoundByIndex.map(\.title))")
        attachScreenshot("replace-bar", app.windows.firstMatch.screenshot())
        all.click()
        waitUntil(5, "Replace All left: \(text)") { self.text == "1 cat 2 cat 3 cat" }
    }

    // MARK: n2: Select Line

    private static let twentyLines = (1...20).map { "L\($0)" }.joined(separator: "\n")

    /// Cmd+L, type 20, Return: line 20 is selected and the panel closes.
    func testSelectLineSelectsTheLine() {
        launchWithText(Self.twentyLines)
        app.typeKey(.upArrow, modifierFlags: .command)
        app.typeKey("l", modifierFlags: .command)
        let panel = app.windows["Select Line"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "Cmd+L did not open the Select Line panel")
        let field = panel.textFields.firstMatch
        XCTAssertEqual(field.placeholderValue, "Line number")
        attachScreenshot("select-line-panel", panel.screenshot())
        app.typeText("20")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "Return did not close the panel after a good entry")
        XCTAssertEqual(selectedText(), "L20")

        // A range, chosen with the Select button: the panel stays open.
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        field.typeKey("a", modifierFlags: .command)
        app.typeText("3-4")
        panel.buttons["Select"].click()
        XCTAssertTrue(panel.exists, "the Select button closed the panel")
        panel.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        app.typeText("X")
        XCTAssertTrue(text.hasPrefix("L1\nL2\nXL5\n"), "lines 3 to 4 were not selected: \(text.prefix(20).debugDescription)")
    }

    /// A bad entry shows TextEdit's message on the panel.
    func testSelectLineRejectsBadEntry() {
        launchWithText(Self.twentyLines)
        app.typeKey("l", modifierFlags: .command)
        let panel = app.windows["Select Line"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        app.typeText("99")
        app.typeKey(.return, modifierFlags: [])
        let message = app.staticTexts["Invalid line specification \u{201C}99\u{201D}."]
        XCTAssertTrue(message.waitForExistence(timeout: 5), "no error for line 99 of 20")
        XCTAssertTrue(app.staticTexts["Enter a line number or a range of line numbers to select."].exists)
        attachScreenshot("select-line-error", panel.screenshot())
        app.typeKey(.return, modifierFlags: []) // OK
        XCTAssertTrue(message.waitForNonExistence(timeout: 5))
        XCTAssertTrue(panel.exists, "the panel closed after a bad entry")
    }
}
