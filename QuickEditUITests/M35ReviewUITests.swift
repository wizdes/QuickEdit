import XCTest

/// End-to-end check for the M3 + M5 review fixes (docs/reviews/M3-M5-code.md
/// row 9). Fixtures come from build.sh (folder "encodings").
final class M35ReviewUITests: QuickEditUITestCase {
    /// Row 9: a Save As panel is shown, UTF-16 is picked, then the panel is
    /// cancelled. The next Cmd+S writes the file's own encoding (UTF-8).
    func testCancelledSavePanelDoesNotSetTheNextSave() throws {
        let url = try fixtureFolder("encodings").appendingPathComponent("cancel.txt")
        launch(opening: url.path)
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        app.typeKey("s", modifierFlags: [.command, .shift, .option]) // Save As…
        let sheet = savePanel()
        let popUp = sheet.popUpButtons["saveEncoding"]
        XCTAssertTrue(popUp.waitForExistence(timeout: 5), "no encoding pop-up")
        popUp.click()
        let item = popUp.menuItems["Unicode (UTF-16)"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no UTF-16 item")
        item.click()
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "the Save panel did not close")
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("x")
        app.typeKey("s", modifierFlags: .command)
        waitForBytes(url, Array("abc\nx".utf8))
    }
}
