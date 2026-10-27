import AppKit
import ObjectiveC
import PDFKit
import XCTest
@testable import QuickEdit

/// M7 n1 step 3: the paper size for PDFs and Wrap to Page. No Page Setup
/// (user decision U1): the size comes from Settings > New Document, whose
/// default follows the Mac's region. Nothing on the Wrap to Page path may
/// ask NSPrintInfo for its paper, because that call reaches macOS's print
/// helper (com.apple.printtool.agent).
@MainActor
final class PaperSizeTests: XCTestCase {
    private var saved: SavedSettings!
    private var documents: [NSDocument] = []
    private var controllers: [SettingsWindowController] = []

    override func setUp() async throws {
        saved = SavedSettings()
    }

    override func tearDown() async throws {
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        for controller in controllers { controller.window?.close() }
        controllers = []
        saved.restore()
    }

    // MARK: Sizes and the region default

    func testPaperSizesInPoints() {
        XCTAssertEqual(PaperSize.letter.size, NSSize(width: 612, height: 792))
        XCTAssertEqual(PaperSize.a4.size, NSSize(width: 595, height: 842))
        XCTAssertEqual(PaperSize.legal.size, NSSize(width: 612, height: 1008))
        XCTAssertEqual(PaperSize.allCases.map(\.title), ["Letter", "A4", "Legal"])
    }

    func testRegionDefaultIsLetterInTheUSAndCanadaElseA4() {
        XCTAssertEqual(PaperSize.regionDefault(for: Locale(identifier: "en_US")), .letter)
        XCTAssertEqual(PaperSize.regionDefault(for: Locale(identifier: "en_CA")), .letter)
        XCTAssertEqual(PaperSize.regionDefault(for: Locale(identifier: "fr_CA")), .letter)
        XCTAssertEqual(PaperSize.regionDefault(for: Locale(identifier: "en_GB")), .a4)
        XCTAssertEqual(PaperSize.regionDefault(for: Locale(identifier: "de_DE")), .a4)
        XCTAssertEqual(PaperSize.regionDefault(for: Locale(identifier: "ja_JP")), .a4)
        // A locale with no region: A4, the world's common size.
        XCTAssertEqual(PaperSize.regionDefault(for: Locale(identifier: "en")), .a4)
    }

    func testRegisteredDefaultFollowsTheRegion() {
        let registered = Defaults.registeredValues()[Defaults.paperSizeKey] as? String
        XCTAssertEqual(registered, PaperSize.regionDefault(for: .current).rawValue)
        XCTAssertEqual(PaperSize.current, PaperSize.regionDefault(for: .current), "nothing saved: the region's size")
    }

    func testUnknownSavedValueFallsBackToTheRegion() {
        Defaults.store.set("Tabloid", forKey: Defaults.paperSizeKey)
        XCTAssertEqual(PaperSize.current, PaperSize.regionDefault(for: .current))
    }

    // MARK: New documents use the setting

    func testNewDocumentUsesTheSettingAndTextEditMargins() throws {
        for paper in PaperSize.allCases {
            Defaults.store.set(paper.rawValue, forKey: Defaults.paperSizeKey)
            let document = TextDocument()
            documents.append(document)
            XCTAssertEqual(document.pageLayout.paperSize, paper.size)
            let layout = document.pageLayout
            XCTAssertEqual([layout.topMargin, layout.leftMargin, layout.bottomMargin, layout.rightMargin], [72, 72, 72, 72])
            XCTAssertEqual(document.printInfo.paperSize, paper.size)
        }
    }

    func testWrapToPageUsesTheSetting() throws {
        Defaults.store.set(PaperSize.legal.rawValue, forKey: Defaults.paperSizeKey)
        Defaults.store.set(true, forKey: DefaultsKey.showPageBreaks.rawValue)
        let document = TextDocument()
        document.makeWindowControllers()
        documents.append(document)
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        let pages = try XCTUnwrap(controller.pagesView)
        XCTAssertEqual(pages.pageRect(forPage: 0).size, NSSize(width: 612, height: 1008))
        XCTAssertEqual(pages.documentRect(forPage: 0).size,
                       NSSize(width: 612 - 144 + 2 * MultiplePageView.textPadding, height: 1008 - 144))
    }

