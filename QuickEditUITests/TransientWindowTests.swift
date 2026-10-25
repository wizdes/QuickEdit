import XCTest

/// M2 n2: the untitled window made at launch is replaced in place by the
/// first file opened, if nobody touched it (TextEdit's transient document).
final class TransientWindowTests: QuickEditUITestCase {
    func testOpenReplacesTheLaunchWindowInPlace() throws {
        let url = try fixtureFolder("transient").appendingPathComponent("replace.txt")
        // The untitled window starts away from the center (a Debug launch
        // argument places it as it is made; dragging it would end the
        // transient state), so a matching frame proves it was copied. The
        // point is quoted: launch arguments are read as property lists, and
        // a bare "{40, 700}" is not one, so the app read nothing.
        launch(extraArguments: ["-QETestUntitledTopLeft", "\"{40, 700}\""])
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1, "launch shows one untitled window")
        let untitledFrame = app.windows.firstMatch.frame
        XCTAssertEqual(untitledFrame.minX, 40, accuracy: 1, "the untitled window was not moved: \(untitledFrame)")

        safePress("o", .command)
        // On macOS 27 the Open panel is a window titled "Open", not a sheet or a dialog.
        XCTAssertTrue(app.windows["Open"].waitForExistence(timeout: 5) || app.sheets.firstMatch.exists
                      || app.dialogs.firstMatch.exists, "no Open panel")
        safePress("g", [.command, .shift])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        safeType(url.path)
        safePress(.return, [])
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        safePress(.return, [])

        let window = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'replace'")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        waitUntil(5, "windows: \(app.windows.allElementsBoundByIndex.map(\.title))") { self.app.windows.count == 1 }
        XCTAssertEqual(window.frame, untitledFrame, "the file's window takes the untitled window's place")
        XCTAssertEqual(window.textViews.firstMatch.value as? String, "replaces the untitled window\n")
    }

    func testTypedUntitledWindowIsKept() throws {
        let url = try fixtureFolder("transient").appendingPathComponent("replace.txt")
        launch()
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        safeType("keep me")
        safePress("o", .command)
        safePress("g", [.command, .shift])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        safeType(url.path)
        safePress(.return, [])
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        safePress(.return, [])
        waitUntil(10, "an edited untitled window must stay") { self.app.windows.count == 2 }
        // Leave nothing to save at teardown.
        app.windows.element(boundBy: 1).click()
        safePress("z", .command)
    }
}
