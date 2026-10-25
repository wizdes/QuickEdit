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
        // One full-screen item only: AppKit must not add its own next to
        // the View menu's "Enter Full Screen".
        let view = app.menuBars.menuBarItems["View"]
        view.click()
        let fullScreenItems = view.menuItems.matching(identifier: "toggleFullScreen:")
        XCTAssertEqual(fullScreenItems.count, 1,
                       "View menu: \(view.menuItems.allElementsBoundByIndex.map(\.title))")
        safePress(.escape, [])
        safePress("f", [.command, .control])
        waitUntil(10, "the window did not fill the screen") {
            self.window.frame.width >= screen.width - 1 && self.window.frame.height >= screen.height - 40
        }
        attachScreenshot("full-screen", XCUIScreen.main.screenshot())
        safePress("f", [.command, .control])
        waitUntil(10, "the window did not leave full screen") { self.window.frame == before }
    }

    /// Window > Merge All Windows puts both windows in one window as tabs.
    func testMergeAllWindowsMakesTabs() throws {
        launch()
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        safePress("n", .command)
        waitUntil(10, "Cmd+N did not add a window") { self.app.windows.count == 2 }
        chooseMenu("Window", "Merge All Windows")
        waitUntil(10, "the windows did not merge") { self.app.windows.count == 1 }
        // macOS 27 reports each tab as a Tab element, not a radio button.
        XCTAssertEqual(window.tabGroups.firstMatch.tabs.count, 2, "two tabs expected")
        attachScreenshot("merged-tabs", XCUIScreen.main.screenshot())
    }

    /// Shift+Cmd+W makes pages; typing past a page adds a page; the menu
    /// title flips; Cmd+> and Cmd+< zoom; Shift+Cmd+W goes back.
    func testWrapToPageAddsPagesAndZooms() throws {
        // macOS capitalizes the first word of each typed line unless this
        // system setting is off; the text below must arrive as typed.
        launch(extraArguments: ["-NSAutomaticCapitalizationEnabled", "NO"])
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.click()
        safePress("w", [.command, .shift])
        waitUntil(5, "Wrap to Page made no page") { self.app.textViews.count >= 1 }
        let format = app.menuBars.menuBarItems["Format"]
        format.click()
        XCTAssertTrue(format.menuItems["Wrap to Window"].waitForExistence(timeout: 5), "the title did not flip")
        safePress(.escape, [])

        // About two pages of lines.
        safeType(String(repeating: "a line of text\n", count: 70))
        waitUntil(10, "typing past page 1 did not add a page") { self.app.textViews.count >= 2 }
        attachScreenshot("wrap-to-page", XCUIScreen.main.screenshot())

        safePress(".", [.command, .shift])
        safePress(",", [.command, .shift])
        safePress(",", [.command, .shift])
        attachScreenshot("wrap-to-page-50", XCUIScreen.main.screenshot())
        safePress("0", .command)

        safePress("w", [.command, .shift])
        waitUntil(5, "Wrap to Window did not go back to one text view") { self.app.textViews.count == 1 }
        XCTAssertTrue(text.hasSuffix("a line of text\n"), "the text changed in the switch")
    }

    /// Dark mode: in Wrap to Window the text area is dark with light text;
    /// in Wrap to Page the page stays white with dark text, as in TextEdit.
    /// The text comes from a fixture file made by build.sh (20 lines of
    /// "readable text in dark mode"), not from typing, so a long typed
    /// string cannot land in another app.
    func testDarkModeKeepsTextReadable() throws {
        let url = try fixtureFolder("dark-mode").appendingPathComponent("dark.txt")
        launch(opening: url.path, extraArguments: ["-AppleInterfaceStyle", "Dark"])
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        XCTAssertEqual(text, String(repeating: "readable text in dark mode\n", count: 20),
                       "the dark mode fixture did not open")
        textView.click()
        let windowShot = textView.screenshot()
        attachScreenshot("dark-window", windowShot)
        let windowBrightness = try averageBrightness(windowShot)
        XCTAssertLessThan(windowBrightness, 0.4, "Wrap to Window should be dark in dark mode")

        safePress("w", [.command, .shift])
        let page = app.textViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        // The page's text view is taller than the window, so its own
        // screenshot also shows the desktop below the window. Measure only
        // the part of the page the window shows.
        let shownPage = page.frame.intersection(window.scrollViews.firstMatch.frame)
        XCTAssertFalse(shownPage.isEmpty, "the page is not in the window: \(page.frame)")
        let pageShot = window.screenshot()
        attachScreenshot("dark-page", pageShot)
        let pageBrightness = try averageBrightness(pageShot, of: shownPage, in: window.frame)
        XCTAssertGreaterThan(pageBrightness, 0.8, "the page should stay white in dark mode")
        XCTAssertLessThan(pageBrightness, 0.995, "no dark text was seen on the page")
    }

    /// Mean brightness (0 black, 1 white) of a screenshot, or of the part
    /// of it at `area` (screen points) when the shot shows `shotFrame`.
    private func averageBrightness(_ shot: XCUIScreenshot, of area: CGRect? = nil,
                                   in shotFrame: CGRect? = nil) throws -> Double {
        let data = try XCTUnwrap(shot.image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        var xs = 0..<rep.pixelsWide, ys = 0..<rep.pixelsHigh
        if let area, let shotFrame {
            // Screen points to pixels; both have y growing down here.
            let scale = CGFloat(rep.pixelsWide) / shotFrame.width
            let left = Int(((area.minX - shotFrame.minX) * scale).rounded(.up))
            let right = Int(((area.maxX - shotFrame.minX) * scale).rounded(.down))
            let top = Int(((area.minY - shotFrame.minY) * scale).rounded(.up))
            let bottom = Int(((area.maxY - shotFrame.minY) * scale).rounded(.down))
            xs = max(0, left)..<min(rep.pixelsWide, right)
            ys = max(0, top)..<min(rep.pixelsHigh, bottom)
        }
        var total = 0.0
        var count = 0
        let step = 4
        for y in stride(from: ys.lowerBound, to: ys.upperBound, by: step) {
            for x in stride(from: xs.lowerBound, to: xs.upperBound, by: step) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += (color.redComponent + color.greenComponent + color.blueComponent) / 3
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 0)
        return total / Double(max(count, 1))
    }
}
