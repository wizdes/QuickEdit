import XCTest

/// M9 done-test 2 (user decision U2): a changed shortcut works at once,
/// works again after a relaunch, and a clash is refused with a message.
/// The app runs on its own settings suite (`-QETestDefaultsSuite`, Debug
/// only), never the user's real settings.
@MainActor
final class ShortcutUITests: QuickEditUITestCase {
    static let suite = "dev.yili.QuickEdit.uitests"

    private func launchWithTestSettings(reset: Bool) {
        var arguments = ["-QETestDefaultsSuite", Self.suite]
        if reset { arguments += ["-QETestDefaultsSuiteReset", "YES"] }
        launch(extraArguments: arguments)
    }

    /// Opens Settings > Keyboard; returns the Settings window.
    private func openKeyboardTab(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        safePress(",", .command)
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "no Settings window", file: file, line: line)
        let tab = settings.tabs["Keyboard"].exists ? settings.tabs["Keyboard"] : settings.radioButtons["Keyboard"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "no Keyboard tab", file: file, line: line)
        tab.click()
        XCTAssertTrue(settings.tables["KeyboardShortcutsTable"].waitForExistence(timeout: 5), file: file, line: line)
        return settings
    }

    private func documentWindowCount() -> Int {
        app.windows.allElementsBoundByIndex.filter { $0.title != "Settings" }.count
    }

    func testChangedShortcutWorksAtOnceAndAfterARelaunch() throws {
        launchWithTestSettings(reset: true)
        let settings = openKeyboardTab()
        let newShortcut = settings.buttons["Shortcut-file.new"]
        XCTAssertTrue(newShortcut.waitForExistence(timeout: 5))
        XCTAssertEqual(newShortcut.value as? String, "\u{2318}N")
        newShortcut.click()
        XCTAssertTrue(settings.staticTexts["Shortcut-file.new"].waitForExistence(timeout: 5), "not recording")
        safePress("n", [.command, .option, .control])
        let changed = settings.buttons["Shortcut-file.new"]
        waitUntil(5, "New's shortcut did not become Ctrl+Option+Cmd+N") {
            changed.exists && (changed.value as? String) == "\u{2303}\u{2325}\u{2318}N"
        }
        XCTAssertTrue(settings.buttons["ResetShortcut-file.new"].exists, "no reset button on the changed row")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))

        // At once: Ctrl+Option+Cmd+N makes a new window; Cmd+N no longer does.
        // (Not Shift+Cmd+Y: the Stickies service has it, and the tab refuses it.)
        let before = documentWindowCount()
        safePress("n", [.command, .option, .control])
        waitUntil(5, "Ctrl+Option+Cmd+N made no new window") { self.documentWindowCount() == before + 1 }
        safePress("n", .command)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(documentWindowCount(), before + 1, "Cmd+N still makes a window")

        // After a relaunch on the same settings.
        app.terminate()
        launchWithTestSettings(reset: false)
        let again = documentWindowCount()
        safePress("n", [.command, .option, .control])
        waitUntil(5, "Ctrl+Option+Cmd+N made no new window after the relaunch") { self.documentWindowCount() == again + 1 }

        // Restore Keyboard Defaults puts Cmd+N back.
        let restored = openKeyboardTab()
        restored.buttons["RestoreKeyboardDefaults"].click()
        let reset = restored.buttons["Shortcut-file.new"]
        waitUntil(5, "New's shortcut was not restored") { reset.exists && (reset.value as? String) == "\u{2318}N" }
    }

    func testClashIsRefusedWithAMessage() throws {
        launchWithTestSettings(reset: true)
        let settings = openKeyboardTab()
        let save = settings.buttons["Shortcut-file.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.click()
        let message = settings.staticTexts["KeyboardShortcutMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        waitUntil(5, "no recording hint: \(String(describing: message.value))") {
            (message.value as? String) == "Press Esc to cancel, or Delete to remove the shortcut."
        }
        safePress("o", .command)
        let expected = "\u{2318}O is already used by \u{201C}Open\u{2026}\u{201D} in the File menu."
        waitUntil(5, "no clash message: \(String(describing: message.value))") {
            (message.value as? String)?.hasSuffix(expected) ?? false
        }
        // Cmd+O was taken by the recorder, so no Open panel.
        XCTAssertFalse(app.dialogs.firstMatch.exists || app.windows["Open"].exists, "Cmd+O opened the Open panel")
        attachScreenshot("settings-keyboard-clash", settings.screenshot())
        safePress(.escape, [])
        let kept = settings.buttons["Shortcut-file.save"]
        waitUntil(5, "Save's shortcut changed") { kept.exists && (kept.value as? String) == "\u{2318}S" }
        XCTAssertEqual(message.value as? String, "")
    }
}
