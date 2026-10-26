import AppKit
import XCTest

/// M11 done-tests 1 to 6 (docs/plans/M11.md): New Tab (Cmd+T), Close Tab
/// (Cmd+W), Show Next Tab (Ctrl+Tab), Show Previous Tab (Ctrl+Shift+Tab),
/// and a tab bar that shows only at 2 or more tabs. The app runs on its
/// own settings suite (`-QETestDefaultsSuite`, Debug only), never the
/// user's real settings. Keys go through SafeTyping only.
@MainActor
final class TabUITests: QuickEditUITestCase {
    private func launchForTabs(reset: Bool = true) {
        var arguments = ["-QETestDefaultsSuite", ShortcutUITests.suite,
                         // The typed words must arrive as typed.
                         "-NSAutomaticCapitalizationEnabled", "NO"]
        if reset { arguments += ["-QETestDefaultsSuiteReset", "YES"] }
        launch(extraArguments: arguments)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
    }

    private var frontWindow: XCUIElement { app.windows.firstMatch }

    /// Tabs in the front window's tab bar; 0 when the bar is hidden.
    private var tabCount: Int {
        let group = frontWindow.tabGroups.firstMatch
        return group.exists ? group.tabs.count : 0
    }

    private func documentWindows() -> [XCUIElement] {
        app.windows.allElementsBoundByIndex.filter { $0.title != "Settings" }
    }

