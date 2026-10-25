import XCTest

/// M7 (user decision U1): Print… and Export as PDF… show a Save panel for a
/// PDF with TextEdit's two print options, never the system Print panel.
/// The PDFs are saved into the "new-save" fixture folder under their own names.
final class PDFOutputUITests: QuickEditUITestCase {
    private func waitForPDF(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        waitUntil(10, "no PDF at \(url.path)", file: file, line: line) {
            guard let data = try? Data(contentsOf: url) else { return false }
            return data.starts(with: Array("%PDF".utf8))
        }
    }

    private func assertNoPrintPanel(file: StaticString = #filePath, line: UInt = #line) {
        // The system Print panel has a "Printer" pop-up and a "Print" button.
        let sheet = app.sheets.firstMatch
        XCTAssertFalse(sheet.popUpButtons["Printer"].exists, "the Print panel opened", file: file, line: line)
        XCTAssertFalse(sheet.buttons["Print"].exists, "the Print panel opened", file: file, line: line)
    }

    /// Hands-on script step 1: Cmd+P shows the PDF Save panel with both options.
    func testCommandPSavesAPDFWithoutThePrintPanel() throws {
        let folder = try fixtureFolder("new-save")
        launch()
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        safeType("printed to a PDF\n")
        safePress("p", .command)
        let sheet = savePanel()
        XCTAssertTrue(sheet.checkBoxes["Print header and footer"].waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.checkBoxes["Rewrap contents to fit page"].exists)
        assertNoPrintPanel()
        attachScreenshot("pdf-save-panel", app.screenshot())
        fillSavePanel(name: "printed", folder: folder)
        waitForPDF(folder.appendingPathComponent("printed.pdf"))
    }

    /// Hands-on script step 2: File > Export as PDF… gives the same panel.
    func testExportAsPDFMenuItem() throws {
        let folder = try fixtureFolder("new-save")
        launch()
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        safeType("exported\n")
        chooseMenu("File", "Export as PDF\u{2026}")
        let sheet = savePanel()
        XCTAssertTrue(sheet.checkBoxes["Print header and footer"].waitForExistence(timeout: 5))
        assertNoPrintPanel()
        fillSavePanel(name: "exported", folder: folder)
        waitForPDF(folder.appendingPathComponent("exported.pdf"))
    }

    /// Hands-on script step 3: in Wrap to Page the Rewrap option is hidden.
    func testWrapToPageHidesRewrap() throws {
        launch()
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        safePress("w", [.command, .shift])
        safePress("p", .command)
        let sheet = savePanel()
        XCTAssertTrue(sheet.checkBoxes["Print header and footer"].waitForExistence(timeout: 5))
        XCTAssertFalse(sheet.checkBoxes["Rewrap contents to fit page"].exists)
        assertNoPrintPanel()
        safePress(.escape, [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
    }
}
