import AppKit
import QuartzCore
import XCTest
@testable import QuickEdit

/// 1.2.1, the user's three tweaks:
/// 1. The document map's box (the lines on screen) is hidden until the
///    mouse comes within `DocumentMapView.hoverMargin` points of the map,
///    stays while a drag in the map goes on, and the line between the text
///    and the map is gone.
/// 2. Line numbers are off by default; Settings has a checkbox for them
///    that agrees with View > Show Line Numbers.
/// 3. Writing Tools and inline predictive text are off by default, with a
///    Settings checkbox to turn them on; a file too large to edit keeps
///    them off.
@MainActor
final class HoverBoxAndOptionsTests: XCTestCase {
    private var saved: SavedSettings!
    private var documents: [NSDocument] = []
    private var folder: URL!
    private var savedLargeThreshold = 0
    private var savedReadOnlyThreshold = 0
    /// Where the tests put the pointer, in window coordinates (review fix
    /// 2): far away unless a test moves it, so the real mouse never
    /// changes a result.
    private var pointer = NSPoint(x: -10_000, y: -10_000)
    private var savedPointerSource: (@MainActor (NSWindow) -> NSPoint)!
    private var savedReducesMotion: (@MainActor () -> Bool)!

    override func setUp() async throws {
        saved = SavedSettings()
        savedPointerSource = DocumentMapView.pointerInWindow
        savedReducesMotion = DocumentMapView.reducesMotion
        DocumentMapView.pointerInWindow = { [unowned self] _ in self.pointer }
        DocumentMapView.reducesMotion = { false }
        savedLargeThreshold = TextDocument.largeFileThreshold
        savedReadOnlyThreshold = TextDocument.readOnlyThreshold
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-hover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        DocumentMapView.pointerInWindow = savedPointerSource
        DocumentMapView.reducesMotion = savedReducesMotion
        TextDocument.largeFileThreshold = savedLargeThreshold
        TextDocument.readOnlyThreshold = savedReadOnlyThreshold
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        try? FileManager.default.removeItem(at: folder)
        saved.restore()
    }

    /// A document window on screen holding `text` (read from a file when
    /// `fromFile`, so the large-file thresholds apply).
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