    /// Closes the front tab of an edited untitled document: Cmd+W, then
    /// Delete on the save sheet.
    private func closeEditedTab(file: StaticString = #filePath, line: UInt = #line) {
        safePress("w", .command, file: file, line: line)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "no save sheet", file: file, line: line)
        let delete = sheet.buttons["Delete"]
        XCTAssertTrue(delete.exists, "buttons: \(sheet.buttons.allElementsBoundByIndex.map(\.title))",
                      file: file, line: line)
        delete.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), file: file, line: line)
    }

    private func waitForText(_ expected: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        waitUntil(5, "\(message): the text is \(self.text.debugDescription)", file: file, line: line) {
            self.text == expected
        }
    }

    private func menuItem(_ menu: String, _ title: String) -> XCUIElement {
        app.menuBars.menuBarItems[menu].menuItems[title]
    }

    // MARK: Done-tests 1 to 3

    /// Cmd+T twice makes three tabs with the bar; Ctrl+Tab and
    /// Ctrl+Shift+Tab move through them and wrap around, each tab keeping
    /// its text; Cmd+W closes one tab at a time, the bar hides at one tab,
    /// and the last Cmd+W closes the window.
    func testNewTabNextPreviousAndCloseTab() throws {
        launchForTabs()
        XCTAssertEqual(tabCount, 0, "one tab: no tab bar")
        safeType("one")
        safePress("t", .command)
        waitUntil(10, "Cmd+T made no second tab (tabs: \(self.tabCount))") { self.tabCount == 2 }
        XCTAssertEqual(documentWindows().count, 1, "New Tab must not make a separate window")
        waitForText("", "the new tab is not empty")
        safeType("two")
        safePress("t", .command)
        waitUntil(10, "Cmd+T made no third tab") { self.tabCount == 3 }
        safeType("three")
        attachScreenshot("three-tabs", frontWindow.screenshot())
        XCTAssertEqual(frontWindow.tabGroups.firstMatch.tabs.allElementsBoundByIndex.map(\.title).count, 3)

        safePress(.tab, [.control])
        waitForText("one", "Ctrl+Tab from the last tab did not wrap to the first")
        safePress(.tab, [.control])
        waitForText("two", "Ctrl+Tab did not go to the next tab")
        safePress(.tab, [.control, .shift])
        waitForText("one", "Ctrl+Shift+Tab did not go to the previous tab")
        safePress(.tab, [.control, .shift])
        waitForText("three", "Ctrl+Shift+Tab from the first tab did not wrap to the last")

        // File > Close says Close Tab while there are tabs.
        app.menuBars.menuBarItems["File"].click()
        XCTAssertTrue(menuItem("File", "Close Tab").waitForExistence(timeout: 5), "no Close Tab item")
        safePress(.escape, [])

        closeEditedTab()
        waitUntil(10, "Cmd+W did not close only the tab") { self.tabCount == 2 }
        XCTAssertEqual(documentWindows().count, 1)
        closeEditedTab()
        waitUntil(10, "one tab left: the tab bar did not hide") { self.tabCount == 0 }
        XCTAssertEqual(documentWindows().count, 1)
        XCTAssertTrue(["one", "two"].contains(text), "the last tab lost its text: \(text.debugDescription)")
        app.menuBars.menuBarItems["File"].click()
        XCTAssertTrue(menuItem("File", "Close").waitForExistence(timeout: 5), "one tab: the item is Close again")
        safePress(.escape, [])
        closeEditedTab()
        waitUntil(10, "the last Cmd+W did not close the window") { self.documentWindows().isEmpty }
    }

    /// The + button in the tab bar adds a tab too.
    func testPlusButtonInTheTabBarAddsATab() throws {
        launchForTabs()
        safePress("t", .command)
        waitUntil(10, "Cmd+T made no second tab") { self.tabCount == 2 }
        let plus = frontWindow.buttons.matching(NSPredicate(
            format: "label ==[c] 'New Tab' OR identifier CONTAINS[c] 'newtab' OR identifier CONTAINS[c] 'addtab'")).firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 5),
                      "no + button; buttons: \(frontWindow.buttons.allElementsBoundByIndex.map { "\($0.identifier)/\($0.label)" })")
        plus.click()
        waitUntil(10, "the + button made no third tab") { self.tabCount == 3 }
        XCTAssertEqual(documentWindows().count, 1)
    }

    // MARK: Done-test 4

    /// Merge All Windows shows the bar; Move Tab to New Window leaves two
    /// windows of one tab each, with no bar. The two windows come from
    /// Cmd+T and Move Tab to New Window, not Cmd+N, so the user's system
    /// "Prefer tabs" setting cannot change the result (with Always, Cmd+N
    /// makes a tab). A `-AppleWindowTabbingMode` launch argument does not
    /// set that preference: with "always" Cmd+N still made a window
    /// (measured 2026-10-26).
    func testMergeAndMoveTabToNewWindow() throws {
        launchForTabs()
        safePress("t", .command)
        waitUntil(10, "Cmd+T made no second tab") { self.documentWindows().count == 1 && self.tabCount == 2 }
        chooseMenu("Window", "Move Tab to New Window")
        waitUntil(10, "Move Tab to New Window left \(self.documentWindows().count) windows") {
            self.documentWindows().count == 2
        }
        for window in documentWindows() {
            XCTAssertFalse(window.tabGroups.firstMatch.exists, "a window of one tab shows a tab bar")
        }
        chooseMenu("Window", "Merge All Windows")
        waitUntil(10, "the windows did not merge") { self.documentWindows().count == 1 && self.tabCount == 2 }
        chooseMenu("Window", "Move Tab to New Window")
        waitUntil(10, "Move Tab to New Window left \(self.documentWindows().count) windows") {
            self.documentWindows().count == 2
        }
        for window in documentWindows() {
            XCTAssertFalse(window.tabGroups.firstMatch.exists, "a window of one tab shows a tab bar")
        }
    }

    // MARK: Done-test 5

    /// New Tab, Show Next Tab and Show Previous Tab are rows in Settings >
    /// Keyboard. A changed New Tab key works at once and after a
    /// relaunch. Ctrl+Tab is recorded (not taken as a focus move).
    func testNewTabKeyChangesAtOnceAndAfterARelaunch() throws {
        launchForTabs()
        safePress(",", .command)
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "no Settings window")
        let tab = settings.tabs["Keyboard"].exists ? settings.tabs["Keyboard"] : settings.radioButtons["Keyboard"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "no Keyboard tab")
        tab.click()
        XCTAssertTrue(settings.tables["KeyboardShortcutsTable"].waitForExistence(timeout: 5))
        for (id, keys) in [("file.newTab", "\u{2318}T"), ("window.previousTab", "\u{2303}\u{21E7}\u{21E5}"),
                           ("window.nextTab", "\u{2303}\u{21E5}")] {
            let button = settings.buttons["Shortcut-\(id)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "no Keyboard row for \(id)")
            XCTAssertEqual(button.value as? String, keys, id)
        }

        // Ctrl+Tab is recorded: giving it to Show Previous Tab clashes with Show Next Tab.
        settings.buttons["Shortcut-window.previousTab"].click()
        XCTAssertTrue(settings.staticTexts["Shortcut-window.previousTab"].waitForExistence(timeout: 5), "not recording")
        safePress(.tab, [.control])
        let message = settings.staticTexts["KeyboardShortcutMessage"]
        let clash = "\u{2303}\u{21E5} is already used by \u{201C}Show Next Tab\u{201D} in the Window menu."
        waitUntil(5, "Ctrl+Tab was not recorded: \(String(describing: message.value))") {
            (message.value as? String)?.hasSuffix(clash) ?? false
        }
        safePress(.escape, [])

        let newTab = settings.buttons["Shortcut-file.newTab"]
        newTab.click()
        XCTAssertTrue(settings.staticTexts["Shortcut-file.newTab"].waitForExistence(timeout: 5), "not recording")
        safePress("t", [.command, .option, .control])
        let changed = settings.buttons["Shortcut-file.newTab"]
        waitUntil(5, "New Tab's shortcut did not become Ctrl+Option+Cmd+T") {
            changed.exists && (changed.value as? String) == "\u{2303}\u{2325}\u{2318}T"
        }
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))

        safePress("t", [.command, .option, .control])
        waitUntil(10, "Ctrl+Option+Cmd+T made no tab") { self.tabCount == 2 }
        safePress("t", .command)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(tabCount, 2, "Cmd+T still makes a tab")

        app.terminate()
        launchForTabs(reset: false)
        XCTAssertEqual(tabCount, 0)
        safePress("t", [.command, .option, .control])
        waitUntil(10, "Ctrl+Option+Cmd+T made no tab after the relaunch") { self.tabCount == 2 }
    }

    // MARK: Done-test 6 and the off states

    /// The Window and View menus have exactly one item for each tab action
    /// and no Show or Hide Tab Bar item, also once AppKit has seen tabs.
    func testMenusHaveOneItemPerTabActionAndNoTabBarItem() throws {
        launchForTabs()
        safePress("t", .command)
        waitUntil(10, "Cmd+T made no second tab") { self.tabCount == 2 }
        let window = app.menuBars.menuBarItems["Window"]
        window.click()
        for action in ["selectNextTab:", "selectPreviousTab:", "mergeAllWindows:", "moveTabToNewWindow:"] {
            XCTAssertEqual(window.menuItems.matching(identifier: action).count, 1,
                           "\(action); Window menu: \(window.menuItems.allElementsBoundByIndex.map(\.title))")
        }
        XCTAssertTrue(window.menuItems["Show Next Tab"].isEnabled)
        safePress(.escape, [])
        let view = app.menuBars.menuBarItems["View"]
        view.click()
        XCTAssertEqual(view.menuItems.matching(identifier: "toggleTabBar:").count, 0,
                       "View menu: \(view.menuItems.allElementsBoundByIndex.map(\.title))")
        safePress(.escape, [])
        let file = app.menuBars.menuBarItems["File"]
        file.click()
        XCTAssertEqual(file.menuItems.matching(identifier: "newWindowForTab:").count, 1)
        safePress(.escape, [])
    }

    /// With Settings in front, Cmd+T adds a tab to the document window,
    /// and Show Next Tab is off.
    func testCmdTWithSettingsInFrontAddsATabToTheDocumentWindow() throws {
        launchForTabs()
        safePress(",", .command)
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "no Settings window")
        safePress("t", .command)
        let document = app.windows.matching(NSPredicate(format: "title != 'Settings'")).firstMatch
        waitUntil(10, "Cmd+T in Settings made no tab in the document window") {
            document.tabGroups.firstMatch.exists && document.tabGroups.firstMatch.tabs.count == 2
        }
        XCTAssertEqual(documentWindows().count, 1)
        // Settings' own tab view (New Document, Open and Save, Keyboard) is
        // a tab group too; no document may be a tab in it.
        let settingsTabs = settings.tabGroups.allElementsBoundByIndex.flatMap { $0.tabs.allElementsBoundByIndex.map(\.title) }
        XCTAssertFalse(settingsTabs.contains { $0.hasPrefix("Untitled") }, "Settings took a tab: \(settingsTabs)")
        // Settings in front again: Show Next Tab is off there.
        safePress(",", .command)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Window"].click()
        let next = menuItem("Window", "Show Next Tab")
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertFalse(next.isEnabled, "Show Next Tab is on while Settings is in front")
        safePress(.escape, [])
    }

    /// While the Save panel sheet is open, New Tab is off and Cmd+T adds nothing.
    func testNewTabIsOffWhileTheSavePanelIsOpen() throws {
        launchForTabs()
        safeType("unsaved")
        safePress("s", .command)
        _ = savePanel()
        app.menuBars.menuBarItems["File"].click()
        let newTab = menuItem("File", "New Tab")
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        XCTAssertFalse(newTab.isEnabled, "New Tab is on under the Save panel")
        safePress(.escape, [])
        safePress("t", .command)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(documentWindows().count, 1)
        XCTAssertEqual(tabCount, 0)
        // Cancel the Save panel.
        safePress(.escape, [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
    }

    /// In full screen, Cmd+T adds a tab to the full-screen window.
    func testCmdTInFullScreenAddsATab() throws {
        launchForTabs()
        let screen = try XCTUnwrap(NSScreen.main).frame
        safePress("f", [.command, .control])
        waitUntil(10, "the window did not fill the screen") {
            self.frontWindow.frame.width >= screen.width - 1 && self.frontWindow.frame.height >= screen.height - 40
        }
        safePress("t", .command)
        // In full screen the tab bar hides with the title bar, and pressing
        // Esc to close a menu would leave full screen, so the new tab is
        // checked by the window in front: Untitled 2, full screen, and the
        // only document window (no separate window).
        let fullScreenFront: (String) -> Bool = { title in
            let windows = self.documentWindows()
            return windows.count == 1 && windows[0].title.hasPrefix(title) && windows[0].frame.width >= screen.width - 1
        }
        waitUntil(10, "Cmd+T in full screen made no full-screen tab in front: "
                  + "\(self.documentWindows().map { "\($0.title) \($0.frame)" })") { fullScreenFront("Untitled 2") }
        attachScreenshot("full-screen-tabs", XCUIScreen.main.screenshot())
        // The new tab is unedited, so Cmd+W closes it without asking; the
        // first tab is in front again, still full screen.
        safePress("w", .command)
        waitUntil(10, "Cmd+W did not close the tab back to the first one: "
                  + "\(self.documentWindows().map { "\($0.title) \($0.frame)" })") {
            fullScreenFront("Untitled") && !self.documentWindows()[0].title.hasPrefix("Untitled 2")
        }
        safePress("f", [.command, .control])
        waitUntil(10, "the window did not leave full screen") { self.frontWindow.frame.width < screen.width - 1 }
    }
}
