import AppKit
import XCTest

/// 1.2.0 in the real app: an empty untitled window closes without a
/// question; Ctrl+1, Ctrl+2 and Ctrl+9 pick tabs; the gutter and the map
/// show and hide from the View menu; and window screenshots for root.
/// The app runs on its own settings suite (`-QETestDefaultsSuite`, Debug
/// only). Keys go through SafeTyping only.
@MainActor
final class SublimeFeaturesUITests: QuickEditUITestCase {
    private func launchWithTestSettings(opening path: String? = nil) {
        launch(opening: path, extraArguments: ["-QETestDefaultsSuite", ShortcutUITests.suite,
                                               "-QETestDefaultsSuiteReset", "YES",
                                               "-NSAutomaticCapitalizationEnabled", "NO"])
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
    }

    private var frontWindow: XCUIElement { app.windows.firstMatch }

    private func documentWindows() -> [XCUIElement] {
        app.windows.allElementsBoundByIndex.filter { $0.title != "Settings" }
    }

    private var tabCount: Int {
        let group = frontWindow.tabGroups.firstMatch
        return group.exists ? group.tabs.count : 0
    }

    private func waitForText(_ expected: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        waitUntil(5, "\(message): the text is \(self.text.debugDescription)", file: file, line: line) {
            self.text == expected
        }
    }

    private var map: XCUIElement { frontWindow.groups["Document map"] }

    /// The gutter is no accessibility element (it fails the audit as a
    /// ruler), so it shows as the text view's offset from the window's
    /// left edge: about its width with line numbers, 0 without.
    private var gutterShows: Bool { textView.frame.minX - frontWindow.frame.minX > 20 }

    // MARK: Change 1