    private func enterExit(_ type: NSEvent.EventType, _ window: NSWindow?) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: window?.windowNumber ?? 0, context: nil,
                                             eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in map: DocumentMapView) throws -> NSEvent {
        let location = map.convert(point, to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                windowNumber: map.window?.windowNumber ?? 0, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// The map drawn into a bitmap, read by map points (top-left origin).
    private struct Picture {
        let rep: NSBitmapImageRep
        let scale: CGFloat
        func color(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
            rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB)
        }
    }

    private func picture(_ map: DocumentMapView) throws -> Picture {
        let rep = try XCTUnwrap(map.bitmapImageRepForCachingDisplay(in: map.bounds))
        map.cacheDisplay(in: map.bounds, to: rep)
        return Picture(rep: rep, scale: CGFloat(rep.pixelsWide) / map.bounds.width)
    }

    private func same(_ a: NSColor?, _ b: NSColor?, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard let a, let b else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02
    }

    // MARK: 1. The map's box shows on hover only; no separator

    func testHoverRectIsTheMapPlusAMarginOnTheLeft() {
        XCTAssertEqual(DocumentMapView.hoverMargin, 8)
        let rect = DocumentMapView.hoverRect(mapFrame: NSRect(x: 500, y: 0, width: 100, height: 300))
        XCTAssertEqual(rect, NSRect(x: 492, y: 0, width: 108, height: 300))
    }

    func testContainerTracksTheHoverRectForTheMap() throws {
        let controller = try window(numbered(60))
        let map = controller.documentMap
        let container = controller.container
        let areas = container.trackingAreas.filter { $0.owner === map }
        XCTAssertEqual(areas.count, 1, "one tracking area, owned by the map")
        let area = try XCTUnwrap(areas.first)
        XCTAssertEqual(area.rect, DocumentMapView.hoverRect(mapFrame: map.frame))
        XCTAssertTrue(area.options.contains(.mouseEnteredAndExited))

        // A hidden map tracks nothing; shown again, it tracks again.
        Defaults.store.set(false, forKey: Defaults.showDocumentMapKey)
        ViewOptionsCommand.updateWindows()
        XCTAssertTrue(container.trackingAreas.filter { $0.owner === map }.isEmpty)
        Defaults.store.set(true, forKey: Defaults.showDocumentMapKey)
        ViewOptionsCommand.updateWindows()
        XCTAssertEqual(container.trackingAreas.filter { $0.owner === map }.count, 1)
    }

    func testBoxIsHiddenAtRestAndFadesInAndOutOnHover() throws {
        let controller = try window(numbered(60))
        let map = controller.documentMap
        XCTAssertFalse(map.showsViewportBox)
        XCTAssertEqual(map.boxAlpha, 0, "no box at rest")

        map.mouseEntered(with: try enterExit(.mouseEntered, controller.window))
        XCTAssertTrue(map.showsViewportBox)
        map.stepFade(at: map.fadeStart + DocumentMapView.fadeInDuration / 2)
        XCTAssertEqual(map.boxAlpha, 0.5, accuracy: 0.05, "half way through the fade in")
        map.stepFade(at: map.fadeStart + DocumentMapView.fadeInDuration)
        XCTAssertEqual(map.boxAlpha, 1)
        XCTAssertFalse(map.isFading, "no display link runs once the fade is done")

        map.mouseExited(with: try enterExit(.mouseExited, controller.window))
        XCTAssertFalse(map.showsViewportBox)
        map.stepFade(at: map.fadeStart + DocumentMapView.fadeOutDuration / 2)
        XCTAssertEqual(map.boxAlpha, 0.5, accuracy: 0.05)
        map.stepFade(at: map.fadeStart + DocumentMapView.fadeOutDuration)
        XCTAssertEqual(map.boxAlpha, 0)
        XCTAssertFalse(map.isFading)
    }

    func testBoxStaysWhileDraggingAndFadesAfterMouseUpOutside() throws {
        let controller = try window(numbered(300))
        let map = controller.documentMap
        map.mouseEntered(with: try enterExit(.mouseEntered, controller.window))
        map.mouseDown(with: try mouse(.leftMouseDown, at: NSPoint(x: 50, y: 4), in: map))
        XCTAssertTrue(map.isDragging)
        // The drag leaves the hover area: the box stays.
        map.mouseExited(with: try enterExit(.mouseExited, controller.window))
        XCTAssertTrue(map.showsViewportBox, "the box stays while dragging")
        map.stepFade(at: map.fadeStart + 1)
        XCTAssertEqual(map.boxAlpha, 1)
        map.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: 50, y: 40), in: map))
        XCTAssertFalse(map.showsViewportBox, "mouse up outside the area hides it")
        map.stepFade(at: map.fadeStart + 1)
        XCTAssertEqual(map.boxAlpha, 0)
    }

    /// Review fix 2: the drag ends outside the area and no mouseExited
    /// arrives; mouse up reads where the pointer really is.
    func testMouseUpOutsideWithoutAnExitEventHidesTheBox() throws {
        let controller = try window(numbered(300))
        let map = controller.documentMap
        pointer = map.convert(NSPoint(x: 50, y: 4), to: nil)
        map.mouseEntered(with: try enterExit(.mouseEntered, controller.window))
        map.mouseDown(with: try mouse(.leftMouseDown, at: NSPoint(x: 50, y: 4), in: map))
        // The pointer leaves the area while the button is down; no exit event.
        pointer = controller.container.convert(NSPoint(x: 10, y: 10), to: nil)
        map.mouseUp(with: try mouse(.leftMouseUp, at: map.convert(pointer, from: nil), in: map))
        XCTAssertFalse(map.isMouseNear, "mouse up resamples the pointer")
        XCTAssertFalse(map.showsViewportBox, "the box goes after mouse up outside")
    }

    /// Mouse up with the pointer still near keeps the box.
    func testMouseUpInsideKeepsTheBox() throws {
        let controller = try window(numbered(300))
        let map = controller.documentMap
        pointer = map.convert(NSPoint(x: 50, y: 4), to: nil)
        map.mouseEntered(with: try enterExit(.mouseEntered, controller.window))
        map.mouseDown(with: try mouse(.leftMouseDown, at: NSPoint(x: 50, y: 4), in: map))
        map.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: 50, y: 4), in: map))
        XCTAssertTrue(map.showsViewportBox)
    }

    /// The tracking area is made again (a resize) with the pointer inside
    /// the margin left of the map: the map knows it is near without an
    /// entered event; moved away and resized again, it knows that too.
    func testReplacingTheTrackingAreaResamplesThePointer() throws {
        let controller = try window(numbered(60))
        let map = controller.documentMap
        let container = controller.container
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(map.isMouseNear)
        var frame = window.frame
        frame.size.width += 40
        let mapLeftAfter = container.bounds.width + 40 - DocumentMapView.width
        pointer = container.convert(NSPoint(x: mapLeftAfter - 4, y: 30), to: nil)
        window.setFrame(frame, display: true)
        XCTAssertTrue(map.isMouseNear, "4 px left of the map is near")
        let area = try XCTUnwrap(container.trackingAreas.first { $0.owner === map })
        XCTAssertTrue(area.options.contains(.enabledDuringMouseDrag), "exits arrive during a drag")

        pointer = container.convert(NSPoint(x: 10, y: 30), to: nil)
        frame.size.width -= 40
        window.setFrame(frame, display: true)
        XCTAssertFalse(map.isMouseNear)
    }

    func testHidingTheMapWhileHoveredResetsTheBox() throws {
        let controller = try window(numbered(60))
        let map = controller.documentMap
        map.mouseEntered(with: try enterExit(.mouseEntered, controller.window))
        map.stepFade(at: map.fadeStart + 1)
        XCTAssertEqual(map.boxAlpha, 1)
        Defaults.store.set(false, forKey: Defaults.showDocumentMapKey)
        ViewOptionsCommand.updateWindows()
        XCTAssertTrue(map.isHidden)
        XCTAssertFalse(map.isMouseNear)
        XCTAssertEqual(map.boxAlpha, 0, "a hidden map drops its box at once")
        XCTAssertFalse(map.isFading)
    }

    func testReduceMotionShowsAndHidesTheBoxWithoutAFade() throws {
        DocumentMapView.reducesMotion = { true }
        let controller = try window(numbered(60))
        let map = controller.documentMap
        map.mouseEntered(with: try enterExit(.mouseEntered, controller.window))
        XCTAssertEqual(map.boxAlpha, 1)
        XCTAssertFalse(map.isFading, "no display link with Reduce Motion")
        map.mouseExited(with: try enterExit(.mouseExited, controller.window))
        XCTAssertEqual(map.boxAlpha, 0)
        XCTAssertFalse(map.isFading)
    }

    // MARK: Review fix 1: no fade outlives its window

    func testRemovingTheMapMidFadeStopsTheLink() throws {
        let controller = try window(numbered(60))
        let map = controller.documentMap
        map.mouseEntered(with: try enterExit(.mouseEntered, controller.window))
        XCTAssertTrue(map.isFading)
        map.removeFromSuperview()
        XCTAssertFalse(map.isFading, "leaving the window stops the fade")
        XCTAssertFalse(map.isMouseNear)
    }

    func testClosingAWindowMidFadeStopsTheLinkAndFreesTheMap() throws {
        weak var weakMap: DocumentMapView?
        weak var weakController: DocumentWindowController?
        try autoreleasepool {
            let controller = try window(numbered(60))
            let map = controller.documentMap
            weakMap = map
            weakController = controller
            map.mouseEntered(with: try enterExit(.mouseEntered, controller.window))
            XCTAssertTrue(map.isFading)
            let window = try XCTUnwrap(controller.window)
            let document = try XCTUnwrap(documents.popLast())
            document.updateChangeCount(.changeCleared)
            document.close()
            XCTAssertFalse(map.isFading, "closing the window stops the fade")
            // AppKit can keep a closed window (and so its views) alive for
            // a while in a long test run (measured: the full unit run). Its
            // content goes, so only a display link could still hold the map.
            window.contentView = nil
        }
        // Let AppKit drop what it holds for the closed window.
        for _ in 0..<5 {
            autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        XCTAssertNil(weakMap, "the map is freed")
        XCTAssertNil(weakController, "the window controller (and its line index) is freed")
        // The text storage is not checked: it outlives a closed window in
        // the test host with no fade at all (measured 2026-10-27), so it is
        // not this leak.
    }

    func testClickWithoutHoverShowsTheBoxUntilMouseUp() throws {
        let controller = try window(numbered(300))
        let map = controller.documentMap
        map.mouseDown(with: try mouse(.leftMouseDown, at: NSPoint(x: 50, y: 100), in: map))
        XCTAssertTrue(map.showsViewportBox)
        map.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: 50, y: 100), in: map))
        XCTAssertFalse(map.showsViewportBox)
    }

    /// Drawn: at rest the box area and the map's left edge are plain
    /// background (no box, no separator line); hovered, the box shows.
    func testDrawingHasNoSeparatorAndTheBoxOnlyOnHover() throws {
        let controller = try window(String(repeating: "a\n", count: 10))
        let map = controller.documentMap
        settle(controller)
        let rest = try picture(map)
        let background = rest.color(90, map.bounds.height - 10)
        XCTAssertTrue(same(rest.color(0, map.bounds.height - 10), background), "no separator at the left edge")
        XCTAssertTrue(same(rest.color(0, 5), background), "no separator next to the text either")
        XCTAssertTrue(same(rest.color(50, 5), background), "no box at rest")

        map.mouseEntered(with: try enterExit(.mouseEntered, controller.window))
        map.stepFade(at: map.fadeStart + 1)
        let hovered = try picture(map)
        XCTAssertFalse(same(hovered.color(50, 5), background), "the box shows on hover")
        XCTAssertTrue(same(hovered.color(50, map.bounds.height - 10), background), "only inside the box")
        map.mouseExited(with: try enterExit(.mouseExited, controller.window))
        map.stepFade(at: map.fadeStart + 1)
    }

    // MARK: 2. Line numbers: off by default, Settings checkbox

    func testLineNumbersAreOffByDefault() throws {
        XCTAssertEqual(Defaults.registeredValues()[Defaults.showLineNumbersKey] as? Bool, false)
        let controller = try window(numbered(60))
        XCTAssertFalse(gutterShows(controller))
        XCTAssertFalse(controller.documentMap.isHidden, "the map stays on by default")
    }

    func testSettingsLineNumbersCheckboxAgreesWithTheViewMenu() throws {
        let controller = try window(numbered(60))
        let settings = SettingsWindowController()
        let window = settings.loadSettingsWindowIfNeeded()
        defer { window.close() }
        let box = try XCTUnwrap(settings.viewCheckboxes[Defaults.showLineNumbersKey])
        XCTAssertEqual(box.title, "Show line numbers")
        XCTAssertEqual(box.state, .off)
        let newDocument = try XCTUnwrap(settings.tabView?.tabViewItem(at: 0).view)
        XCTAssertTrue(box.isDescendant(of: newDocument))

        let bar = MainMenu.build()
        let item = try XCTUnwrap(bar.item(withTitle: "View")?.submenu?.item(withTitle: "Show Line Numbers"))
        XCTAssertTrue(ViewOptionsCommand.shared.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)

        box.performClick(nil)
        XCTAssertEqual(Defaults.store.object(forKey: Defaults.showLineNumbersKey) as? Bool, true)
        XCTAssertTrue(gutterShows(controller), "an open window follows at once")
        XCTAssertTrue(ViewOptionsCommand.shared.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)

        // The menu flips it back; the checkbox follows.
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(gutterShows(controller))
        XCTAssertEqual(box.state, .off, "the checkbox follows the menu")

        box.performClick(nil)
        XCTAssertTrue(gutterShows(controller))
        settings.restoreAllDefaults(nil)
        XCTAssertFalse(gutterShows(controller), "Restore All Defaults hides them again")
        XCTAssertEqual(box.state, .off)
    }

    // MARK: 3. Writing Tools and predictive text

    func testWritingToolsAndPredictionAreOffByDefault() throws {
        XCTAssertEqual(Defaults.registeredValues()[Defaults.showWritingToolsKey] as? Bool, false)
        let controller = try window("text")
        XCTAssertEqual(controller.textView.writingToolsBehavior, .none)
        XCTAssertEqual(controller.textView.inlinePredictionType, .no)
    }

    func testSettingsWritingToolsCheckboxTurnsThemOnInOpenWindows() throws {
        let controller = try window("text")
        let settings = SettingsWindowController()
        let window = settings.loadSettingsWindowIfNeeded()
        defer { window.close() }
        let box = try XCTUnwrap(settings.viewCheckboxes[Defaults.showWritingToolsKey])
        XCTAssertEqual(box.title, "Show Writing Tools and predictive text")
        XCTAssertEqual(box.state, .off)
        XCTAssertLessThanOrEqual(box.fittingSize.width, box.frame.width, "the title is not clipped")

        box.performClick(nil)
        XCTAssertEqual(Defaults.store.object(forKey: Defaults.showWritingToolsKey) as? Bool, true)
        XCTAssertEqual(controller.textView.writingToolsBehavior, .default)
        XCTAssertEqual(controller.textView.allowedWritingToolsResultOptions, [.plainText])
        XCTAssertEqual(controller.textView.inlinePredictionType, .default)
        let later = try self.window("later")
        XCTAssertEqual(later.textView.writingToolsBehavior, .default, "new windows read it too")

        settings.restoreAllDefaults(nil)
        XCTAssertEqual(controller.textView.writingToolsBehavior, .none)
        XCTAssertEqual(controller.textView.inlinePredictionType, .no)
        XCTAssertEqual(box.state, .off)
    }

    func testAFileTooLargeToEditKeepsWritingToolsOffWhateverTheSetting() throws {
        Defaults.store.set(true, forKey: Defaults.showWritingToolsKey)
        TextDocument.largeFileThreshold = 10
        TextDocument.readOnlyThreshold = 20
        let large = try window(String(repeating: "a long line\n", count: 4), fromFile: true)
        XCTAssertTrue(try XCTUnwrap(large.document as? TextDocument).isTooLargeToEdit)
        XCTAssertEqual(large.textView.writingToolsBehavior, .none)
        XCTAssertEqual(large.textView.inlinePredictionType, .no)
        for window in NSApp.windows {
            (window.windowController as? DocumentWindowController)?.applyWritingTools()
        }
        XCTAssertEqual(large.textView.writingToolsBehavior, .none, "a settings change does not turn them on")
    }

    /// Review fix 3: with the setting ON, a file too large to edit keeps
    /// Writing Tools and predictive text off on every view (page views in
    /// Wrap to Page too) through setting changes; a revert to a small file
    /// makes them follow the setting again.
    func testTooLargeBeatsTheSettingOnAndARevertToSmallFollowsItAgain() throws {
        Defaults.store.set(true, forKey: Defaults.showWritingToolsKey)
        TextDocument.largeFileThreshold = 10
        TextDocument.readOnlyThreshold = 20
        let controller = try window(String(repeating: "a long line\n", count: 4), fromFile: true)
        let document = try XCTUnwrap(controller.document as? TextDocument)
        XCTAssertTrue(document.isTooLargeToEdit)
        func assertOff(_ message: String, line: UInt = #line) {
            XCTAssertFalse(controller.textViews.isEmpty)
            for view in controller.textViews {
                XCTAssertEqual(view.writingToolsBehavior, .none, message, line: line)
                XCTAssertEqual(view.inlinePredictionType, .no, message, line: line)
            }
        }
        assertOff("too large, setting on")
        document.hasMultiplePages = true
        settle(controller)
        XCTAssertGreaterThanOrEqual(controller.textViews.count, 1)
        assertOff("Wrap to Page page views")
        for value in [false, true] {
            Defaults.store.set(value, forKey: Defaults.showWritingToolsKey)
            ViewOptionsCommand.updateWritingTools()
            assertOff("setting \(value) while too large")
        }
        document.hasMultiplePages = false
        settle(controller)

        // The file shrinks under the limit: a revert reads it again.
        let url = try XCTUnwrap(document.fileURL)
        try Data("short\n".utf8).write(to: url)
        try document.revert(toContentsOf: url, ofType: TextDocument.plainTextType)
        XCTAssertFalse(document.isTooLargeToEdit)
        XCTAssertEqual(controller.textView.writingToolsBehavior, .default, "follows the setting again")
        XCTAssertEqual(controller.textView.inlinePredictionType, .default)
        Defaults.store.set(false, forKey: Defaults.showWritingToolsKey)
        ViewOptionsCommand.updateWritingTools()
        XCTAssertEqual(controller.textView.writingToolsBehavior, .none)
        XCTAssertEqual(controller.textView.inlinePredictionType, .no)
    }

    // MARK: Layout

    func testSettingsNewDocumentTabStaysTidy() throws {
        let settings = SettingsWindowController()
        let window = settings.loadSettingsWindowIfNeeded()
        defer { window.close() }
        let tab = try XCTUnwrap(settings.tabView?.tabViewItem(at: 0).view)
        let controls = tab.subviews
        for (i, a) in controls.enumerated() {
            XCTAssertTrue(tab.bounds.contains(a.frame), "\(a) sticks out of its tab")
            for b in controls[(i + 1)...] {
                XCTAssertFalse(a.frame.intersects(b.frame), "\(a) overlaps \(b)")
            }
        }
    }
}