    /// An open document keeps its paper when the setting changes later
    /// (Settings apply to new documents).
    func testOpenDocumentKeepsItsPaper() {
        Defaults.store.set(PaperSize.letter.rawValue, forKey: Defaults.paperSizeKey)
        let document = TextDocument()
        documents.append(document)
        _ = document.pageLayout
        Defaults.store.set(PaperSize.a4.rawValue, forKey: Defaults.paperSizeKey)
        XCTAssertEqual(document.pageLayout.paperSize, PaperSize.letter.size)
    }

    /// M7 review item 4: the paper is fixed when the document is opened,
    /// not when something first asks for it. Nothing reads `pageLayout`
    /// before the setting changes.
    func testOpenedDocumentKeepsThePaperItWasOpenedWith() throws {
        Defaults.store.set(PaperSize.letter.rawValue, forKey: Defaults.paperSizeKey)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-paper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("opened.txt")
        try Data("opened under Letter\n".utf8).write(to: url)
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        documents.append(document)
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        XCTAssertFalse(controller.hasMultiplePages, "a file opens in Wrap to Window")
        Defaults.store.set(PaperSize.a4.rawValue, forKey: Defaults.paperSizeKey)
        NSApp.sendAction(#selector(TextDocument.togglePageBreaks(_:)), to: document, from: nil)
        XCTAssertEqual(try XCTUnwrap(controller.pagesView).pageRect(forPage: 0).size, PaperSize.letter.size)
        let pdfURL = folder.appendingPathComponent("opened.pdf")
        try document.writePDF(to: pdfURL, options: .init(headerAndFooter: false, wrappingToFit: true))
        XCTAssertEqual(PDFDocument(url: pdfURL)?.page(at: 0)?.bounds(for: .mediaBox).size, PaperSize.letter.size)
    }

    /// The same for a new untitled document: its paper is the setting at
    /// the moment it was made.
    func testNewDocumentKeepsThePaperItWasMadeWith() {
        Defaults.store.set(PaperSize.legal.rawValue, forKey: Defaults.paperSizeKey)
        let document = TextDocument()
        documents.append(document)
        Defaults.store.set(PaperSize.a4.rawValue, forKey: Defaults.paperSizeKey)
        XCTAssertEqual(document.pageLayout.paperSize, PaperSize.legal.size)
    }

    /// M7 review item 3: reading the print info of a fresh document is not
    /// an edit and leaves nothing to undo.
    func testReadingPrintInfoIsNotAnEdit() throws {
        let document = TextDocument()
        documents.append(document)
        let undoManager = try XCTUnwrap(document.undoManager)
        _ = document.printInfo
        _ = document.printInfo
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertFalse(undoManager.canUndo, "reading the print info registered an undo")
    }

    // MARK: The print helper

    /// Opening a document in Wrap to Page and laying it all out never asks
    /// NSPrintInfo for its paper or its dictionary: both reach macOS's print
    /// helper. Counted by swapping the two getters for counting ones.
    func testWrapToPageNeverAsksPrintInfoForPaper() throws {
        Defaults.store.set(true, forKey: DefaultsKey.showPageBreaks.rawValue)
        let counter = PrintInfoReadCounter()
        defer { counter.stop() }
        counter.start()
        let document = TextDocument()
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0),
                                               with: String(repeating: "a line of text\n", count: 400))
        document.makeWindowControllers()
        documents.append(document)
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        XCTAssertTrue(controller.hasMultiplePages)
        controller.layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: document.textStorage.length))
        XCTAssertGreaterThan(controller.numberOfPages, 1)
        let window = try XCTUnwrap(controller.window)
        _ = controller.windowWillUseStandardFrame(window, defaultFrame: NSRect(x: 0, y: 0, width: 3000, height: 2000))
        // State restoration encodes the document and the window.
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        document.encodeRestorableState(with: archiver)
        controller.encodeRestorableState(with: archiver)
        archiver.finishEncoding()
        // Back and forth.
        document.hasMultiplePages = false
        document.hasMultiplePages = true
        XCTAssertEqual(counter.counts, PrintInfoReadCounter.Counts(), "something asked NSPrintInfo")
    }

    /// The counter itself works: a direct read is counted.
    func testPrintInfoReadCounterCounts() {
        let counter = PrintInfoReadCounter()
        counter.start()
        let info = NSPrintInfo(dictionary: [.paperSize: NSValue(size: PaperSize.a4.size)])
        _ = info.paperSize
        _ = info.dictionary()
        _ = NSPrintInfo.shared
        counter.stop()
        _ = NSPrintInfo.shared // not counted after stop
        let counts = counter.counts
        XCTAssertEqual([counts.paper, counts.dictionary, counts.shared, counts.printer], [1, 1, 1, 0])
        // AppKit may make the shared print info on first use, so at least one.
        XCTAssertGreaterThanOrEqual(counts.made, 1)
        // `printer` is counted too. Its read is left out above: it asks the
        // print system for the printer list.
        XCTAssertTrue(PrintInfoReadCounter.countsPrinter)
    }

    // MARK: Settings > New Document

    private func makeController() -> SettingsWindowController {
        let controller = SettingsWindowController()
        controller.loadSettingsWindowIfNeeded()
        controllers.append(controller)
        return controller
    }

    // 1.2.0: the Settings Paper size pop-up is gone, and with it its two
    // tests (testSettingsHasAPaperSizePopUp, testChoosingAPaperWritesTheDefault).
    // The stored size stays and is still used (the tests above and below).

    func testRestoreAllDefaultsPutsTheRegionPaperBack() throws {
        let other: PaperSize = PaperSize.regionDefault(for: .current) == .legal ? .a4 : .legal
        Defaults.store.set(other.rawValue, forKey: Defaults.paperSizeKey)
        let controller = makeController()
        try XCTUnwrap(controller.restoreButton).performClick(nil)
        XCTAssertNil(saved.persisted?[Defaults.paperSizeKey])
        XCTAssertEqual(PaperSize.current, PaperSize.regionDefault(for: .current))
    }

    /// Rendered evidence for root: the New Document tab (no pop-up since 1.2.0),
    /// drawn off screen into build/m7-evidence (no window is shown).
    func testRenderNewDocumentTab() throws {
        let controller = makeController()
        let tab = try XCTUnwrap(controller.tabView?.tabViewItems[0].view)
        // The light look, so labels show on the white picture in dark mode.
        controller.window?.appearance = NSAppearance(named: .aqua)
        let pdf = tab.dataWithPDF(inside: tab.bounds)
        XCTAssertGreaterThan(pdf.count, 1000)
        if let folder = ProcessInfo.processInfo.environment["QE_M7_EVIDENCE"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try pdf.write(to: URL(fileURLWithPath: folder).appendingPathComponent("settings-new-document.pdf"))
        }
    }
}

