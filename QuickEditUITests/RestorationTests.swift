import XCTest

/// M2 n5: quit with windows kept, relaunch: the same file, selection and
/// place come back. The only test that reads and writes saved window state.
final class RestorationTests: QuickEditUITestCase {
    func testRelaunchRestoresFileAndSelection() throws {
        let url = try fixtureFolder("restore").appendingPathComponent("restore-1mb.txt")
        launch(opening: url.path, keepsWindows: true)
        XCTAssertTrue(textView.waitForExistence(timeout: 15))

        // Select "line 13000 of" with the find bar; Escape keeps the match selected.
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "no find bar")
        search.typeText("line 13000 of")
        search.typeKey(.return, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        textView.click() // focus back on the text; the click would move the caret, so
        app.typeKey("g", modifierFlags: .command) // find the match again: it is the selection
        RunLoop.current.run(until: Date().addingTimeInterval(1.0)) // let state save
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

        // Relaunch with no file argument: restoration reopens the window.
        launch(keepsWindows: true)
        let window = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'restore-1mb'")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "titles: \(app.windows.allElementsBoundByIndex.map(\.title))")
        XCTAssertEqual(app.windows.count, 1)
        // Read the selection back: Use Selection for Find (Cmd+E) puts it in
        // the find field.
        app.typeKey("e", modifierFlags: .command)
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "line 13000 of", "the selection did not come back")
        attachScreenshot("restored-window", window.screenshot())

        // Leave no saved windows for later runs: close, then quit.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }
}
