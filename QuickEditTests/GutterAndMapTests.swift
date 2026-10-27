import AppKit
import QuartzCore
import XCTest
@testable import QuickEdit

/// 1.2.0 changes 2 and 3: the line-number gutter on the left and the
/// document map on the right. Both are on by default and turned off from
/// the View menu (saved); both hide in Wrap to Page; the map also hides in
/// large-file mode. "Width: N characters" still means N characters of text.
@MainActor
final class GutterAndMapTests: XCTestCase {
    private var saved: SavedSettings!
    private var documents: [NSDocument] = []
    private var folder: URL!

    override func setUp() async throws {
        saved = SavedSettings()
        // Line numbers are off by default since 1.2.1; these tests are
        // about the gutter, so they start with it on (the default itself is
        // checked in HoverBoxAndOptionsTests).
        Defaults.store.set(true, forKey: Defaults.showLineNumbersKey)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-gutter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        try? FileManager.default.removeItem(at: folder)
        saved.restore()
    }

    /// A document window on screen holding `text` (read from a file when
    /// `fromFile`, so the large-file mode can apply).
    private func window(_ text: String, fromFile: Bool = false) throws -> DocumentWindowController {
        let document: TextDocument
        if fromFile {
            let url = folder.appendingPathComponent("text-\(documents.count).txt")
            try Data(text.utf8).write(to: url)
            document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        } else {
            document = TextDocument()
            document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0),
                                                   with: NSAttributedString(string: text, attributes: TextViewFactory.plainTextAttributes()))
        }
        document.makeWindowControllers()
        documents.append(document)
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        controller.window?.orderFront(nil)
        settle(controller)
        return controller
    }

    private func settle(_ controller: DocumentWindowController) {
        controller.window?.layoutIfNeeded()
        controller.window?.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func numbered(_ count: Int) -> String {
        (1...count).map { "line \($0)" }.joined(separator: "\n") + "\n"
    }

    private func gutterShows(_ controller: DocumentWindowController) -> Bool {
        controller.scrollView.hasVerticalRuler && controller.scrollView.rulersVisible
            && controller.scrollView.verticalRulerView === controller.lineNumberView
    }

    // MARK: On by default, View menu toggles

    func testBothAreOnByDefault() throws {
        XCTAssertEqual(Defaults.registeredValues()[Defaults.showLineNumbersKey] as? Bool, false)  // 1.2.1
        XCTAssertEqual(Defaults.registeredValues()[Defaults.showDocumentMapKey] as? Bool, true)
        let controller = try window(numbered(60))
        XCTAssertTrue(gutterShows(controller))
        XCTAssertGreaterThan(controller.lineNumberView.ruleThickness, 10)
        let map = controller.documentMap
        XCTAssertFalse(map.isHidden)
        XCTAssertEqual(map.frame.width, DocumentMapView.width)
        let content = try XCTUnwrap(controller.window?.contentView)
        XCTAssertTrue(content === controller.container)
        XCTAssertEqual(map.frame.maxX, content.bounds.maxX, "the map is on the right")
        XCTAssertEqual(controller.scrollView.frame.maxX, map.frame.minX, accuracy: 0.5)
        XCTAssertEqual(controller.lineNumberView.frame.minX, 0, accuracy: 0.5, "the gutter is on the left")
    }

    func testViewMenuItemsToggleAndSave() throws {
        let controller = try window(numbered(60))
        let bar = MainMenu.build()
        let view = try XCTUnwrap(bar.item(withTitle: "View")?.submenu)
        let lineNumbers = try XCTUnwrap(view.item(withTitle: "Show Line Numbers"))
        let map = try XCTUnwrap(view.item(withTitle: "Show Document Map"))
        for (item, id) in [(lineNumbers, "view.lineNumbers"), (map, "view.documentMap")] {
            XCTAssertEqual((item.representedObject as? MenuCommand)?.id, id, "a stable id, so Settings > Keyboard lists it")
            XCTAssertTrue(item.target === ViewOptionsCommand.shared)
            XCTAssertTrue(ViewOptionsCommand.shared.validateMenuItem(item))
            XCTAssertEqual(item.state, .on)
        }
        let width = try XCTUnwrap(controller.window).frame.width

        NSApp.sendAction(try XCTUnwrap(lineNumbers.action), to: lineNumbers.target, from: lineNumbers)
        XCTAssertFalse(gutterShows(controller), "Show Line Numbers off hides the gutter")
        XCTAssertEqual(Defaults.store.object(forKey: Defaults.showLineNumbersKey) as? Bool, false, "saved")
        XCTAssertTrue(ViewOptionsCommand.shared.validateMenuItem(lineNumbers))
        XCTAssertEqual(lineNumbers.state, .off)
        NSApp.sendAction(try XCTUnwrap(map.action), to: map.target, from: map)
        XCTAssertTrue(controller.documentMap.isHidden)
        XCTAssertEqual(controller.scrollView.frame.width, try XCTUnwrap(controller.window?.contentView).bounds.width,
                       "a hidden map takes no width")
        XCTAssertEqual(Defaults.store.object(forKey: Defaults.showDocumentMapKey) as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(controller.window).frame.width, width, "the window keeps its size")

        // A new window reads the saved choice.
        let second = try window("two")
        XCTAssertFalse(gutterShows(second))
        XCTAssertTrue(second.documentMap.isHidden)

        NSApp.sendAction(try XCTUnwrap(lineNumbers.action), to: lineNumbers.target, from: lineNumbers)
        NSApp.sendAction(try XCTUnwrap(map.action), to: map.target, from: map)
        XCTAssertTrue(gutterShows(controller))
        XCTAssertFalse(controller.documentMap.isHidden)
        XCTAssertTrue(gutterShows(second))
    }

    func testRestoreAllDefaultsTurnsBothBackOn() throws {
        Defaults.store.set(false, forKey: Defaults.showLineNumbersKey)
        Defaults.store.set(false, forKey: Defaults.showDocumentMapKey)
        let controller = try window("text")
        XCTAssertFalse(gutterShows(controller))
        let settings = SettingsWindowController()
        settings.loadSettingsWindowIfNeeded()
        defer { settings.window?.close() }
        settings.restoreAllDefaults(nil)
        XCTAssertFalse(gutterShows(controller), "line numbers are off by default since 1.2.1")
        XCTAssertFalse(controller.documentMap.isHidden)
    }

    // MARK: When they hide

    func testWrapToPageHidesBothAndWrapToWindowBringsThemBack() throws {
        let controller = try window(numbered(60))
        let document = try XCTUnwrap(controller.document as? TextDocument)
        document.hasMultiplePages = true
        XCTAssertFalse(gutterShows(controller), "no gutter in Wrap to Page")
        XCTAssertTrue(controller.documentMap.isHidden, "no map in Wrap to Page")
        document.hasMultiplePages = false
        XCTAssertTrue(gutterShows(controller))
        XCTAssertFalse(controller.documentMap.isHidden)
        XCTAssertTrue(controller.lineNumberView.textView === controller.textView, "the gutter follows the new text view")
        XCTAssertTrue(controller.documentMap.textView === controller.textView)
    }

    /// Large-file mode (over 50 MB) hides the gutter and the map and
    /// builds no line index at all: 8 bytes per line start would need
    /// gigabytes for a 1 GB file of short lines. The View menu items are
    /// off while such a window is in front.
    func testLargeFileHidesBothAndBuildsNoIndex() throws {
        let threshold = TextDocument.largeFileThreshold
        defer { TextDocument.largeFileThreshold = threshold }
        TextDocument.largeFileThreshold = 1_000
        let controller = try window(numbered(400), fromFile: true)
        XCTAssertTrue(try XCTUnwrap(controller.document as? TextDocument).isLargeFile)
        XCTAssertTrue(controller.documentMap.isHidden, "no map in large-file mode")
        XCTAssertFalse(gutterShows(controller), "no gutter in large-file mode")
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("new line\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(controller)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(controller.lineIndex.scannedTo, 0, "the index was built for a large file")
        XCTAssertEqual(controller.lineIndex.knownLineCount, 1)
        let view = try XCTUnwrap(MainMenu.build().item(withTitle: "View")?.submenu)
        controller.window?.orderFront(nil)
        for title in ["Show Line Numbers", "Show Document Map"] {
            let item = try XCTUnwrap(view.item(withTitle: title))
            XCTAssertFalse(ViewOptionsCommand.shared.validateMenuItem(item), "\(title) is on for a large file")
        }
    }

    // MARK: Window size

    /// "Width: 60 characters" makes a text area of 60 x-advances plus the
    /// line padding, with the gutter and the map outside it.
    func testWidthInCharactersStillMeansTextWidth() throws {
        Defaults.store.set(60, forKey: DefaultsKey.widthInChars.rawValue)
        let controller = try window("x")
        let font = TextViewFactory.plainFont()
        let expected = (60 * TextViewFactory.xAdvance(of: font) + 2 * NSTextContainer().lineFragmentPadding).rounded(.up)
        XCTAssertEqual(controller.scrollView.contentSize.width, expected, accuracy: 0.5)
        // AppKit insets the clip view by the gutter; the text view is the text area.
        XCTAssertEqual(controller.textView.frame.width, expected, accuracy: 0.5, "the text view is the text area")
        XCTAssertEqual(controller.scrollView.contentView.contentInsets.left, controller.lineNumberView.ruleThickness)
        XCTAssertGreaterThan(controller.sideWidth, DocumentMapView.width)
        let content = try XCTUnwrap(controller.window?.contentView)
        XCTAssertGreaterThanOrEqual(content.bounds.width,
                                    expected + controller.lineNumberView.ruleThickness + DocumentMapView.width)
    }

    // MARK: The gutter's numbers

    func testGutterNumbersLogicalLinesOnScreenOnly() throws {
        let long = String(repeating: "wrapped words ", count: 40)
        let controller = try window(numbered(5) + long + "\n" + numbered(200))
        let labels = controller.lineNumberView.visibleLabels()
        XCTAssertGreaterThan(labels.count, 5)
        XCTAssertEqual(labels.map(\.number), Array(1...labels.count), "one number per logical line, in order")
        // Line 6 wraps over several rows: the gap to line 7 is bigger.
        let rowGap = labels[1].y - labels[0].y
        XCTAssertGreaterThan(labels[6].y - labels[5].y, rowGap * 1.5, "a wrapped line gets one number")
        XCTAssertLessThan(labels.count, 100, "only the lines on screen are numbered")
        XCTAssertGreaterThanOrEqual(controller.lineNumberView.digits, 3)

        // Scrolled down: the first number is the first line on screen.
        controller.documentMap.scrollText(toLine: 120)
        settle(controller)
        let scrolled = controller.lineNumberView.visibleLabels()
        XCTAssertEqual(scrolled.first?.number, 121)
    }

    func testGutterFollowsEdits() throws {
        let controller = try window(numbered(3))
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("new\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle(controller)
        XCTAssertEqual(controller.lineNumberView.visibleLabels().map(\.number), [1, 2, 3, 4, 5])
    }

    /// Typing inside a line must not redraw the gutter with each key
    /// (AppKit asks for it each time the text view's frame is set); a new
    /// line redraws it at once.
    func testTypingInsideALineDoesNotRedrawTheGutterEachKey() throws {
        let controller = try window(numbered(3_000))
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: textView.textStorage?.length ?? 0, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        settle(controller)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let gutter = controller.lineNumberView
        let before = gutter.drawCount
        for i in 0..<30 {
            textView.insertText(String(UnicodeScalar(UInt8(97 + i))), replacementRange: NSRange(location: NSNotFound, length: 0))
            controller.window?.layoutIfNeeded()
            controller.window?.displayIfNeeded()
            CATransaction.flush() // the gutter has a layer: it draws here
        }
        XCTAssertEqual(gutter.drawCount, before, "30 keys inside a line redrew the gutter \(gutter.drawCount - before) times")
        textView.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.window?.layoutIfNeeded()
        controller.window?.displayIfNeeded()
        CATransaction.flush()
        XCTAssertGreaterThan(gutter.drawCount, before, "a new line redraws the gutter at once")
    }

    /// Opening and scrolling to the end widens the gutter for five-digit
    /// numbers by itself: scans made while drawing change the line count
    /// too, not only the idle ones.
    func testGutterWidensForMoreDigits() throws {
        let controller = try window(numbered(20_000))
        let textView = controller.textView
        textView.scrollRangeToVisible(NSRange(location: textView.textStorage?.length ?? 0, length: 0))
        for _ in 0..<5 { settle(controller) }
        XCTAssertEqual(controller.lineNumberView.visibleLabels().last?.number, 20_001)
        XCTAssertEqual(controller.lineNumberView.digits, 5)
        XCTAssertEqual(controller.lineNumberView.ruleThickness, controller.lineNumberView.thickness(forDigits: 5))
        let small = try window("x")
        XCTAssertLessThan(small.lineNumberView.ruleThickness, controller.lineNumberView.ruleThickness)
    }

    // MARK: Reload

    /// While a reload replaces the text (maybe on another thread), the
    /// line index neither scans on idle turns nor answers from the text;
    /// after it, it starts again and answers from the new text.
    func testReloadPausesTheIndexAndStartsItAgain() throws {
        let line = "a line of the reload test\n"
        let controller = try window(String(repeating: line, count: (LineIndex.syncGap * 3) / line.count))
        let index = controller.lineIndex
        let length = controller.textView.textStorage?.length ?? 0
        XCTAssertNil(index.line(containing: length - 1), "a long gap goes to idle turns")
        controller.beginReload()
        let before = index.scannedTo
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(index.scannedTo, before, "the index scanned while the text was being replaced")
        XCTAssertNil(index.line(containing: 0), "the index read the text during a reload")
        // The gutter and the map ask the index nothing that reads the text.
        let width = controller.lineNumberView.ruleThickness
        controller.lineNumberView.updateThickness()
        XCTAssertEqual(controller.lineNumberView.ruleThickness, width)
        XCTAssertTrue(controller.lineNumberView.visibleLabels().isEmpty)
        XCTAssertNil(controller.documentMap.currentGeometry())
        XCTAssertFalse(index.isComplete)
        controller.window?.displayIfNeeded()
        controller.endReload()
        XCTAssertEqual(index.line(containing: 0), 0)
        XCTAssertNil(index.line(containing: length - 1), "the far end goes to idle turns again")
        let deadline = Date().addingTimeInterval(20)
        while !index.isComplete, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(index.line(containing: length - 1), length / (line as NSString).length - 1)
    }

    // MARK: The map

    /// Dragging the box on a long text keeps its top under the pointer,
    /// although the map itself scrolls in proportion while the text moves.
    func testDraggingTheBoxKeepsItUnderThePointer() throws {
        let controller = try window(numbered(10_000))
        let map = controller.documentMap
        let windowNumber = controller.window?.windowNumber ?? 0
        func event(_ type: NSEvent.EventType, mapY: CGFloat) throws -> NSEvent {
            let point = map.convert(NSPoint(x: 50, y: mapY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        }
        let start = try XCTUnwrap(map.currentGeometry()).box(width: map.bounds.width)
        let grab: CGFloat = 4
        map.mouseDown(with: try event(.leftMouseDown, mapY: start.minY + grab))
        for step in 1...8 {
            let y = start.minY + grab + CGFloat(step) * 50
            map.mouseDragged(with: try event(.leftMouseDragged, mapY: y))
            settle(controller)
            let box = try XCTUnwrap(map.currentGeometry()).box(width: map.bounds.width)
            XCTAssertEqual(box.minY, y - grab, accuracy: 2, "step \(step): the box top left the pointer")
        }
        map.mouseUp(with: try event(.leftMouseUp, mapY: start.minY + grab + 400))
    }

    func testMapTopLineScrollsInProportion() {
        // Everything fits: the map does not scroll.
        XCTAssertEqual(DocumentMapView.mapTopLine(first: 0, last: 30, lineCount: 100, rows: 200), 0)
        // 1,000 lines in 200 rows, 31 on screen: top, middle and bottom.
        XCTAssertEqual(DocumentMapView.mapTopLine(first: 0, last: 30, lineCount: 1_000, rows: 200), 0)
        XCTAssertEqual(DocumentMapView.mapTopLine(first: 969, last: 999, lineCount: 1_000, rows: 200), 800, accuracy: 0.001)
        XCTAssertEqual(DocumentMapView.mapTopLine(first: 484, last: 514, lineCount: 1_000, rows: 200), 400, accuracy: 1)
    }

    func testMapBoxMarksTheLinesOnScreenAndClickScrolls() throws {
        let controller = try window(numbered(2_000))
        let map = controller.documentMap
        let top = try XCTUnwrap(map.currentGeometry())
        XCTAssertEqual(top.firstVisibleLine, 0)
        XCTAssertEqual(top.mapTopLine, 0)
        XCTAssertGreaterThan(top.lastVisibleLine, 5)
        let box = top.box(width: map.bounds.width)
        XCTAssertEqual(box.minY, 0)
        XCTAssertEqual(box.height, CGFloat(top.lastVisibleLine + 1) * DocumentMapView.rowHeight)

        map.scrollText(toLine: 1_000)
        settle(controller)
        let middle = try XCTUnwrap(map.currentGeometry())
        XCTAssertEqual(middle.firstVisibleLine, 1_000)
        XCTAssertGreaterThan(middle.mapTopLine, 0, "the map scrolls along with a long text")
        let middleBox = middle.box(width: map.bounds.width)
        XCTAssertTrue(map.bounds.intersects(middleBox), "the box stays in the map")

        // A click in the map outside the box moves the text so the box is
        // centered under the click.
        let clickY = 50 * DocumentMapView.rowHeight + 1 // below the box's height, so no clamp at line 0
        XCTAssertFalse(middleBox.minY...middleBox.maxY ~= clickY, "the click must miss the box")
        let point = map.convert(NSPoint(x: 50, y: clickY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                     timestamp: 0, windowNumber: controller.window?.windowNumber ?? 0,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        map.mouseDown(with: event)
        settle(controller)
        let after = try XCTUnwrap(map.currentGeometry()).box(width: map.bounds.width)
        XCTAssertEqual(after.midY, clickY, accuracy: 3, "the box is centered on the click")
        XCTAssertLessThan(try XCTUnwrap(map.currentGeometry()).firstVisibleLine, middle.firstVisibleLine)
    }

    func testMapBlocksComeFromTheString() throws {
        let controller = try window("ab  cd\n\tx\n")
        let map = controller.documentMap
        let geometry = try XCTUnwrap(map.currentGeometry())
        let rects = map.blockRects(geometry: geometry, string: "ab  cd\n\tx\n" as NSString)
        let w = DocumentMapView.columnWidth
        XCTAssertEqual(rects.count, 3)
        XCTAssertEqual(rects[0], CGRect(x: 2, y: 0, width: 2 * w, height: DocumentMapView.blockHeight))
        XCTAssertEqual(rects[1], CGRect(x: 2 + 4 * w, y: 0, width: 2 * w, height: DocumentMapView.blockHeight))
        let tab = CGFloat(Defaults.integer(.tabWidth))
        XCTAssertEqual(rects[2], CGRect(x: 2 + tab * w, y: DocumentMapView.rowHeight, width: w, height: DocumentMapView.blockHeight))
    }

    /// Edits redraw the map's rows at most every `editRedrawDelay`.
    func testMapRedrawsAfterAnEditWithADelay() throws {
        let controller = try window(numbered(10))
        let map = controller.documentMap
        map.displayIfNeeded()
        XCTAssertFalse(map.needsDisplay)
        let draws = map.drawCount
        map.textDidChange()
        map.textDidChange()
        XCTAssertFalse(map.needsDisplay, "not at once")
        controller.window?.displayIfNeeded()
        XCTAssertEqual(map.drawCount, draws, "an edit does not redraw the map at once")
        RunLoop.main.run(until: Date().addingTimeInterval(DocumentMapView.editRedrawDelay + 0.1))
        map.displayIfNeeded()
        XCTAssertEqual(map.drawCount, draws + 1, "one redraw for both edits, after the delay")
    }

    /// The text, the numbers and the map all show. Before the fix the
    /// gutter's and the map's backgrounds, filled over dirty rects that
    /// reach past their bounds (macOS 14+), covered the text entirely.
    func testTextNumbersAndMapAreAllVisible() throws {
        let controller = try window(numbered(60))
        let window = try XCTUnwrap(controller.window)
        window.appearance = NSAppearance(named: .aqua)
        let content = try XCTUnwrap(window.contentView)
        settle(controller)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / content.bounds.width
        /// Dark pixels (text on the white background) in `rect`, given in
        /// the content view's points from its top-left corner.
        func darkPixels(_ rect: NSRect, below limit: CGFloat = 1.5) -> Int {
            var count = 0
            for y in stride(from: Int(rect.minY * scale), to: Int(rect.maxY * scale), by: 1) {
                for x in stride(from: Int(rect.minX * scale), to: Int(rect.maxX * scale), by: 1) {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if color.redComponent + color.greenComponent + color.blueComponent < limit { count += 1 }
                }
            }
            return count
        }
        let gutter = controller.lineNumberView.ruleThickness
        let firstRows = NSRect(x: 0, y: 0, width: content.bounds.width, height: 60)
        XCTAssertGreaterThan(darkPixels(NSRect(x: gutter + 4, y: firstRows.minY, width: 80, height: firstRows.height)), 20,
                             "no text in the text area")
        XCTAssertGreaterThan(darkPixels(NSRect(x: 2, y: firstRows.minY, width: gutter - 4, height: firstRows.height)), 10,
                             "no numbers in the gutter")
        let mapX = content.bounds.width - DocumentMapView.width
        // The map's rows are drawn at 45%: grey, not black, on white.
        XCTAssertGreaterThan(darkPixels(NSRect(x: mapX + 2, y: 0, width: 30, height: 60), below: 2.7), 10, "no rows in the map")
    }

    /// The text view stays in the accessibility tree (UI tests and
    /// VoiceOver find it); the gutter is left out. Marking the ruler as no
    /// accessibility element made AppKit drop every child of the scroll
    /// view, the text view too.
    func testTextViewStaysInTheAccessibilityTree() throws {
        let controller = try window("text")
        XCTAssertTrue(controller.scrollView.rulersVisible)
        let children = try XCTUnwrap(controller.scrollView.accessibilityChildren()).map { $0 as AnyObject }
        XCTAssertTrue(children.contains { $0 === controller.textView }, "children: \(children)")
        XCTAssertFalse(children.contains { $0 === controller.lineNumberView })
        let content = try XCTUnwrap(controller.window?.contentView?.accessibilityChildren()).map { $0 as AnyObject }
        XCTAssertTrue(content.contains { $0 === controller.documentMap }, "the map is reachable")
    }

    /// Screenshot of a window with the gutter and the map, for root.
    func testRenderWindowWithGutterAndMap() throws {
        let controller = try window(numbered(60) + String(repeating: "\tindented code(); // comment\n", count: 40))
        let content = try XCTUnwrap(controller.window?.contentView)
        settle(controller)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: TestShots.folder, withIntermediateDirectories: true)
        try png.write(to: TestShots.folder.appendingPathComponent("gutter-and-map.png"))
    }
}
