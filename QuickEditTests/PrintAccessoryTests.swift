import AppKit
import XCTest
@testable import QuickEdit

/// M7 n2: the two TextEdit print options, shown as the accessory of the PDF
/// Save panel (reference/apple/PrintPanelAccessoryController.m,
/// Base.lproj/PrintPanelAccessory.nib).
@MainActor
final class PrintAccessoryTests: XCTestCase {
    private var saved: SavedSettings!
    private var documents: [NSDocument] = []

    override func setUp() async throws {
        saved = SavedSettings()
    }

    override func tearDown() async throws {
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        saved.restore()
    }

    func testDefaultsAreHeaderOffAndRewrapOn() {
        let accessory = PrintPanelAccessoryController(showsWrappingToFit: true)
        XCTAssertFalse(accessory.pageNumbering)
        XCTAssertTrue(accessory.wrappingToFit)
        XCTAssertEqual(accessory.headerCheckbox.state, .off)
        XCTAssertEqual(accessory.rewrapCheckbox.state, .on)
        XCTAssertEqual(accessory.options, TextDocument.PDFOptions(headerAndFooter: false, wrappingToFit: true))
    }

    func testCheckboxTitlesAndLayoutFromTheNib() {
        let accessory = PrintPanelAccessoryController(showsWrappingToFit: true)
        XCTAssertEqual(accessory.headerCheckbox.title, "Print header and footer")
        XCTAssertEqual(accessory.rewrapCheckbox.title, "Rewrap contents to fit page")
        XCTAssertEqual(accessory.view.frame.size, NSSize(width: 406, height: 49))
        XCTAssertEqual(accessory.headerCheckbox.frame, NSRect(x: 105, y: 26, width: 196, height: 18))
        XCTAssertEqual(accessory.rewrapCheckbox.frame, NSRect(x: 105, y: 6, width: 196, height: 18))
        XCTAssertFalse(accessory.rewrapCheckbox.isHidden)
    }

    /// Rewrap is only for Wrap to Window: Wrap to Page pages are fixed.
    func testRewrapIsHiddenInWrapToPage() {
        let accessory = PrintPanelAccessoryController(showsWrappingToFit: false)
        XCTAssertTrue(accessory.rewrapCheckbox.isHidden)
        XCTAssertFalse(accessory.headerCheckbox.isHidden)
    }

    /// The values stick: a change writes the default, as in TextEdit.
    func testClicksWriteTheDefaults() {
        let accessory = PrintPanelAccessoryController(showsWrappingToFit: true)
        accessory.headerCheckbox.performClick(nil)
        accessory.rewrapCheckbox.performClick(nil)
        XCTAssertTrue(accessory.pageNumbering)
        XCTAssertFalse(accessory.wrappingToFit)
        XCTAssertTrue(Defaults.bool(.numberPagesWhenPrinting))
        XCTAssertFalse(Defaults.bool(.wrapToFitWhenPrinting))
        XCTAssertEqual(saved.persisted?[DefaultsKey.numberPagesWhenPrinting.rawValue] as? Bool, true)
        XCTAssertEqual(saved.persisted?[DefaultsKey.wrapToFitWhenPrinting.rawValue] as? Bool, false)
        // A new panel starts from the new defaults.
        let next = PrintPanelAccessoryController(showsWrappingToFit: true)
        XCTAssertTrue(next.pageNumbering)
        XCTAssertFalse(next.wrappingToFit)
    }

    /// Each panel keeps its own values (the apple copy's design): a change
    /// in one does not reach a panel that is already open.
    func testEachPanelKeepsItsOwnValues() {
        let first = PrintPanelAccessoryController(showsWrappingToFit: true)
        let second = PrintPanelAccessoryController(showsWrappingToFit: true)
        first.headerCheckbox.performClick(nil)
        XCTAssertTrue(first.pageNumbering)
        XCTAssertFalse(second.pageNumbering)
        XCTAssertEqual(second.headerCheckbox.state, .off)
    }

    /// Print… shows a Save panel for a PDF with both options as its accessory.
    func testSavePanelShowsBothOptionsInWrapToWindow() throws {
        let document = try makeDocument()
        var seen: (NSSavePanel, PrintPanelAccessoryController)?
        document.pdfPanelRunner = { panel, accessory, completion in
            seen = (panel, accessory)
            completion(nil)
        }
        document.printToPDF(nil)
        let (panel, accessory) = try XCTUnwrap(seen)
        XCTAssertTrue(panel.accessoryView === accessory.view)
        XCTAssertEqual(panel.allowedContentTypes, [.pdf])
        XCTAssertTrue(accessory.headerCheckbox.isDescendant(of: try XCTUnwrap(panel.accessoryView)))
        XCTAssertTrue(accessory.rewrapCheckbox.isDescendant(of: try XCTUnwrap(panel.accessoryView)))
        XCTAssertFalse(accessory.rewrapCheckbox.isHidden)
        XCTAssertFalse(accessory.headerCheckbox.isHidden)
    }

    func testSavePanelHidesRewrapInWrapToPage() throws {
        let document = try makeDocument()
        document.hasMultiplePages = true
        var accessory: PrintPanelAccessoryController?
        document.pdfPanelRunner = { _, shown, completion in
            accessory = shown
            completion(nil)
        }
        document.saveToPDF(nil)
        XCTAssertTrue(try XCTUnwrap(accessory).rewrapCheckbox.isHidden)
    }

    /// The options chosen in the panel reach the PDF.
    func testPanelChoicesReachThePrintOperation() throws {
        let document = try makeDocument()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qe-accessory-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var chosen: TextDocument.PDFOptions?
        document.pdfWriter = { _, options in chosen = options }
        document.pdfPanelRunner = { _, accessory, completion in
            accessory.headerCheckbox.performClick(nil)
            accessory.rewrapCheckbox.performClick(nil)
            completion(url)
        }
        document.printToPDF(nil)
        XCTAssertEqual(chosen, TextDocument.PDFOptions(headerAndFooter: true, wrappingToFit: false))
    }

    private func makeDocument() throws -> TextDocument {
        let document = TextDocument()
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "accessory\n")
        document.makeWindowControllers()
        documents.append(document)
        return document
    }
}
