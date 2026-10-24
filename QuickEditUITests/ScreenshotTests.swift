import XCTest

/// Screenshots for root to read: the untitled window, the File and Edit menus,
/// and the Save panel with the ".txt" checkbox. Exported from the .xcresult.
final class ScreenshotTests: QuickEditUITestCase {
    func testScreenshots() throws {
        launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1.0)) // let the caret blink on
        attachScreenshot("01-untitled-window", window.screenshot())
        attachScreenshot("01b-untitled-window-full-screen", XCUIScreen.main.screenshot())

        for (index, title) in ["File", "Edit", "Format", "Window"].enumerated() {
            let menu = app.menuBars.menuBarItems[title]
            XCTAssertTrue(menu.waitForExistence(timeout: 5), "no \(title) menu")
            menu.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            attachScreenshot(String(format: "%02d-%@-menu", index + 2, title), XCUIScreen.main.screenshot())
            app.typeKey(.escape, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }

        let appMenu = app.menuBars.menuBarItems.element(boundBy: 1)
        appMenu.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        attachScreenshot("06-app-menu", XCUIScreen.main.screenshot())
        app.typeKey(.escape, modifierFlags: [])

        textView.click()
        app.typeText("shot")
        app.typeKey("s", modifierFlags: .command)
        let sheet = savePanel()
        XCTAssertTrue(sheet.checkBoxes["If no extension is provided, use \u{201C}.txt\u{201D}."]
            .waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        attachScreenshot("07-save-panel", window.screenshot())
        attachScreenshot("07b-save-panel-full-screen", XCUIScreen.main.screenshot())
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }
}
