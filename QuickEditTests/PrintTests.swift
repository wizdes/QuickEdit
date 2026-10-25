import AppKit
import PDFKit
import Synchronization
import XCTest
@testable import QuickEdit

/// M7 n1 and n3: Print… and Export as PDF… write a PDF with no Print panel
/// and no print system (user decision U1). Each test reads the PDF back with
/// PDFKit: page count, and the text of every page in order.
@MainActor
final class PrintTests: XCTestCase {
    private var folder: URL!
    private var documents: [NSDocument] = []
    private var saved: SavedSettings!

    override func setUp() async throws {
        saved = SavedSettings()
        // Letter paper, so the page counts below do not depend on the Mac's region.
        Defaults.store.set(PaperSize.letter.rawValue, forKey: Defaults.paperSizeKey)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-print-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        TextDocument.testHooks.withLock { $0.pdfTemporaryFile = nil }
        saved.restore()
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    // MARK: Helpers

    private func open(_ text: String, name: String = "print.txt") throws -> (TextDocument, DocumentWindowController) {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        document.makeWindowControllers()
        documents.append(document)
        return (document, try XCTUnwrap(document.windowControllers.first as? DocumentWindowController))
    }

    private func pdfURL(_ name: String = "out") -> URL {
        folder.appendingPathComponent("\(name)-\(UUID().uuidString).pdf")
    }

    private func write(_ document: TextDocument, header: Bool = false, rewrap: Bool = true,
                       file: StaticString = #filePath, line: UInt = #line) throws -> PDFDocument {
        let url = pdfURL()
        try document.writePDF(to: url, options: .init(headerAndFooter: header, wrappingToFit: rewrap))
        return try XCTUnwrap(PDFDocument(url: url), "no PDF at \(url.path)", file: file, line: line)
    }

    /// All text of the PDF, page after page.
    private func text(of pdf: PDFDocument) -> String {
        (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined()
    }

    /// Text without any white space: line wrapping and PDF text extraction
    /// change breaks and tabs, never the other characters or their order.
    private func squeezed(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    private func assertSameText(_ pdf: PDFDocument, _ document: TextDocument,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(squeezed(text(of: pdf)), squeezed(document.textStorage.string),
                       "the PDF's text is not the document's text", file: file, line: line)
    }

    private func lineHeight() -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: TextViewFactory.plainFont())
    }

    /// The text of every page read line by line (Letter, 72 pt margins),
    /// for short lines drawn at `scale`.
    private func textByLines(_ pdf: PDFDocument, scale: CGFloat) -> String {
        let step = lineHeight() * scale
        var result: [String] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            var top: CGFloat = 72
            while top + step <= 72 + 648 + 0.5 {
                let middle = 792 - (top + step / 2) // PDF space starts at the bottom
                if let text = page.selection(for: NSRect(x: 0, y: middle - 0.25, width: 612, height: 0.5))?.string {
                    result.append(text)
                }
                top += step
            }
        }
        return result.joined(separator: "\n")
    }

    /// Lines of a page's text area (Letter, 72 pt margins: 648 pt) at scale `scale`.
    private func linesPerPage(scale: CGFloat = 1) -> Int {
        Int((648 / scale) / lineHeight())
    }

    /// Short numbered lines that never wrap.
    private func lines(_ count: Int, ending: String = "\n", tabs: Bool = false) -> String {
        (0..<count).map { tabs ? "row\t\($0)\tcell\($0)" : "line \($0) of the print test" }
            .joined(separator: ending) + ending
    }

    private func toggle(_ document: TextDocument) {
        NSApp.sendAction(#selector(TextDocument.togglePageBreaks(_:)), to: document, from: nil)
    }

    /// The printing view's width with Rewrap on: page text width plus padding;
    /// fit-to-width scales it into the 468 pt text width.
    private var rewrapScale: CGFloat {
        468 / (468 + 2 * MultiplePageView.textPadding)
    }

    /// Line fragments of text made of short lines that never wrap: one per
    /// line, plus the empty one after a final line end, as on screen.
    private func fragments(_ text: String) -> Int {
        var count = 0
        text.enumerateLines { _, _ in count += 1 }
        let last = text.unicodeScalars.last
        return (last == nil || last == "\n" || last == "\r") ? count + 1 : count
    }

    /// Pages for short-line text at `scale`, worked out before anything prints.
    private func expectedPages(_ text: String, scale: CGFloat = 1) -> Int {
        let perPage = linesPerPage(scale: scale)
        return max(1, Int((Double(fragments(text)) / Double(perPage)).rounded(.up)))
    }

    /// The three M7 fixtures. `scale` is the print scale of Wrap to Window.
    private func fixtures(scale: CGFloat) -> [(name: String, text: String)] {
        let perPage = linesPerPage(scale: scale)
        return [("one", "just one line\n"),
                ("three", lines(perPage * 2 + perPage / 2)),
                ("crlf", lines(200, ending: "\r\n", tabs: true))]
    }

    /// The header's date: the date part of the header line (the time may
    /// change while the test runs).
    private var todayInHeader: String {
        DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
    }

    /// The text PDFKit finds inside `rect` (PDF space: points from the
    /// bottom left) of a page, or "" when there is none.
    private func text(in rect: NSRect, of page: PDFPage) -> String {
        page.selection(for: rect)?.string ?? ""
    }

    /// Checks the header and footer on every page, and that the body text
    /// of all pages, in order, is the document's text. Each part is read
    /// from its own area of the Letter page (PDFKit's reading order of a
    /// whole page mixes the header's date in with short pages' text): the
    /// top margin, the text area and the bottom margin.
    private func assertHeaderFooterAndBody(_ pdf: PDFDocument, title: String, _ document: TextDocument, name: String = "",
                                           file: StaticString = #filePath, line: UInt = #line) {
        var body = ""
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else {
                XCTFail("\(name): no page \(index + 1)", file: file, line: line)
                return
            }
            let header = text(in: NSRect(x: 0, y: 792 - 72, width: 612, height: 72), of: page)
                .components(separatedBy: .newlines).filter { !$0.isEmpty }
            XCTAssertEqual(header.count, 2, "\(name): page \(index + 1) header: \(header)", file: file, line: line)
            XCTAssertTrue(header.contains(title), "\(name): page \(index + 1) header has no name: \(header)", file: file, line: line)
            XCTAssertTrue(header.contains { $0.hasPrefix(todayInHeader) }, "\(name): page \(index + 1) header has no date: \(header)",
                          file: file, line: line)
            let footer = text(in: NSRect(x: 0, y: 0, width: 612, height: 72), of: page)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(footer, "Page \(index + 1) of \(pdf.pageCount)", "\(name): page \(index + 1) footer", file: file, line: line)
            body += text(in: NSRect(x: 0, y: 72, width: 612, height: 648), of: page)
        }
        XCTAssertEqual(squeezed(body), squeezed(document.textStorage.string), "\(name): the body text, in order", file: file, line: line)
    }

