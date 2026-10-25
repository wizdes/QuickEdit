import AppKit
import XCTest

/// M2 n5: quit with windows kept, relaunch: the same file, selection and
/// place come back. The only test that reads and writes saved window state.
final class RestorationTests: QuickEditUITestCase {
    func testRelaunchRestoresFileAndSelection() throws {
        let url = try fixtureFolder("restore").appendingPathComponent("restore-1mb.txt")
        launch(opening: url.path, keepsWindows: true)
        XCTAssertTrue(textView.waitForExistence(timeout: 15))

        // Select "line 13000 of" with the find bar; Escape keeps the match selected.
        safePress("f", .command)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "no find bar")
        safeType("line 13000 of", into: search)
        safePress(.return, [], on: search)
        safePress(.escape, [])
        textView.click() // focus back on the text; the click would move the caret, so
        safePress("g", .command) // find the match again: it is the selection
        RunLoop.current.run(until: Date().addingTimeInterval(1.0)) // let state save
        safePress("q", .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

        // The find pasteboard outlives the app; clear it so nothing but the
        // restored selection can bring "line 13000 of" back.
        NSPasteboard(name: .find).clearContents()

        // Relaunch with no file argument: restoration reopens the window.
        launch(keepsWindows: true)
        let window = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'restore-1mb'")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "titles: \(app.windows.allElementsBoundByIndex.map(\.title))")
        XCTAssertEqual(app.windows.count, 1)
        // Read the selection back through accessibility: typing replaces the
        // selection, so the text view's value shows exactly what was selected.
        safeType("§")
        let value = (window.textViews.firstMatch.value as? String) ?? ""
        XCTAssertTrue(value.contains("line 12999 of the restoration fixture\n§ the restoration fixture\nline 13001 of"),
                      "the selection \"line 13000 of\" did not come back")
        XCTAssertEqual(value.components(separatedBy: "§").count, 2, "exactly one replacement")
        attachScreenshot("restored-window", window.screenshot())
        safePress("z", .command)

        // Leave no saved windows for later runs: close, then quit.
        safePress("w", .command)
        safePress("q", .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }
}