/// Counts the NSPrintInfo calls that can reach macOS's print system, or
/// that make a print info: -paperSize, -dictionary, -printer,
/// +sharedPrintInfo and -initWithDictionary:. It swaps in counting
/// implementations; `stop` puts the originals back.
final class PrintInfoReadCounter {
    struct Counts: Equatable {
        var paper = 0, dictionary = 0, shared = 0, printer = 0, made = 0
    }
    nonisolated(unsafe) private static var current = Counts()
    nonisolated(unsafe) private static var running = false
    private var restore: [() -> Void] = []

    var counts: Counts { Self.current }
    var paperReads: Int { Self.current.paper }
    var dictionaryReads: Int { Self.current.dictionary }

    /// The `printer` getter is swapped too (checked by the counter test).
    static let countsPrinter = class_getInstanceMethod(NSPrintInfo.self, #selector(getter: NSPrintInfo.printer)) != nil

    private func method(_ selector: Selector, classMethod: Bool = false) -> Method {
        let found = classMethod ? class_getClassMethod(NSPrintInfo.self, selector)
                                : class_getInstanceMethod(NSPrintInfo.self, selector)
        guard let found else { preconditionFailure("NSPrintInfo has no \(selector)") }
        return found
    }

    private func swap(_ method: Method, _ block: Any) {
        let original = method_getImplementation(method)
        method_setImplementation(method, imp_implementationWithBlock(block))
        restore.append { method_setImplementation(method, original) }
    }

    func start() {
        Self.current = Counts()
        Self.running = true

        let paperSelector = #selector(getter: NSPrintInfo.paperSize)
        let paperMethod = method(paperSelector)
        let callPaper = unsafeBitCast(method_getImplementation(paperMethod),
                                      to: (@convention(c) (AnyObject, Selector) -> NSSize).self)
        swap(paperMethod, { (object: AnyObject) -> NSSize in
            PrintInfoReadCounter.current.paper += 1
            return callPaper(object, paperSelector)
        } as @convention(block) (AnyObject) -> NSSize)

        let dictionarySelector = #selector(NSPrintInfo.dictionary)
        let dictionaryMethod = method(dictionarySelector)
        let callDictionary = unsafeBitCast(method_getImplementation(dictionaryMethod),
                                           to: (@convention(c) (AnyObject, Selector) -> NSMutableDictionary).self)
        swap(dictionaryMethod, { (object: AnyObject) -> NSMutableDictionary in
            PrintInfoReadCounter.current.dictionary += 1
            return callDictionary(object, dictionarySelector)
        } as @convention(block) (AnyObject) -> NSMutableDictionary)

        let printerSelector = #selector(getter: NSPrintInfo.printer)
        let printerMethod = method(printerSelector)
        let callPrinter = unsafeBitCast(method_getImplementation(printerMethod),
                                        to: (@convention(c) (AnyObject, Selector) -> NSPrinter).self)
        swap(printerMethod, { (object: AnyObject) -> NSPrinter in
            PrintInfoReadCounter.current.printer += 1
            return callPrinter(object, printerSelector)
        } as @convention(block) (AnyObject) -> NSPrinter)

        let sharedSelector = #selector(getter: NSPrintInfo.shared)
        let sharedMethod = method(sharedSelector, classMethod: true)
        let callShared = unsafeBitCast(method_getImplementation(sharedMethod),
                                       to: (@convention(c) (AnyObject, Selector) -> NSPrintInfo).self)
        swap(sharedMethod, { (object: AnyObject) -> NSPrintInfo in
            PrintInfoReadCounter.current.shared += 1
            return callShared(object, sharedSelector)
        } as @convention(block) (AnyObject) -> NSPrintInfo)

        // An init consumes its receiver and returns a +1 object; Unmanaged
        // passes both through without any retain or release.
        let initSelector = #selector(NSPrintInfo.init(dictionary:))
        let initMethod = method(initSelector)
        typealias Init = @convention(c) (Unmanaged<AnyObject>, Selector, NSDictionary) -> Unmanaged<AnyObject>?
        let callInit = unsafeBitCast(method_getImplementation(initMethod), to: Init.self)
        swap(initMethod, { (object: Unmanaged<AnyObject>, dictionary: NSDictionary) -> Unmanaged<AnyObject>? in
            PrintInfoReadCounter.current.made += 1
            return callInit(object, initSelector, dictionary)
        } as @convention(block) (Unmanaged<AnyObject>, NSDictionary) -> Unmanaged<AnyObject>?)
    }

    func stop() {
        Self.running = false
        restore.reversed().forEach { $0() }
        restore = []
    }
}
