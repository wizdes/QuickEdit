import XCTest

/// M1 review row 14 (windows cascade) and M2 n1 (Open Recent fills).
final class WindowsAndMenusTests: QuickEditUITestCase {
    func testNewWindowCascades() throws {
        launch()
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        let first = app.windows.firstMatch.frame
        app.typeKey("n", modifierFlags: .command)
        waitUntil(10, "Cmd+N did not add a window") { self.app.windows.count == 2 }
        let second = app.windows.firstMatch.frame // the front window is the new one
        XCTAssertGreaterThan(second.minX, first.minX, "moves right: \(first) -> \(second)")
        XCTAssertGreaterThan(second.minY, first.minY, "moves down (screen y grows down here): \(first) -> \(second)")
        XCTAssertEqual(second.size, first.size)
        attachScreenshot("cascade", XCUIScreen.main.screenshot())
    }

    func testOpenRecentListsAnOpenedFile() throws {
        let url = try fixtureFolder("recent").appendingPathComponent("recent.txt")
        launch(opening: url.path)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        app.typeKey("w", modifierFlags: .command)
        chooseMenu("File", "Open Recent")
        let item = app.menuBars.menuBarItems["File"].menuItems["Open Recent"].menuItems["recent.txt"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "recent.txt is not in Open Recent")
        attachScreenshot("open-recent", XCUIScreen.main.screenshot())
        item.click()
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "title BEGINSWITH 'recent'")).firstMatch
            .waitForExistence(timeout: 10), "Open Recent did not reopen the file")
    }
}
