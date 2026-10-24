import AppKit
import XCTest
@testable import QuickEdit

/// M5 n2: Format > Wrap to Page and Wrap to Window, the page view, Page
/// Setup, the Zoom button, the scroller style rule, renders and the 10 MB
/// switch time (reference/apple/DocumentWindowController.m:459-631, :860-897,
/// :992-1022, MultiplePageView.m; docs/codemap.md section 5).
@MainActor
final class PageModeTests: XCTestCase {
    private var folder: URL!
    private var documents: [NSDocument] = []
    private var savedDefaults: [String: Any]?
    private let bundleID = Bundle.main.bundleIdentifier ?? "dev.yili.QuickEdit"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedDefaults = UserDefaults.standard.persistentDomain(forName: bundleID)
        ScalingScrollView.animatesZoom = false
    }

    override func tearDown() async throws {
        ScalingScrollView.animatesZoom = true
        for document in documents {
            // Edited documents would autosave later into the deleted folder
            // and the error alert would stop the test run.
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        if let savedDefaults {
            UserDefaults.standard.setPersistentDomain(savedDefaults, forName: bundleID)
        } else {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    // MARK: Helpers

    private func open(_ text: String, name: String = "pages.txt") throws -> (TextDocument, DocumentWindowController) {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        document.makeWindowControllers()
        documents.append(document)
        return (document, try XCTUnwrap(document.windowControllers.first as? DocumentWindowController))
    }

    /// Lines of text that each fit on one line of a page.
    private func lines(_ count: Int) -> String {
        (0..<count).map { String(format: "line %05d of the page test", $0) }.joined(separator: "\n") + "\n"
    }

    /// Lines on one page, measured by laying out a long text in Wrap to
    /// Page, then put back to Wrap to Window with the text emptied.
    private func measuredLinesPerPage(_ document: TextDocument, _ controller: DocumentWindowController) throws -> Int {
        let estimate = linesPerPage(document, controller)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: document.textStorage.length),
                                               with: lines(estimate * 2))
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        try toggle(document)
        controller.layoutManager.ensureLayout(for: controller.layoutManager.textContainers[0])
        let measured = linesOnFirstPage(controller)
        try toggle(document)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: document.textStorage.length), with: "")
        document.undoManager?.removeAllActions()
        return measured
    }

    /// Text lines that fit on one page with the document's print info, from the font's line height.
    private func linesPerPage(_ document: TextDocument, _ controller: DocumentWindowController) -> Int {
        let height = MultiplePageView.documentSize(for: document.printInfo).height
        let lineHeight = controller.layoutManager.defaultLineHeight(for: TextViewFactory.plainFont())
        return Int(height / lineHeight)
    }

    /// Lines on page 1, from the laid-out text.
    private func linesOnFirstPage(_ controller: DocumentWindowController) -> Int {
        let manager = controller.layoutManager
        let glyphs = manager.glyphRange(for: manager.textContainers[0])
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let text = (manager.textStorage?.string ?? "") as NSString
        return text.substring(with: characters).filter { $0 == "\n" }.count
    }

    /// Lays out the whole text (fine for these small texts).
    private func layOutAll(_ controller: DocumentWindowController) {
        let length = controller.layoutManager.textStorage?.length ?? 0
        controller.layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: length))
    }

    /// Format > Wrap to Page / Wrap to Window, sent from the real menu item.
    private func toggle(_ document: TextDocument, file: StaticString = #filePath, line: UInt = #line) throws {
        let item = try XCTUnwrap(MainMenu.build().item(withTitle: "Format")?.submenu?
            .items.first { $0.action == #selector(TextDocument.togglePageBreaks(_:)) }, "no Wrap to Page item")
        XCTAssertTrue(NSApp.sendAction(#selector(TextDocument.togglePageBreaks(_:)), to: document, from: item),
                      file: file, line: line)
    }

    /// One keystroke in its own undo group (see ReviewFixTests.type).
    private func type(_ text: String, into textView: NSTextView, of document: NSDocument) {
        let undoManager = document.undoManager!
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        textView.insertText(text, replacementRange: textView.selectedRange())
        undoManager.endUndoGrouping()
        undoManager.groupsByEvent = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: Start mode and menu

    func testNewDocumentsFollowShowPageBreaksAndOpenedFilesWrapToWindow() throws {
        UserDefaults.standard.set(true, forKey: DefaultsKey.showPageBreaks.rawValue)
        let untitled = TextDocument()
        untitled.makeWindowControllers()
        documents.append(untitled)
        let untitledController = try XCTUnwrap(untitled.windowControllers.first as? DocumentWindowController)
        XCTAssertTrue(untitled.hasMultiplePages)
        XCTAssertNotNil(untitledController.pagesView)
        XCTAssertEqual(untitledController.textViews.count, 1)

        let (opened, openedController) = try open("opened\n")
        XCTAssertFalse(opened.hasMultiplePages, "opened plain files start in Wrap to Window, as in TextEdit")
        XCTAssertNil(openedController.pagesView)

        UserDefaults.standard.set(false, forKey: DefaultsKey.showPageBreaks.rawValue)
        let plain = TextDocument()
        plain.makeWindowControllers()
        documents.append(plain)
        XCTAssertFalse(plain.hasMultiplePages)
    }

    func testMenuItemAndTitleFlip() throws {
        let format = try XCTUnwrap(MainMenu.build().item(withTitle: "Format")?.submenu)
        XCTAssertEqual(format.items.map(\.title), ["Prevent Editing", "Wrap to Page"])
        let item = try XCTUnwrap(format.item(withTitle: "Wrap to Page"))
        XCTAssertEqual(item.action, #selector(TextDocument.togglePageBreaks(_:)))
        XCTAssertEqual(item.keyEquivalent, "w")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])

        let (document, _) = try open("menu\n")
        XCTAssertTrue(document.validateMenuItem(item))
        XCTAssertEqual(item.title, "Wrap to Page")
        try toggle(document)
        XCTAssertTrue(document.validateMenuItem(item))
        XCTAssertEqual(item.title, "Wrap to Window")
        try toggle(document)
        XCTAssertTrue(document.validateMenuItem(item))
        XCTAssertEqual(item.title, "Wrap to Page")
    }

    // MARK: The switch

    /// A 3-page text: Wrap to Page makes 3 text views on the same storage and
    /// layout manager, keeps the selection and the edited state, and Undo of
    /// typing done before the switch still works; Wrap to Window goes back
    /// to one text view.
    func testToggleKeepsTextSelectionUndoAndEditedState() throws {
        let (document, controller) = try open("")
        let perPage = try measuredLinesPerPage(document, controller)
        let original = lines(perPage * 2 + perPage / 2)
        // Reload through the storage so the file holds the 3-page text.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0),
                                               with: NSAttributedString(string: original,
                                                                        attributes: TextViewFactory.plainTextAttributes()))
        document.undoManager?.removeAllActions()
        document.updateChangeCount(.changeCleared)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(document.isDocumentEdited)

        // Unedited stays unedited.
        try toggle(document)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(document.isDocumentEdited, "switching marked the document edited")
        try toggle(document)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(document.isDocumentEdited, "switching back marked the document edited")

        // Type, select, switch.
        controller.textView.setSelectedRange(NSRange(location: 5, length: 0))
        type("TYPED", into: controller.textView, of: document)
        XCTAssertTrue(document.isDocumentEdited)
        let selection = NSRange(location: (original as NSString).length / 2, length: 7)
        controller.textView.setSelectedRange(selection)

        try toggle(document)
        layOutAll(controller)
        XCTAssertTrue(controller.hasMultiplePages)
        let pagesView = try XCTUnwrap(controller.pagesView)
        XCTAssertTrue(controller.scrollView.documentView === pagesView)
        XCTAssertEqual(controller.textViews.count, 3)
        XCTAssertEqual(pagesView.numberOfPages, 3)
        for (page, view) in controller.textViews.enumerated() {
            XCTAssertTrue(view.layoutManager === controller.layoutManager, "page \(page) has its own layout manager")
            XCTAssertTrue(view.textStorage === document.textStorage, "page \(page) is not on the document's storage")
            XCTAssertTrue(view.superview === pagesView)
            XCTAssertEqual(view.frame, pagesView.documentRect(forPage: page))
            XCTAssertFalse(view.isRichText)
            XCTAssertTrue(view.allowsUndo)
            XCTAssertTrue(view.delegate === controller)
            XCTAssertTrue(view.usesFindBar)
            XCTAssertEqual(view.isContinuousSpellCheckingEnabled, Defaults.bool(.checkSpellingWhileTyping))
            XCTAssertEqual(view.isAutomaticQuoteSubstitutionEnabled, Defaults.bool(.smartQuotes))
        }
        XCTAssertEqual(document.textStorage.layoutManagers.count, 1)
        XCTAssertEqual(controller.textView.selectedRange(), selection)
        XCTAssertTrue(controller.window?.firstResponder === controller.textView)
        XCTAssertTrue(document.isDocumentEdited, "switching cleared the edited mark")

        // Undo the typing done before the switch.
        document.undoManager?.undo()
        XCTAssertEqual(document.textStorage.string, original)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(document.isDocumentEdited)
        document.undoManager?.redo()
        XCTAssertTrue(document.textStorage.string.hasPrefix("line TYPED"))

        // Typing on page 3 goes into the shared storage, with plain attributes.
        let page3 = controller.textViews[2]
        let end = document.textStorage.length
        page3.setSelectedRange(NSRange(location: end, length: 0))
        type("tail", into: page3, of: document)
        XCTAssertTrue(document.textStorage.string.hasSuffix("tail"))
        XCTAssertEqual(document.textStorage.attribute(.font, at: document.textStorage.length - 1, effectiveRange: nil) as? NSFont,
                       TextViewFactory.plainFont())

        // Back to Wrap to Window.
        let selectionBefore = controller.textView.selectedRange()
        try toggle(document)
        XCTAssertFalse(controller.hasMultiplePages)
        XCTAssertEqual(controller.textViews.count, 1)
        XCTAssertNil(controller.pagesView)
        XCTAssertTrue(controller.scrollView.documentView === controller.textView)
        XCTAssertEqual(controller.textView.selectedRange(), selectionBefore)
        XCTAssertTrue(controller.textView.textContainer?.widthTracksTextView ?? false)
        XCTAssertTrue(controller.textView.isVerticallyResizable)
        document.undoManager?.undo()
        XCTAssertFalse(document.textStorage.string.hasSuffix("tail"), "undo after switching back")
    }

    /// Prevent Editing holds on every page.
    func testPreventEditingCoversEveryPage() throws {
        let (document, controller) = try open(lines(200))
        document.toggleReadOnly(nil)
        try toggle(document)
        layOutAll(controller)
        XCTAssertGreaterThan(controller.textViews.count, 1)
        XCTAssertTrue(controller.textViews.allSatisfy { !$0.isEditable })
        document.toggleReadOnly(nil)
        XCTAssertTrue(controller.textViews.allSatisfy(\.isEditable))
    }

    /// Pages come as layout reaches them, not at the switch; deleting text
    /// removes empty trailing pages.
    func testPagesAreAddedAsLayoutReachesThemAndRemovedWhenEmpty() throws {
        let (document, controller) = try open("")
        let perPage = linesPerPage(document, controller)
        let count = perPage * 20 - perPage / 2
        let text = lines(count)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        try toggle(document)
        let atSwitch = controller.numberOfPages
        XCTAssertLessThan(atSwitch, 5, "the switch laid out far past the first page")

        // Lay out to the middle: about half the pages.
        let middle = (text as NSString).length / 2
        controller.layoutManager.ensureLayout(forCharacterRange: NSRange(location: middle, length: 1))
        let atMiddle = controller.numberOfPages
        XCTAssertGreaterThanOrEqual(atMiddle, 9)
        XCTAssertLessThan(atMiddle, 15)

        layOutAll(controller)
        let onPage = linesOnFirstPage(controller)
        let expected = (count + onPage - 1) / onPage
        XCTAssertEqual(controller.numberOfPages, expected)
        XCTAssertEqual(controller.textViews.count, expected)
        XCTAssertGreaterThanOrEqual(expected, 20)
        let pagesView = try XCTUnwrap(controller.pagesView)
        XCTAssertEqual(pagesView.frame.height, pagesView.pageRect(forPage: expected - 1).maxY, accuracy: 0.5)
        print("M5-PAGES at switch \(atSwitch), at middle \(atMiddle), all \(expected); lines per page \(onPage);"
              + " non-contiguous layout in page mode: \(controller.layoutManager.hasNonContiguousLayout)")

        // Delete all but the first line: back to one page.
        let firstLineEnd = (text as NSString).range(of: "\n").upperBound
        document.textStorage.replaceCharacters(in: NSRange(location: firstLineEnd, length: document.textStorage.length - firstLineEnd),
                                               with: "")
        // No layout callback comes for this edit (the text left is laid
        // out already); the window removes the pages on the next turn.
        layOutAll(controller)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(controller.numberOfPages, 1)
        XCTAssertEqual(controller.textViews.count, 1)
        XCTAssertEqual(pagesView.subviews.count, 1)

        // Again, deleting through the text view from inside line 1: here
        // the layout callback removes the pages.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: document.textStorage.length), with: text)
        layOutAll(controller)
        XCTAssertEqual(controller.numberOfPages, expected)
        let view = controller.textView
        let range = NSRange(location: 3, length: document.textStorage.length - 3)
        view.setSelectedRange(range)
        view.insertText("", replacementRange: range)
        layOutAll(controller)
        XCTAssertEqual(controller.numberOfPages, 1)
        XCTAssertEqual(document.textStorage.string, "lin")
    }

    func testEmptyDocumentHasOnePage() throws {
        let (document, controller) = try open("")
        try toggle(document)
        layOutAll(controller)
        XCTAssertEqual(controller.numberOfPages, 1)
        XCTAssertEqual(controller.textViews.count, 1)
    }

    // MARK: Page Setup

    /// A smaller paper makes more, smaller pages; every page view follows.
    func testPageSetupWithSmallerPaperAddsPages() throws {
        let (document, controller) = try open("")
        let perPage = try measuredLinesPerPage(document, controller)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: lines(perPage * 2 + perPage / 2))
        try toggle(document)
        layOutAll(controller)
        XCTAssertEqual(controller.numberOfPages, 3)

        let smaller = try XCTUnwrap(document.printInfo.copy() as? NSPrintInfo)
        smaller.paperSize = NSSize(width: 420, height: 595) // A5
        document.printInfo = smaller
        layOutAll(controller)
        let pagesView = try XCTUnwrap(controller.pagesView)
        XCTAssertEqual(pagesView.printInfo.paperSize, NSSize(width: 420, height: 595))
        XCTAssertGreaterThan(controller.numberOfPages, 3, "a smaller paper must make more pages")
        for (page, view) in controller.textViews.enumerated() {
            XCTAssertEqual(view.frame, pagesView.documentRect(forPage: page), "page \(page) kept the old size")
            XCTAssertEqual(view.textContainer?.size, MultiplePageView.documentSize(for: smaller))
        }
        XCTAssertEqual(pagesView.frame.width, 420)

        // Back to the old paper: back to 3 pages.
        let letter = try XCTUnwrap(smaller.copy() as? NSPrintInfo)
        letter.paperSize = NSSize(width: 612, height: 792)
        document.printInfo = letter
        layOutAll(controller)
        XCTAssertEqual(controller.numberOfPages, 3)
    }

    /// Page geometry is TextEdit's: paper minus margins plus the padding.
    func testPageGeometry() throws {
        let info = try XCTUnwrap(NSPrintInfo.shared.copy() as? NSPrintInfo)
        info.paperSize = NSSize(width: 612, height: 792)
        info.leftMargin = 72; info.rightMargin = 72; info.topMargin = 90; info.bottomMargin = 90
        let view = MultiplePageView(printInfo: info)
        let padding = MultiplePageView.textPadding
        XCTAssertEqual(MultiplePageView.documentSize(for: info), NSSize(width: 612 - 144 + 2 * padding, height: 792 - 180))
        XCTAssertEqual(view.pageRect(forPage: 1), NSRect(x: 0, y: 797, width: 612, height: 792))
        XCTAssertEqual(view.documentRect(forPage: 1).origin, NSPoint(x: 72 - padding, y: 797 + 90))
        XCTAssertEqual(view.pageSeparatorHeight, 5)
    }

    // MARK: Window

    /// The Zoom button in Wrap to Page fits one page width (legacy scrollers).
    func testZoomButtonFitsOnePageWidth() throws {
        let (document, controller) = try open(lines(10))
        let window = try XCTUnwrap(controller.window)
        let screenFrame = NSRect(x: 0, y: 0, width: 3000, height: 2000)
        XCTAssertEqual(controller.windowWillUseStandardFrame(window, defaultFrame: screenFrame), screenFrame,
                       "Wrap to Window keeps AppKit's frame")
        try toggle(document)
        let frame = controller.windowWillUseStandardFrame(window, defaultFrame: screenFrame)
        let content = window.contentRect(forFrameRect: frame)
        let paper = document.printInfo.paperSize
        let expected = NSScrollView.frameSize(forContentSize: paper, horizontalScrollerClass: NSScroller.self,
                                              verticalScrollerClass: NSScroller.self, borderType: .noBorder,
                                              controlSize: .regular, scrollerStyle: .legacy)
        XCTAssertEqual(content.size, expected)
        XCTAssertEqual(frame.maxY, window.frame.maxY, "the top edge stays")
        XCTAssertEqual(frame.minX, window.frame.minX, "the left edge stays")
    }

    /// P44: a scroller style change keeps the text width, not the window width.
    func testScrollerStyleChangeKeepsTextWidth() throws {
        let (_, controller) = try open(lines(10))
        let scrollView = controller.scrollView
        let start = scrollView.scrollerStyle
        let other: NSScroller.Style = start == .overlay ? .legacy : .overlay
        let width = scrollView.contentSize.width
        let windowWidth = try XCTUnwrap(controller.window).frame.width
        scrollView.scrollerStyle = other
        XCTAssertEqual(scrollView.contentSize.width, width, accuracy: 0.5, "text width changed with the scroller style")
        XCTAssertNotEqual(try XCTUnwrap(controller.window).frame.width, windowWidth, "the window did not resize")
        scrollView.scrollerStyle = start
        XCTAssertEqual(scrollView.contentSize.width, width, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(controller.window).frame.width, windowWidth, accuracy: 0.5)
    }

    /// Windows join tabs as TextEdit's do (Window > Merge All Windows).
    func testWindowsTabAutomatically() throws {
        let (_, controller) = try open("tabs\n")
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.tabbingMode, .automatic)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary)
                      || !window.collectionBehavior.contains(.fullScreenAuxiliary),
                      "the window must be able to go full screen")
    }

    // MARK: Renders (read by root)

    private static var shotsFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/shots", isDirectory: true)
    }

    @discardableResult
    private func render(_ controller: DocumentWindowController, _ name: String) throws -> URL {
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: Self.shotsFolder, withIntermediateDirectories: true)
        let url = Self.shotsFolder.appendingPathComponent("\(name).png")
        try png.write(to: url)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("M5-SHOT \(url.path)")
        return url
    }

    /// Both modes at 50%, 100% and 200%, plus page mode in dark mode.
    func testRenderBothModesAtThreeScales() throws {
        let (document, controller) = try open("")
        let perPage = try measuredLinesPerPage(document, controller)
        var sample = "QuickEdit M5 render check: Wrap to Window and Wrap to Page\n\tone tab\n"
            + String(repeating: "x", count: 90) + "|\n"
            + "A long line that wraps at the window or page edge. " + String(repeating: "word ", count: 30) + "\n"
        sample += lines(perPage + perPage / 2)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0),
                                               with: NSAttributedString(string: sample,
                                                                        attributes: TextViewFactory.plainTextAttributes()))
        let window = try XCTUnwrap(controller.window)
        window.appearance = NSAppearance(named: .aqua)
        for scale in [0.5, 1.0, 2.0] {
            controller.scrollView.magnification = scale
            controller.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            try render(controller, "window-\(Int(scale * 100))")
        }
        controller.scrollView.magnification = 1
        try toggle(document)
        // A page-sized window, as TextEdit's Zoom button gives.
        window.setFrame(controller.windowWillUseStandardFrame(window, defaultFrame: window.frame), display: false)
        layOutAll(controller)
        XCTAssertEqual(controller.numberOfPages, 2)
        for scale in [0.5, 1.0, 2.0] {
            controller.scrollView.magnification = scale
            controller.scrollView.contentView.scroll(to: .zero)
            controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
            try render(controller, "page-\(Int(scale * 100))")
        }
        // Dark mode: the page stays paper white with dark text, as TextEdit's.
        controller.scrollView.magnification = 0.5
        window.appearance = NSAppearance(named: .darkAqua)
        try render(controller, "page-50-dark")
        let pageText = controller.textView
        XCTAssertEqual(pageText.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        try toggle(document)
        controller.scrollView.magnification = 1
        try render(controller, "window-100-dark")
        XCTAssertEqual(controller.textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
    }

    // MARK: Speed

    /// The 10 MB fixture of bench/make-fixtures.sh, made the same way.
    private func tenMegabyteText() -> String {
        let size = 10 * 1024 * 1024
        var out = ""
        out.reserveCapacity(size)
        var n = 0
        while out.utf8.count < size {
            var line = String(format: "line %08d the quick brown fox jumps over the lazy dog 0123456789\n", n)
            n += 1
            if out.utf8.count + line.utf8.count > size {
                line = String(line.prefix(size - out.utf8.count - 1)) + "\n"
            }
            out += line
        }
        return out
    }

    /// Wrap to Page on a 10 MB file: median of 5 switches, each until the
    /// first page is drawn. Under 300 ms is required in an optimized build.
    /// Then the main thread must stay responsive while AppKit's background
    /// layout adds pages: the longest gap between 10 ms timer ticks is reported.
    func testTenMegabyteSwitchTime() throws {
        let url = folder.appendingPathComponent("10mb.txt")
        try Data(tenMegabyteText().utf8).write(to: url)
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        document.makeWindowControllers()
        documents.append(document)
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        let content = try XCTUnwrap(controller.window?.contentView)
        func draw() throws {
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
        }
        try draw()
        var onTimes: [Double] = [], offTimes: [Double] = [], pagesAtSwitch: [Int] = []
        for _ in 0..<5 {
            var start = DispatchTime.now().uptimeNanoseconds
            document.togglePageBreaks(nil)
            try draw()
            onTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            pagesAtSwitch.append(controller.numberOfPages)
            XCTAssertTrue(controller.hasMultiplePages)
            start = DispatchTime.now().uptimeNanoseconds
            document.togglePageBreaks(nil)
            try draw()
            offTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let median = onTimes.sorted()[2]
        let offMedian = offTimes.sorted()[2]

        // Responsiveness while background layout adds pages.
        document.togglePageBreaks(nil)
        try draw()
        let nonContiguousWithOnePage = controller.layoutManager.hasNonContiguousLayout
        let meter = GapMeter()
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated { meter.tick() }
        }
        RunLoop.current.add(timer, forMode: .default)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        timer.invalidate()
        let longestGap = meter.longest
        let slowGaps = meter.gaps.filter { $0 > 50 }
        let pagesAfter3s = controller.numberOfPages

        let report = "M5-TIMING 10MB switch to page ms: \(onTimes.map { String(format: "%.1f", $0) }) median \(String(format: "%.1f", median)); "
            + "back to window ms: \(offTimes.map { String(format: "%.1f", $0) }) median \(String(format: "%.1f", offMedian)); "
            + "pages right after switch: \(pagesAtSwitch); pages after 3 s of idle: \(pagesAfter3s); "
            + "longest main-thread gap during background layout: \(String(format: "%.1f", longestGap)) ms; "
            + "gaps over 50 ms: \(slowGaps.count) \(slowGaps.prefix(8).map { String(format: "%.0f", $0) }); "
            + "hasNonContiguousLayout right after switch: \(nonContiguousWithOnePage), after 3 s: \(controller.layoutManager.hasNonContiguousLayout); "
            + "optimized: \(!_isDebugAssertConfiguration())"
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "10mb-switch-time"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(pagesAtSwitch.allSatisfy { $0 < 10 }, "the switch laid out far past the first page")
        if !_isDebugAssertConfiguration() {
            XCTAssertLessThan(median, 300, "10 MB switch to Wrap to Page took \(median) ms")
        }
    }

    /// The longest time between two timer ticks on the main thread.
    @MainActor
    private final class GapMeter {
        private var last = DispatchTime.now().uptimeNanoseconds
        private(set) var gaps: [Double] = []
        var longest: Double { gaps.max() ?? 0 }
        func tick() {
            let now = DispatchTime.now().uptimeNanoseconds
            gaps.append(Double(now - last) / 1e6)
            last = now
        }
    }
}