    /// Header and footer off: both margins are empty, and the text area of
    /// all pages, in order, is the document's text.
    private func assertBodyOnly(_ pdf: PDFDocument, _ document: TextDocument, name: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        var body = ""
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else {
                XCTFail("\(name): no page \(index + 1)", file: file, line: line)
                return
            }
            let margins = text(in: NSRect(x: 0, y: 792 - 72, width: 612, height: 72), of: page)
                + text(in: NSRect(x: 0, y: 0, width: 612, height: 72), of: page)
            XCTAssertEqual(squeezed(margins), "", "\(name): page \(index + 1) has text in a margin", file: file, line: line)
            body += text(in: NSRect(x: 0, y: 72, width: 612, height: 648), of: page)
        }
        XCTAssertEqual(squeezed(body), squeezed(document.textStorage.string), "\(name): the body text, in order",
                       file: file, line: line)
    }

    // MARK: n1: the three fixtures in Wrap to Window

    func testOneLineMakesOnePage() throws {
        let (document, _) = try open("just one line\n")
        let pdf = try write(document)
        XCTAssertEqual(pdf.pageCount, 1)
        assertSameText(pdf, document)
        XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).size, NSSize(width: 612, height: 792), "Letter paper")
    }

    func testThreePageTextInWrapToWindow() throws {
        let perPage = linesPerPage(scale: rewrapScale)
        let (document, _) = try open(lines(perPage * 2 + perPage / 2))
        let pdf = try write(document)
        XCTAssertEqual(pdf.pageCount, 3, "\(perPage) lines a page")
        assertSameText(pdf, document)
    }

    func testTwoHundredLinesWithTabsAndCRLF() throws {
        let (document, _) = try open(lines(200, ending: "\r\n", tabs: true))
        XCTAssertEqual(document.format.lineEnding, .crlf)
        let pdf = try write(document)
        let perPage = linesPerPage(scale: rewrapScale)
        // 201 line fragments: the empty line after the last line end
        // counts too, as on screen.
        XCTAssertEqual(pdf.pageCount, Int((Double(201) / Double(perPage)).rounded(.up)), "\(perPage) lines a page")
        assertSameText(pdf, document)
        // A tab in the PDF keeps its columns apart: "row" and the number are not joined.
        XCTAssertFalse(text(of: pdf).contains("row0"), "a tab was lost")
    }

    // MARK: n1: the same fixtures in Wrap to Page

    func testWrapToPagePrintsTheShownPages() throws {
        for (name, text) in [("one", "just one line\n"),
                             ("three", lines(linesPerPage() * 2 + linesPerPage() / 2)),
                             ("crlf", lines(200, ending: "\r\n", tabs: true))] {
            let expected = expectedPages(text) // fixed before anything prints
            let (document, controller) = try open(text, name: "\(name).txt")
            toggle(document)
            XCTAssertTrue(controller.hasMultiplePages)
            let pdf = try write(document)
            XCTAssertEqual(pdf.pageCount, expected, "\(name): \(linesPerPage()) lines a page")
            XCTAssertEqual(controller.numberOfPages, expected, "\(name): pages as shown on screen")
            assertSameText(pdf, document)
            XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).size, NSSize(width: 612, height: 792))
        }
    }

    func testWrapToPageThreePageFixtureMakesThreePages() throws {
        let perPage = linesPerPage()
        let (document, controller) = try open(lines(perPage * 2 + perPage / 2))
        toggle(document)
        let pdf = try write(document)
        XCTAssertEqual(pdf.pageCount, 3)
        XCTAssertEqual(controller.numberOfPages, 3, "printing laid out every page")
    }

    /// Rewrap has no effect in Wrap to Page: the pages are fixed already.
    func testWrapToPageIgnoresRewrap() throws {
        let (document, _) = try open(lines(150))
        toggle(document)
        let on = try write(document, rewrap: true)
        let off = try write(document, rewrap: false)
        XCTAssertEqual(on.pageCount, off.pageCount)
    }

    // MARK: n1: margins, paper and job title

    /// TextEdit's 72 pt margins on every side (Document.m:679-689): the
    /// first line starts one inch from the top and the left of the page.
    func testTextStartsAtTheOneInchMargins() throws {
        for pages in [false, true] {
            let (document, _) = try open("Wmargin\n", name: "margin-\(pages).txt")
            if pages { toggle(document) }
            let pdf = try write(document)
            let page = try XCTUnwrap(pdf.page(at: 0))
            let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 1)))
            let bounds = selection.bounds(for: page)
            // PDF space starts at the bottom left. In Wrap to Page the text
            // view starts one padding left of the margin, so the text is at
            // the margin; in Wrap to Window the printing view starts at the
            // margin and the text one (scaled) padding inside it, as in TextEdit.
            let left = pages ? 72 : 72 + MultiplePageView.textPadding * rewrapScale
            XCTAssertEqual(bounds.minX, left, accuracy: 1.5, "left margin (pages: \(pages))")
            XCTAssertEqual(792 - bounds.maxY, 72, accuracy: 4, "top margin (pages: \(pages))")
        }
    }

    func testDocumentPrintInfoHasTextEditsMarginsAndFitPagination() throws {
        let (document, _) = try open("x\n")
        let info = document.printInfo
        XCTAssertEqual([info.topMargin, info.leftMargin, info.bottomMargin, info.rightMargin], [72, 72, 72, 72])
        XCTAssertEqual(info.horizontalPagination, .fit)
        XCTAssertFalse(info.isHorizontallyCentered)
        XCTAssertFalse(info.isVerticallyCentered)
    }

    func testA4SettingMakesA4Pages() throws {
        Defaults.store.set(PaperSize.a4.rawValue, forKey: Defaults.paperSizeKey)
        for pages in [false, true] {
            let (document, _) = try open("a4\n", name: "a4-\(pages).txt")
            if pages { toggle(document) }
            let pdf = try write(document)
            XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).size, NSSize(width: 595, height: 842))
        }
    }

    /// TextEdit's job title is the window's printJobTitle: the document's
    /// name without its extension (Document.m:662). It heads each page.
    func testHeaderTitleIsTheNameWithoutExtension() throws {
        let (document, controller) = try open("x\n", name: "Job Title.txt")
        XCTAssertEqual(controller.scrollView.documentView?.printJobTitle, "Job Title")
        let pdf = try write(document, header: true)
        assertHeaderFooterAndBody(pdf, title: "Job Title", document)
    }

    /// U1: writing a PDF never reaches the print system. NSPrintOperation
    /// and reading a print info's paper open com.apple.printtool.agent
    /// (probe 2026-10-24), so nothing on this path may touch NSPrintInfo.
    func testWritingAPDFNeverTouchesNSPrintInfo() throws {
        for pages in [false, true] {
            let (document, _) = try open(lines(80), name: "touch-\(pages).txt")
            if pages { toggle(document) }
            let counter = PrintInfoReadCounter()
            counter.start()
            defer { counter.stop() }
            _ = try write(document, header: true)
            counter.stop()
            XCTAssertEqual(counter.counts, PrintInfoReadCounter.Counts(), "pages: \(pages)")
        }
    }

    // MARK: n2: header and footer, rewrap

    func testHeaderAndFooterPutNameAndPageNumberInThePDF() throws {
        let perPage = linesPerPage(scale: rewrapScale)
        let (document, _) = try open(lines(perPage + perPage / 2), name: "Header Test.txt")
        let title = "Header Test" // the job title: the name without its extension
        let plain = try write(document, header: false)
        let withHeader = try write(document, header: true)
        XCTAssertEqual(withHeader.pageCount, 2)
        XCTAssertFalse(text(of: plain).contains(title), "header printed while off")
        XCTAssertFalse(text(of: plain).contains("Page 1 of"), "footer printed while off")
        let footerArea = NSRect(x: 0, y: 0, width: 612, height: 72)
        XCTAssertEqual(text(in: footerArea, of: try XCTUnwrap(withHeader.page(at: 0))), "Page 1 of 2")
        XCTAssertEqual(text(in: footerArea, of: try XCTUnwrap(withHeader.page(at: 1))), "Page 2 of 2")
        assertHeaderFooterAndBody(withHeader, title: title, document)
    }

    func testHeaderAndFooterInWrapToPage() throws {
        let (document, _) = try open(lines(linesPerPage() + 3), name: "Paged.txt")
        toggle(document)
        let pdf = try write(document, header: true)
        XCTAssertEqual(pdf.pageCount, 2)
        assertHeaderFooterAndBody(pdf, title: "Paged", document)
    }

    /// The M7 done-test as a table: every fixture in both view modes,
    /// with the header and footer on and off, and Rewrap on and off. Each
    /// case checks the page count (worked out before printing) and the
    /// text in order; with the header on, also the header and footer on
    /// every page; with it off, that both margins are empty.
    func testDoneTestMatrix() throws {
        let fixtures: [(name: String, text: String)] = self.fixtures(scale: 1) + [
            ("cr-only", lines(60, ending: "\r")),
            ("empty-last-line", "first line\nsecond line\n\n"),
        ]
        var caseNumber = 0
        for fixture in fixtures {
            for pages in [false, true] {
                for header in [false, true] {
                    for rewrap in [false, true] {
                        let name = "\(fixture.name) \(pages ? "page" : "window") header-\(header ? "on" : "off") rewrap-\(rewrap ? "on" : "off")"
                        // Letters and digits only: PDFKit splits a header name
                        // at "_" and "-" into separate pieces.
                        caseNumber += 1
                        let fileName = String(format: "Case%02d", caseNumber)
                        let (document, controller) = try open(fixture.text, name: fileName + ".txt")
                        if pages { toggle(document) }
                        XCTAssertEqual(controller.hasMultiplePages, pages, "\(name) (\(fileName))")
                        // Fixed before printing: Wrap to Page prints its pages
                        // at full size; Wrap to Window prints at the page's
                        // text width plus padding (Rewrap on) or the window's
                        // text width (off), scaled down when wider than 468 pt.
                        let scale: CGFloat = pages ? 1 : (rewrap ? rewrapScale : min(1, 468 / controller.textView.frame.width))
                        let expected = expectedPages(fixture.text, scale: scale)
                        let pdf = try write(document, header: header, rewrap: rewrap)
                        XCTAssertEqual(pdf.pageCount, expected, "\(name): page count at scale \(scale)")
                        if header {
                            assertHeaderFooterAndBody(pdf, title: fileName, document, name: name)
                        } else {
                            assertBodyOnly(pdf, document, name: name)
                        }
                    }
                }
            }
        }
    }

    /// A wide window with Rewrap off prints the on-screen width scaled down,
    /// so more text fits a page and the page count drops.
    func testRewrapOffInAWideWindowChangesThePageCount() throws {
        let long = (0..<120).map { "paragraph \($0) " + String(repeating: "word ", count: 40) }.joined(separator: "\n")
        let (document, controller) = try open(long + "\n")
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1400, height: 600))
        XCTAssertGreaterThan(controller.textView.frame.width, 1000)
        let on = try write(document, rewrap: true)
        let off = try write(document, rewrap: false)
        XCTAssertNotEqual(on.pageCount, off.pageCount)
        XCTAssertLessThan(off.pageCount, on.pageCount, "on-screen width, scaled down, fits more on a page")
        assertSameText(on, document)
        // Scaled to about a third, lines are about 5 pt apart and PDFKit's
        // page text mixes them up (the characters all match). So the text
        // is read one line at a time, top to bottom: a thin strip through
        // the middle of each line.
        let scale = 468 / controller.textView.frame.width
        XCTAssertEqual(squeezed(textByLines(off, scale: scale)), squeezed(document.textStorage.string))
    }

    // MARK: n1 step 2: the menu items both write the same PDF

    func testPrintAndExportGiveTheSamePages() throws {
        let perPage = linesPerPage(scale: rewrapScale)
        let (document, _) = try open(lines(perPage * 2 + 3))
        var panels: [NSSavePanel] = []
        var urls: [URL] = []
        document.pdfPanelRunner = { panel, _, completion in
            panels.append(panel)
            let url = self.pdfURL()
            urls.append(url)
            completion(url)
        }
        XCTAssertTrue(NSApp.sendAction(#selector(TextDocument.printToPDF(_:)), to: document, from: nil))
        XCTAssertTrue(NSApp.sendAction(#selector(NSDocument.saveToPDF(_:)), to: document, from: nil))
        XCTAssertEqual(panels.count, 2)
        XCTAssertEqual(urls.count, 2)
        let printed = try XCTUnwrap(PDFDocument(url: urls[0]))
        let exported = try XCTUnwrap(PDFDocument(url: urls[1]))
        XCTAssertEqual(printed.pageCount, 3)
        XCTAssertEqual(printed.pageCount, exported.pageCount)
        XCTAssertEqual(text(of: printed), text(of: exported))
        for panel in panels {
            XCTAssertEqual(panel.allowedContentTypes, [.pdf])
            XCTAssertEqual(panel.nameFieldStringValue, "print.pdf")
        }
    }

    func testCancelledPanelWritesNothing() throws {
        let (document, _) = try open("x\n")
        var asked = false
        document.pdfPanelRunner = { _, _, completion in
            asked = true
            completion(nil)
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        document.printToPDF(nil)
        XCTAssertTrue(asked)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), before)
    }

    func testMenuItemsAreEnabledForADocument() throws {
        let (document, _) = try open("x\n")
        let file = try XCTUnwrap(MainMenu.build().item(withTitle: "File")?.submenu)
        for title in ["Export as PDF\u{2026}", "Print\u{2026}"] {
            let item = try XCTUnwrap(file.item(withTitle: title), title)
            XCTAssertTrue(document.validateMenuItem(item), title)
        }
    }

    // MARK: Evidence for root

    /// Writes two PDFs (Wrap to Window, and Wrap to Page with the header and
    /// footer on) to $QE_M7_EVIDENCE, when it is set, so root can look at them.
    func testWriteEvidencePDFs() throws {
        let text = (0..<140).map { "Line \($0)\tof the M7 evidence. " + String(repeating: "Some words that wrap. ", count: $0 % 7) }
            .joined(separator: "\n") + "\n"
        let (window, _) = try open(text, name: "Wrap to Window.txt")
        let (page, _) = try open(text, name: "Wrap to Page.txt")
        toggle(page)
        let windowURL = pdfURL("window"), pageURL = pdfURL("page")
        try window.writePDF(to: windowURL, options: .init(headerAndFooter: false, wrappingToFit: true))
        try page.writePDF(to: pageURL, options: .init(headerAndFooter: true, wrappingToFit: true))
        let pagePDF = try XCTUnwrap(PDFDocument(url: pageURL))
        XCTAssertGreaterThan(pagePDF.pageCount, 1)
        print("M7-EVIDENCE page 1 text with header: \((pagePDF.page(at: 0)?.string ?? "").debugDescription)")
        guard let folder = ProcessInfo.processInfo.environment["QE_M7_EVIDENCE"] else { return }
        let out = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (source, name) in [(windowURL, "wrap-to-window.pdf"), (pageURL, "wrap-to-page-header.pdf")] {
            let target = out.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    func testWritingOverAnExistingPDFReplacesIt() throws {
        let url = pdfURL()
        let (short, _) = try open("one page\n", name: "short.txt")
        try short.writePDF(to: url, options: .init(headerAndFooter: false, wrappingToFit: true))
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 1)
        let perPage = linesPerPage(scale: rewrapScale)
        let (long, _) = try open(lines(perPage * 2 + perPage / 2), name: "long.txt")
        try long.writePDF(to: url, options: .init(headerAndFooter: false, wrappingToFit: true))
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 3)
    }

    // MARK: n3: speed and safety

    func testOneMegabytePrintKeepsLayoutManagersAndTyping() throws {
        let line = "a line of about forty characters here.\n"
        let text = String(repeating: line, count: 1_048_576 / line.utf8.count)
        let (document, controller) = try open(text, name: "big.txt")
        let managersBefore = document.textStorage.layoutManagers.map(ObjectIdentifier.init)
        XCTAssertEqual(managersBefore.count, 1)
        let start = Date()
        let pdf = try write(document)
        let seconds = Date().timeIntervalSince(start)
        // The write runs on the main thread in one piece, so this is also
        // the longest main-thread block.
        print(String(format: "M7-TIMING 1 MB Wrap to Window to PDF: %.0f ms (one main-thread block), %d pages",
                     seconds * 1000, pdf.pageCount))
        XCTAssertEqual(pdf.pageCount, expectedPages(text, scale: rewrapScale))
        XCTAssertGreaterThan(pdf.pageCount, 100)
        XCTAssertEqual(document.textStorage.layoutManagers.map(ObjectIdentifier.init), managersBefore,
                       "printing left a layout manager on the document")

        // Typing still works.
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let undoManager = try XCTUnwrap(document.undoManager)
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        textView.insertText("typed ", replacementRange: textView.selectedRange())
        undoManager.endUndoGrouping()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(document.textStorage.string.hasPrefix("typed a line"))
        XCTAssertTrue(document.isDocumentEdited)
    }

    func testFailedWriteThrowsAndCleansUp() throws {
        let (document, _) = try open("x\n")
        let before = document.textStorage.layoutManagers.count
        let seen = Mutex<URL?>(nil)
        TextDocument.testHooks.withLock { hooks in hooks.pdfTemporaryFile = { url in seen.withLock { $0 = url } } }
        let missing = folder.appendingPathComponent("no-such-folder/out.pdf")
        XCTAssertThrowsError(try document.writePDF(to: missing, options: .init(headerAndFooter: false, wrappingToFit: true)))
        XCTAssertEqual(document.textStorage.layoutManagers.count, before)
        if let temporary = seen.withLock({ $0 }) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path),
                           "a QuickEdit-PDF folder was left behind")
        }
    }

    // MARK: Review fixes (M7 review)

    /// Item 1: the temporary PDF is written on the target's volume, so
    /// replacing a PDF on another disk works, and its folder goes away.
    func testTemporaryFolderIsOnTheTargetVolumeAndRemoved() throws {
        let (document, _) = try open("x\n")
        let seen = Mutex<URL?>(nil)
        TextDocument.testHooks.withLock { hooks in hooks.pdfTemporaryFile = { url in seen.withLock { $0 = url } } }
        let url = pdfURL()
        for _ in 0..<2 { // the second write replaces the first file
            try document.writePDF(to: url, options: .init(headerAndFooter: false, wrappingToFit: true))
            let temporary = try XCTUnwrap(seen.withLock { $0 })
            let temporaryFolder = temporary.deletingLastPathComponent()
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFolder.path), "the temporary folder was left behind")
            let targetVolume = try folder.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
            // The folder is gone, so its volume is read from its parent.
            let temporaryVolume = try temporaryFolder.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
            XCTAssertNotNil(targetVolume)
            XCTAssertEqual(temporaryVolume, targetVolume, "temporary PDF at \(temporary.path) is on another volume")
            XCTAssertNotEqual(temporaryFolder.deletingLastPathComponent().standardizedFileURL,
                              FileManager.default.temporaryDirectory.standardizedFileURL,
                              "the user's temporary folder may be on another volume")
            XCTAssertEqual(PDFDocument(url: url)?.pageCount, 1)
        }
    }

    /// The branch for "no PDF came out": the temporary file is gone when
    /// it is checked. The write throws, the target is not made, and the
    /// temporary folder is removed.
    func testMissingTemporaryPDFThrowsAndCleansUp() throws {
        let (document, _) = try open("x\n")
        let seen = Mutex<URL?>(nil)
        TextDocument.testHooks.withLock { hooks in
            hooks.pdfTemporaryFile = { url in
                seen.withLock { $0 = url }
                try? FileManager.default.removeItem(at: url)
            }
        }
        let url = pdfURL()
        XCTAssertThrowsError(try document.writePDF(to: url, options: .init(headerAndFooter: false, wrappingToFit: true))) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteUnknown)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let temporary = try XCTUnwrap(seen.withLock { $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path))
    }

    /// Item 6: an empty document makes one blank page.
    func testEmptyDocumentMakesOneBlankPage() throws {
        for pages in [false, true] {
            let (document, _) = try open("", name: "empty-\(pages).txt")
            if pages { toggle(document) }
            let pdf = try write(document)
            XCTAssertEqual(pdf.pageCount, 1, "pages: \(pages)")
            XCTAssertEqual(squeezed(text(of: pdf)), "")
            let withHeader = try write(document, header: true)
            XCTAssertEqual(text(in: NSRect(x: 0, y: 0, width: 612, height: 72), of: try XCTUnwrap(withHeader.page(at: 0))),
                           "Page 1 of 1")
        }
    }

    private func type(_ text: String, in controller: DocumentWindowController, document: TextDocument) throws {
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let undoManager = try XCTUnwrap(document.undoManager)
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        textView.insertText(text, replacementRange: textView.selectedRange())
        undoManager.endUndoGrouping()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    /// Item 6: typing still works after a PDF in Wrap to Page.
    func testTypingWorksAfterAPDFInWrapToPage() throws {
        let (document, controller) = try open(lines(linesPerPage() * 2))
        toggle(document)
        let managers = document.textStorage.layoutManagers.map(ObjectIdentifier.init)
        _ = try write(document, header: true)
        XCTAssertEqual(document.textStorage.layoutManagers.map(ObjectIdentifier.init), managers)
        let textView = try XCTUnwrap(controller.textView as NSTextView?)
        XCTAssertTrue(textView.isEditable)
        try type("typed ", in: controller, document: document)
        XCTAssertTrue(document.textStorage.string.hasPrefix("typed line 0"))
        XCTAssertTrue(document.isDocumentEdited)
        // And the next PDF has the new text.
        let after = try write(document)
        XCTAssertTrue(text(of: after).hasPrefix("typed line 0"))
    }

    /// Item 6: 1 MB in Wrap to Page. Prints the time; the write runs on the
    /// main thread in one piece, so it is also the longest main-thread block.
    func testOneMegabyteInWrapToPage() throws {
        let line = "a line of about forty characters here.\n"
        let text = String(repeating: line, count: 1_048_576 / line.utf8.count)
        let expected = expectedPages(text)
        let (document, controller) = try open(text, name: "big-pages.txt")
        let toggleStart = Date()
        toggle(document)
        let toggleMS = Date().timeIntervalSince(toggleStart) * 1000
        let start = Date()
        let pdf = try write(document)
        let writeMS = Date().timeIntervalSince(start) * 1000
        print(String(format: "M7-TIMING 1 MB Wrap to Page: switch %.0f ms; PDF %.0f ms (one main-thread block), %d pages",
                     toggleMS, writeMS, pdf.pageCount))
        XCTAssertEqual(pdf.pageCount, expected)
        XCTAssertEqual(controller.numberOfPages, expected)
        XCTAssertLessThan(writeMS, 30_000, "a 1 MB PDF took too long")
        try type("typed ", in: controller, document: document)
        XCTAssertTrue(document.textStorage.string.hasPrefix("typed a line"))
    }

    /// Item 6: Cmd+P while the PDF Save panel is open does not open a
    /// second panel; after the first one closes, the next one opens.
    func testPrintWhileThePanelIsOpenOpensNoSecondPanel() throws {
        let (document, _) = try open("x\n")
        var completions: [(URL?) -> Void] = []
        document.pdfPanelRunner = { _, _, completion in completions.append(completion) }
        let file = try XCTUnwrap(MainMenu.build().item(withTitle: "File")?.submenu)
        let printItem = try XCTUnwrap(file.item(withTitle: "Print\u{2026}"))
        XCTAssertTrue(NSApp.sendAction(#selector(TextDocument.printToPDF(_:)), to: document, from: nil))
        XCTAssertEqual(completions.count, 1)
        XCTAssertFalse(document.validateMenuItem(printItem), "Print… stays on while the panel is open")
        _ = NSApp.sendAction(#selector(TextDocument.printToPDF(_:)), to: document, from: nil)
        _ = NSApp.sendAction(#selector(NSDocument.saveToPDF(_:)), to: document, from: nil)
        XCTAssertEqual(completions.count, 1, "a second PDF panel opened")
        completions[0](nil)
        XCTAssertTrue(document.validateMenuItem(printItem))
        document.printToPDF(nil)
        XCTAssertEqual(completions.count, 2)
        completions[1](nil)
    }

    /// Item 8: a print request from outside (Finder's File > Print, a
    /// script) opens QuickEdit's PDF Save panel and never reaches
    /// NSDocument's print path. The caller hears back once the panel closes.
    func testPrintRequestFromOutsideOpensThePDFPanel() throws {
        let (document, _) = try open(lines(10), name: "outside.txt")
        let target = pdfURL()
        var panels = 0
        document.pdfPanelRunner = { _, _, completion in
            panels += 1
            completion(target)
        }
        let delegate = DidPrintRecorder()
        let counter = PrintInfoReadCounter()
        counter.start()
        defer { counter.stop() }
        document.print(withSettings: [:], showPrintPanel: true, delegate: delegate,
                       didPrint: #selector(DidPrintRecorder.document(_:didPrint:contextInfo:)), contextInfo: nil)
        counter.stop()
        XCTAssertEqual(panels, 1)
        XCTAssertEqual(document.printOperationRequests, 0, "NSDocument's print path ran")
        XCTAssertEqual(delegate.results, [true])
        XCTAssertEqual(PDFDocument(url: target)?.pageCount, 1)
        XCTAssertEqual(counter.counts, PrintInfoReadCounter.Counts())

        // A cancelled panel reports false; asking AppKit for a print
        // operation directly fails with an error instead of printing.
        document.pdfPanelRunner = { _, _, completion in completion(nil) }
        document.print(withSettings: [:], showPrintPanel: false, delegate: delegate,
                       didPrint: #selector(DidPrintRecorder.document(_:didPrint:contextInfo:)), contextInfo: nil)
        XCTAssertEqual(delegate.results, [true, false])
        XCTAssertThrowsError(try document.printOperation(withSettings: [:]))
        XCTAssertEqual(document.printOperationRequests, 1)
    }

    // MARK: Re-review fixes (M7, Astra)

    /// Item 1: a partial PDF never replaces a good one. The hook cuts the
    /// new temporary PDF to half its size; the write throws, the old file
    /// keeps its exact bytes, and the temporary folder is gone.
    func testTruncatedPDFDoesNotReplaceTheOldOne() throws {
        let url = pdfURL()
        let (old, _) = try open("the good old PDF\n", name: "old.txt")
        try old.writePDF(to: url, options: .init(headerAndFooter: false, wrappingToFit: true))
        let goodBytes = try Data(contentsOf: url)
        let perPage = linesPerPage(scale: rewrapScale)
        let (document, _) = try open(lines(perPage * 2 + perPage / 2), name: "new.txt")
        let seen = Mutex<URL?>(nil)
        TextDocument.testHooks.withLock { hooks in
            hooks.pdfTemporaryFile = { temporary in
                seen.withLock { $0 = temporary }
                guard let data = try? Data(contentsOf: temporary) else { return }
                try? data.prefix(data.count / 2).write(to: temporary)
            }
        }
        XCTAssertThrowsError(try document.writePDF(to: url, options: .init(headerAndFooter: false, wrappingToFit: true))) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteUnknown)
        }
        XCTAssertEqual(try Data(contentsOf: url), goodBytes, "the old PDF changed")
        let temporary = try XCTUnwrap(seen.withLock { $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path))
    }

    /// Item 1: a whole PDF with fewer pages than were drawn is refused too.
    func testPDFWithTheWrongPageCountDoesNotReplaceTheOldOne() throws {
        let url = pdfURL()
        let (old, _) = try open("the good old PDF\n", name: "old.txt")
        try old.writePDF(to: url, options: .init(headerAndFooter: false, wrappingToFit: true))
        let goodBytes = try Data(contentsOf: url)
        let onePage = try Data(contentsOf: url)
        let perPage = linesPerPage(scale: rewrapScale)
        let (document, _) = try open(lines(perPage * 2 + perPage / 2), name: "new.txt")
        TextDocument.testHooks.withLock { hooks in
            hooks.pdfTemporaryFile = { temporary in try? onePage.write(to: temporary) }
        }
        XCTAssertThrowsError(try document.writePDF(to: url, options: .init(headerAndFooter: false, wrappingToFit: true)))
        XCTAssertEqual(try Data(contentsOf: url), goodBytes, "the old PDF changed")
    }

    /// The check itself: a whole PDF passes, a cut one or a wrong count fails.
    func testCheckPDF() throws {
        let (document, _) = try open(lines(10))
        let pdf = try write(document)
        let url = try XCTUnwrap(pdf.documentURL)
        XCTAssertTrue(TextDocument.checkPDF(at: url, pages: 1))
        XCTAssertFalse(TextDocument.checkPDF(at: url, pages: 2))
        let data = try Data(contentsOf: url)
        let cut = folder.appendingPathComponent("cut.pdf")
        try data.prefix(data.count - 10).write(to: cut)
        XCTAssertFalse(TextDocument.checkPDF(at: cut, pages: 1))
        XCTAssertFalse(TextDocument.checkPDF(at: folder.appendingPathComponent("missing.pdf"), pages: 1))
    }

    /// Dark pixels of `page` drawn at 1 pixel a point outside `area`
    /// (points from the paper's top-left; 1 pt of slack for smoothing),
    /// and inside it.
    private func darkPixels(_ page: PDFPage, area: NSRect) throws -> (outside: Int, inside: Int) {
        let width = 612, height = 792
        let cgPage = try XCTUnwrap(page.pageRef)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.drawPDFPage(cgPage)
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let slack = area.insetBy(dx: -1, dy: -1)
        var outside = 0, inside = 0
        for row in 0..<height { // row 0 is the top of the page
            for column in 0..<width {
                let offset = row * width * 4 + column * 4
                guard pixels[offset] < 200 || pixels[offset + 1] < 200 || pixels[offset + 2] < 200 else { continue }
                if slack.contains(NSPoint(x: CGFloat(column) + 0.5, y: CGFloat(row) + 0.5)) { inside += 1 } else { outside += 1 }
            }
        }
        return (outside, inside)
    }

    /// Item 2: a line taller than the page's text area (a 900 pt font) goes
    /// alone on its own page and is cut off at the text area: nothing is
    /// drawn in the margins or off the paper, and the page count is finite
    /// and the same on every write. Wrap to Window only: Wrap to Page's
    /// window has its own handling of such a line (follow-up).
    func testLineTallerThanThePageIsClippedToTheTextArea() throws {
        let (document, _) = try open("W\nW", name: "huge.txt")
        let font = try XCTUnwrap(NSFont.userFixedPitchFont(ofSize: 900))
        document.textStorage.addAttribute(.font, value: font, range: NSRange(location: 0, length: document.textStorage.length))
        let textArea = NSRect(x: 72, y: 72, width: 468, height: 648)
        for rewrap in [true, false] {
            let first = try write(document, rewrap: rewrap)
            let second = try write(document, rewrap: rewrap)
            XCTAssertEqual(first.pageCount, 2, "rewrap \(rewrap): one tall line a page")
            XCTAssertEqual(second.pageCount, first.pageCount, "rewrap \(rewrap): page count changed")
            for index in 0..<first.pageCount {
                let counts = try darkPixels(try XCTUnwrap(first.page(at: index)), area: textArea)
                XCTAssertEqual(counts.outside, 0, "rewrap \(rewrap) page \(index + 1): drawn outside the text area")
                XCTAssertGreaterThan(counts.inside, 0, "rewrap \(rewrap) page \(index + 1): nothing drawn")
            }
        }
        // With the header and footer on, every page still has its footer.
        // (Read from the page's text: PDFKit gives a cut-off glyph its full,
        // unclipped box, so the footer area's text can include it.)
        let withFooter = try write(document, header: true)
        XCTAssertEqual(withFooter.pageCount, 2)
        for index in 0..<withFooter.pageCount {
            let page = withFooter.page(at: index)?.string ?? ""
            XCTAssertTrue(page.contains("Page \(index + 1) of \(withFooter.pageCount)"), "page \(index + 1): \(page.debugDescription)")
        }
    }

    /// Follow-up to item 2: Wrap to Page with a line taller than the page.
    /// The window must not add pages without end: the switch and the PDF
    /// each finish within 5 s, the page count settles, and the PDF has one
    /// page a line, cut off at the page's text area. The switch runs on
    /// the main thread, so it is timed; then the run loop turns in steps
    /// (at most 5 s) while the page count is watched, so a page-adding
    /// loop driven by the run loop fails here instead of hanging the run.
    func testWrapToPageWithALineTallerThanThePage() throws {
        let (document, controller) = try open("W\nW", name: "huge-page.txt")
        let font = try XCTUnwrap(NSFont.userFixedPitchFont(ofSize: 900))
        document.textStorage.addAttribute(.font, value: font, range: NSRange(location: 0, length: document.textStorage.length))

        let switchStart = Date()
        toggle(document)
        XCTAssertTrue(controller.hasMultiplePages)
        var counts = [controller.numberOfPages]
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            counts.append(controller.numberOfPages)
            if counts.suffix(5).count == 5 && Set(counts.suffix(5)).count == 1 { break }
        }
        let switchSeconds = Date().timeIntervalSince(switchStart)
        print(String(format: "M7-TALL Wrap to Page switch: %.0f ms, pages on screen %@", switchSeconds * 1000, "\(counts.last ?? -1)"))
        XCTAssertLessThan(switchSeconds, 5, "the switch did not settle: pages \(counts.suffix(10))")
        XCTAssertEqual(Set(counts.suffix(5)).count, 1, "the page count keeps changing: \(counts.suffix(10))")
        XCTAssertLessThanOrEqual(controller.numberOfPages, 4, "pages on screen: \(controller.numberOfPages)")

        let writeStart = Date()
        let pdf = try write(document)
        let writeSeconds = Date().timeIntervalSince(writeStart)
        print(String(format: "M7-TALL Wrap to Page PDF: %.0f ms, %d pages", writeSeconds * 1000, pdf.pageCount))
        XCTAssertLessThan(writeSeconds, 5)
        XCTAssertEqual(pdf.pageCount, 2, "one tall line a page")
        // The page's text view starts one padding left of the margin.
        let textArea = NSRect(x: 72 - MultiplePageView.textPadding, y: 72, width: 468 + 2 * MultiplePageView.textPadding, height: 648)
        for index in 0..<pdf.pageCount {
            let pixels = try darkPixels(try XCTUnwrap(pdf.page(at: index)), area: textArea)
            XCTAssertEqual(pixels.outside, 0, "page \(index + 1): drawn outside the text area")
            XCTAssertGreaterThan(pixels.inside, 0, "page \(index + 1): nothing drawn")
        }
        XCTAssertEqual(try write(document).pageCount, pdf.pageCount, "page count changed")
    }
}

/// Records NSDocument's didPrint callbacks.
final class DidPrintRecorder: NSObject {
    var results: [Bool] = []
    @objc func document(_ document: NSDocument, didPrint: Bool, contextInfo: UnsafeMutableRawPointer?) {
        results.append(didPrint)
    }
}