    /// Cmd+W on an untitled window that holds only spaces and line ends
    /// closes it with no save sheet.
    func testClosingAWhitespaceUntitledWindowAsksNothing() throws {
        launchWithTestSettings()
        safeType("   ")
        safePress(.return, [])
        safeType("  ")
        XCTAssertEqual(text, "   \n  ")
        safePress("w", .command)
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 2), "a blank untitled window asked to save")
        waitUntil(10, "the window did not close") { self.documentWindows().isEmpty }
    }

    /// Quit with a blank untitled window, windows kept: no question, and
    /// the window does not come back at the next launch.
    func testQuitWithABlankUntitledWindowDoesNotBringItBack() throws {
        // Saved windows are read: a run that last quit with none open
        // opens none, so make one then.
        let first = XCUIApplication()
        first.launchArguments = ["-ApplePersistenceIgnoreState", "NO", "-NSQuitAlwaysKeepsWindows", "YES"]
        first.launch()
        app = first
        if !first.windows.firstMatch.waitForExistence(timeout: 5) { safePress("n", .command) }
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        safeType("  ")
        safePress(.return, [])
        RunLoop.current.run(until: Date().addingTimeInterval(1.0)) // let state save
        safePress("q", .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Quit stopped on a question")
        // Relaunch reading the saved windows. With the blank window gone
        // there may be no window at all (as after quitting with none open),
        // so the launch helper's window check is not used.
        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["-ApplePersistenceIgnoreState", "NO", "-NSQuitAlwaysKeepsWindows", "YES"]
        relaunched.launch()
        app = relaunched
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let texts = relaunched.windows.allElementsBoundByIndex.map { ($0.textViews.firstMatch.value as? String) ?? "" }
        XCTAssertFalse(texts.contains { !$0.isEmpty && $0.allSatisfy(\.isWhitespace) }, "the blank window came back: \(texts)")
        XCTAssertLessThanOrEqual(texts.count, 1, "windows: \(relaunched.windows.allElementsBoundByIndex.map(\.title))")
        relaunched.terminate()
    }

    /// Leaves no saved windows or autosaved untitled documents (a failed
    /// run may have left some): opens what would come back, closes each
    /// window with Cmd+W (Delete on the save sheet), then quits.
    private func clearSavedWindows() {
        let clean = XCUIApplication()
        clean.launchArguments = ["-ApplePersistenceIgnoreState", "NO", "-NSQuitAlwaysKeepsWindows", "YES"]
        clean.launch()
        app = clean
        let dontReopen = clean.buttons["Don\u{2019}t Reopen"].firstMatch
        if dontReopen.waitForExistence(timeout: 2) { dontReopen.click() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        for _ in 0..<20 where !documentWindows().isEmpty {
            safePress("w", .command)
            let delete = clean.sheets.firstMatch.buttons["Delete"]
            if delete.waitForExistence(timeout: 1.5) { delete.click() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        XCTAssertTrue(documentWindows().isEmpty, "could not close the restored windows")
        // A real quit (terminate() kills the app, which saves nothing).
        safePress("q", .command)
        XCTAssertTrue(clean.wait(for: .notRunning, timeout: 10))
    }

    /// Launches reading and writing saved windows; makes a window when
    /// the last run quit with none.
    private func launchKeepingWindows(_ keeps: Bool) -> XCUIApplication {
        let launched = XCUIApplication()
        launched.launchArguments = ["-ApplePersistenceIgnoreState", "NO", "-NSQuitAlwaysKeepsWindows", keeps ? "YES" : "NO",
                                    "-QETestDefaultsSuite", ShortcutUITests.suite, "-QETestDefaultsSuiteReset", "YES",
                                    "-NSAutomaticCapitalizationEnabled", "NO"]
        launched.launch()
        app = launched
        // After a crash, macOS asks whether to reopen the windows.
        let dontReopen = launched.buttons["Don\u{2019}t Reopen"].firstMatch
        if dontReopen.waitForExistence(timeout: 2) { dontReopen.click() }
        if !launched.windows.firstMatch.waitForExistence(timeout: 5) { safePress("n", .command) }
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        return launched
    }

    /// One tab with real text and one blank tab, both untitled. Quit with
    /// windows kept, relaunch: the real text comes back, the blank tab
    /// does not.
    func testQuitKeepsRealTextAndDropsTheBlankWindow() throws {
        clearSavedWindows()
        _ = launchKeepingWindows(true)
        XCTAssertEqual(tabCount, 0, "saved windows came back at the start")
        safeType("keep this text")
        safePress("t", .command)
        waitUntil(10, "Cmd+T made no second tab") { self.tabCount == 2 }
        safeType("   ")
        safePress(.return, [])
        RunLoop.current.run(until: Date().addingTimeInterval(1.5)) // let state and autosave settle
        safePress("q", .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Quit stopped on a question")

        expectExactlyOneRestoredWindow(holding: "keep this text")
    }

    /// A blank untitled window (off the saved list) gets real text, and
    /// Quit comes at once, windows kept: the text comes back.
    func testBlankWindowGivenTextJustBeforeQuitComesBack() throws {
        clearSavedWindows()
        _ = launchKeepingWindows(true)
        XCTAssertEqual(tabCount, 0, "saved windows came back at the start")
        safeType("  ")
        safeType("real words")
        safePress("q", .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Quit stopped on a question")
        expectExactlyOneRestoredWindow(holding: "  real words")
    }

    /// Relaunches reading the saved windows and checks exactly one
    /// document window came back, with no tabs, holding `expected`
    /// (so no empty or blank window came back beside it). Leaves no
    /// saved windows.
    private func expectExactlyOneRestoredWindow(holding expected: String,
                                                file: StaticString = #filePath, line: UInt = #line) {
        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["-ApplePersistenceIgnoreState", "NO", "-NSQuitAlwaysKeepsWindows", "YES"]
        relaunched.launch()
        app = relaunched
        waitUntil(15, "no window came back", file: file, line: line) { relaunched.windows.count > 0 }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let windows = documentWindows()
        var texts: [String] = []
        if tabCount > 0 {
            for number in 1...tabCount {
                safePress("\(number)", .control)
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                texts.append(text)
            }
        } else {
            texts = windows.map { ($0.textViews.firstMatch.value as? String) ?? "" }
        }
        XCTAssertEqual(windows.count, 1, "document windows came back: \(windows.map(\.title)) \(texts)", file: file, line: line)
        XCTAssertEqual(tabCount, 0, "tabs came back: \(texts.map(\.debugDescription))", file: file, line: line)
        XCTAssertEqual(texts, [expected], "restored texts", file: file, line: line)
        XCTAssertFalse(texts.contains { $0.allSatisfy(\.isWhitespace) }, "an empty or blank window came back",
                       file: file, line: line)
        // Leave no saved windows for later runs.
        relaunched.terminate()
        clearSavedWindows()
    }

    /// The same two tabs, quitting without keeping windows: AppKit asks
    /// about the real text only; Cancel keeps both tabs open.
    func testCancelledQuitKeepsBothTabs() throws {
        clearSavedWindows()
        _ = launchKeepingWindows(false)
        safeType("keep this text")
        safePress("t", .command)
        waitUntil(10, "Cmd+T made no second tab") { self.tabCount == 2 }
        safeType("   ")
        safePress("q", .command)
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Quit asked nothing about the real text; "
                      + "sheets: \(app.sheets.count), dialogs: \(app.dialogs.count)")
        cancel.click()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(app.state, .runningForeground, "the app quit although Quit was cancelled")
        XCTAssertEqual(tabCount, 2, "a tab closed although Quit was cancelled")
        // Both keep their text: the real one and the blank one.
        safePress("1", .control)
        waitForText("keep this text", "the first tab lost its text")
        safePress("2", .control)
        waitForText("   ", "the blank tab lost its spaces")
        app.terminate()
    }

    // MARK: Change 6

    /// Ctrl+1 and Ctrl+2 pick the first and second tab, Ctrl+9 the last.
    func testControlDigitsPickTabs() throws {
        launchWithTestSettings()
        safeType("one")
        safePress("t", .command)
        waitUntil(10, "Cmd+T made no second tab") { self.tabCount == 2 }
        safeType("two")
        safePress("t", .command)
        waitUntil(10, "Cmd+T made no third tab") { self.tabCount == 3 }
        safeType("three")
        safePress("1", .control)
        waitForText("one", "Ctrl+1 did not pick the first tab")
        safePress("2", .control)
        waitForText("two", "Ctrl+2 did not pick the second tab")
        safePress("9", .control)
        waitForText("three", "Ctrl+9 did not pick the last tab")
        safePress("1", .control)
        waitForText("one", "Ctrl+1 again")
        // No tab 5: nothing changes and nothing is typed.
        safePress("5", .control)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(text, "one")
        app.menuBars.menuBarItems["Window"].click()
        let tab2 = app.menuBars.menuBarItems["Window"].menuItems["Tab 2"]
        XCTAssertTrue(tab2.waitForExistence(timeout: 5))
        XCTAssertTrue(tab2.isEnabled)
        XCTAssertFalse(app.menuBars.menuBarItems["Window"].menuItems["Tab 4"].isEnabled, "no fourth tab")
        safePress(.escape, [])
    }

    // MARK: Changes 2 and 3

    func testGutterAndMapShowAndHideFromTheViewMenu() throws {
        launchWithTestSettings()
        XCTAssertTrue(map.waitForExistence(timeout: 5), "no document map by default")
        XCTAssertFalse(gutterShows, "line numbers are off by default since 1.2.1")
        XCTAssertGreaterThan(map.frame.minX, textView.frame.midX, "the map is on the right")
        let width = frontWindow.frame.width

        // 1.2.1: turn them on first, so the rest runs as in 1.2.0.
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuBarItems["View"].menuItems["Show Line Numbers"].click()
        waitUntil(5, "the gutter did not show") { self.gutterShows }

        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuBarItems["View"].menuItems["Show Line Numbers"].click()
        waitUntil(5, "the gutter did not hide") { !self.gutterShows }
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuBarItems["View"].menuItems["Show Document Map"].click()
        waitUntil(5, "the map did not hide") { !self.map.exists }
        XCTAssertEqual(frontWindow.frame.width, width, "the window keeps its size")

        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuBarItems["View"].menuItems["Show Line Numbers"].click()
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuBarItems["View"].menuItems["Show Document Map"].click()
        waitUntil(5, "the gutter and the map did not come back") { self.gutterShows && self.map.exists }

        // Wrap to Page hides both.
        safePress("w", [.command, .shift])
        waitUntil(5, "Wrap to Page kept the map") { !self.map.exists }
        // The page sits in the middle of the window, so the offset test
        // does not apply; the unit tests check the ruler is off.
    }

    // MARK: Screenshots for root

    /// The share of pixels in `rect` (window points, top-left origin) that
    /// differ by more than 3% in any channel between two window pictures.
    private func changedFraction(_ a: XCUIScreenshot, _ b: XCUIScreenshot, in rect: CGRect) throws -> Double {
        let first = try XCTUnwrap(NSBitmapImageRep(data: a.pngRepresentation))
        let second = try XCTUnwrap(NSBitmapImageRep(data: b.pngRepresentation))
        XCTAssertEqual(first.pixelsWide, second.pixelsWide)
        let scale = CGFloat(first.pixelsWide) / a.image.size.width
        var changed = 0, total = 0
        for y in stride(from: Int(rect.minY * scale), to: Int(rect.maxY * scale), by: 2) {
            for x in stride(from: Int(rect.minX * scale), to: Int(rect.maxX * scale), by: 2) {
                guard let p = first.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let q = second.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += 1
                if abs(p.redComponent - q.redComponent) > 0.03 || abs(p.greenComponent - q.greenComponent) > 0.03
                    || abs(p.blueComponent - q.blueComponent) > 0.03 { changed += 1 }
            }
        }
        XCTAssertGreaterThan(total, 100, "the band lies inside the picture")
        return total > 0 ? Double(changed) / Double(total) : 0
    }

    /// Window-cropped screenshots: the default window (1.2.1: no line
    /// numbers, the map's box hidden) at rest and with the mouse over the
    /// map; a window with the gutter, the map and about 60 lines; Settings
    /// > New Document and Keyboard; and the window right after Cmd+T with
    /// two tabs.
    func testScreenshots() throws {
        let url = try fixtureFolder("gutter-map").appendingPathComponent("sixty.txt")
        launchWithTestSettings(opening: url.path)
        let window = frontWindow
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        XCTAssertFalse(gutterShows, "line numbers are off by default since 1.2.1")
        // The mouse well away from the map: the box is hidden.
        textView.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).hover()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let rest = window.screenshot()
        attachScreenshot("m121-map-at-rest", rest)
        // Over the map: the box fades in (0.15 s).
        map.hover()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let hovered = window.screenshot()
        attachScreenshot("m121-map-hovered", hovered)
        // The box covers the lines on screen, at the map's top: the band
        // there must change between the two pictures (review fix 4).
        let band = CGRect(x: map.frame.minX - window.frame.minX + 10, y: map.frame.minY - window.frame.minY + 4,
                          width: map.frame.width - 20, height: 30)
        let changed = try changedFraction(rest, hovered, in: band)
        XCTAssertGreaterThan(changed, 0.2, "the box did not show on hover (\(changed) of the band changed)")
        textView.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).hover()

        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuBarItems["View"].menuItems["Show Line Numbers"].click()
        waitUntil(5, "the gutter did not show") { self.gutterShows }
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        attachScreenshot("m12-gutter-and-map", window.screenshot())

        safePress(",", .command)
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        for name in ["New Document", "Keyboard"] {
            let tab = settings.tabs[name].exists ? settings.tabs[name] : settings.radioButtons[name]
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "no tab \(name)")
            tab.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            attachScreenshot(name == "Keyboard" ? "m12-settings-keyboard" : "m12-settings-new-document", settings.screenshot())
        }
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))

        safePress("t", .command)
        waitUntil(10, "Cmd+T made no second tab") { self.tabCount == 2 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        attachScreenshot("m12-new-tab", frontWindow.screenshot())
    }
}
