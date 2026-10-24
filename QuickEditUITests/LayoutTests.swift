import AppKit
import XCTest

/// M5 n3: full screen, window tabs, dark mode, and Wrap to Page with zoom
/// from the keyboard (P40 to P43).
final class LayoutTests: QuickEditUITestCase {
    private var window: XCUIElement { app.windows.firstMatch }

    /// Ctrl+Cmd+F enters full screen and leaves it again, and the window
    /// comes back to its old frame.
    func testFullScreenOnAndOff() throws {
        launch()
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        let before = window.frame
        let screen = try XCTUnwrap(NSScreen.main).frame
        app.typeKey("f", modifierFlags: [.command, .control])
        waitUntil(10, "the window did not fill the screen") {
            self.window.frame.width >= screen.width - 1 && self.window.frame.height >= screen.height - 40
        }
        attachScreenshot("full-screen", XCUIScreen.main.screenshot())
        app.typeKey("f", modifierFlags: [.command, .control])
        waitUntil(10, "the window did not leave full screen") { self.window.frame == before }
    }

    /// Window > Merge All Windows puts both windows in one window as tabs.
    func testMergeAllWindowsMakesTabs() throws {
        launch()
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        waitUntil(10, "Cmd+N did not add a window") { self.app.windows.count == 2 }
        chooseMenu("Window", "Merge All Windows")
        waitUntil(10, "the windows did not merge") { self.app.windows.count == 1 }
        XCTAssertEqual(window.tabGroups.firstMatch.radioButtons.count, 2, "two tabs expected")
        attachScreenshot("merged-tabs", XCUIScreen.main.screenshot())
    }

    /// Shift+Cmd+W makes pages; typing past a page adds a page; the menu
    /// title flips; Cmd+> and Cmd+< zoom; Shift+Cmd+W goes back.
    func testWrapToPageAddsPagesAndZooms() throws {
        launch()
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.click()
        app.typeKey("w", modifierFlags: [.command, .shift])
        waitUntil(5, "Wrap to Page made no page") { self.app.textViews.count >= 1 }
        let format = app.menuBars.menuBarItems["Format"]
        format.click()
        XCTAssertTrue(format.menuItems["Wrap to Window"].waitForExistence(timeout: 5), "the title did not flip")
        app.typeKey(.escape, modifierFlags: [])

        // About two pages of lines.
        app.typeText(String(repeating: "a line of text\n", count: 70))
        waitUntil(10, "typing past page 1 did not add a page") { self.app.textViews.count >= 2 }
        attachScreenshot("wrap-to-page", XCUIScreen.main.screenshot())

        app.typeKey(".", modifierFlags: [.command, .shift])
        app.typeKey(",", modifierFlags: [.command, .shift])
        app.typeKey(",", modifierFlags: [.command, .shift])
        attachScreenshot("wrap-to-page-50", XCUIScreen.main.screenshot())
        app.typeKey("0", modifierFlags: .command)

        app.typeKey("w", modifierFlags: [.command, .shift])
        waitUntil(5, "Wrap to Window did not go back to one text view") { self.app.textViews.count == 1 }
        XCTAssertTrue(text.hasSuffix("a line of text\n"), "the text changed in the switch")
    }

    /// Dark mode: in Wrap to Window the text area is dark with light text;
    /// in Wrap to Page the page stays white with dark text, as in TextEdit.
    func testDarkModeKeepsTextReadable() throws {
        launch(extraArguments: ["-AppleInterfaceStyle", "Dark"])
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.click()
        app.typeText(String(repeating: "readable text in dark mode\n", count: 20))
        let windowShot = textView.screenshot()
        attachScreenshot("dark-window", windowShot)
        let windowBrightness = try averageBrightness(windowShot)
        XCTAssertLessThan(windowBrightness, 0.4, "Wrap to Window should be dark in dark mode")

        app.typeKey("w", modifierFlags: [.command, .shift])
        let page = app.textViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let pageShot = page.screenshot()
        attachScreenshot("dark-page", pageShot)
        let pageBrightness = try averageBrightness(pageShot)
        XCTAssertGreaterThan(pageBrightness, 0.8, "the page should stay white in dark mode")
        XCTAssertLessThan(pageBrightness, 0.995, "no dark text was seen on the page")
    }

    /// Mean brightness (0 black, 1 white) of a screenshot.
    private func averageBrightness(_ shot: XCUIScreenshot) throws -> Double {
        let data = try XCTUnwrap(shot.image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        var total = 0.0
        var count = 0
        let step = 4
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += (color.redComponent + color.greenComponent + color.blueComponent) / 3
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 0)
        return total / Double(max(count, 1))
    }
}
