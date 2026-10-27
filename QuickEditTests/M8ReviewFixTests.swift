import AppKit
import XCTest
@testable import QuickEdit

/// Fixes for the M8 code review (docs/reviews/M8-code.md). Each test is
/// named after its row.
@MainActor
final class M8ReviewFixTests: XCTestCase {
    private var folder: URL!
    private var documents: [NSDocument] = []
    private var saved: SavedSettings!
    private var savedThreshold = 0

    override func setUp() async throws {
        saved = SavedSettings()
        savedThreshold = TextDocument.largeFileThreshold
        ScalingScrollView.animatesZoom = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-m8fix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ScalingScrollView.animatesZoom = true
        TextDocument.largeFileThreshold = savedThreshold
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        saved.restore()
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    private func open(_ text: String, name: String) throws -> (TextDocument, DocumentWindowController) {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        document.makeWindowControllers()
        documents.append(document)
        return (document, try XCTUnwrap(document.windowControllers.first as? DocumentWindowController))
    }

    private func lines(_ count: Int) -> String {
        (0..<count).map { String(format: "line %05d of the review fix test", $0) }.joined(separator: "\n") + "\n"
    }

    /// Runs the main run loop until `done` or `seconds` pass.
    private func runLoop(upTo seconds: Double, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func allLaidOut(_ controller: DocumentWindowController) -> Bool {
        controller.layoutManager.firstUnlaidCharacterIndex() >= (controller.layoutManager.textStorage?.length ?? 0)
    }

    // MARK: Row 1: idle layout stops

    func testRow1IdleLayoutTimerIsNilOnceLayoutIsDone() throws {
        let (document, controller) = try open(lines(2_000), name: "done.txt")
        document.togglePageBreaks(nil)
        XCTAssertNotNil(controller.idleLayoutTimer, "the switch scheduled no idle layout")
        runLoop(upTo: 10) { allLaidOut(controller) }
        XCTAssertTrue(allLaidOut(controller), "idle layout did not finish in 10 s")
        runLoop(upTo: 0.2)
        XCTAssertNil(controller.idleLayoutTimer, "idle layout still scheduled after every page is laid out")
    }

    /// A slice whose layout call lays out nothing stops; it does not run
    /// again on every run-loop turn.
    func testRow1NoProgressDoesNotReschedule() throws {
        let (document, controller) = try open(lines(2_000), name: "stuck.txt")
        var calls = 0
        controller.idleLayoutCallForTests = { _, _ in calls += 1 }
        document.togglePageBreaks(nil)
        runLoop(upTo: 0.5)
        XCTAssertFalse(allLaidOut(controller), "the forced case laid out everything; the test proves nothing")
        XCTAssertEqual(calls, 1, "the idle layout ran \(calls) layout calls with no progress")
        XCTAssertNil(controller.idleLayoutTimer, "idle layout rescheduled itself with no progress")
        // An edit starts it again (and real layout then finishes).
        controller.idleLayoutCallForTests = nil
        controller.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertNotNil(controller.idleLayoutTimer, "an edit did not start idle layout again")
        runLoop(upTo: 10) { allLaidOut(controller) }
        XCTAssertTrue(allLaidOut(controller))
    }

    // MARK: Row 2: large-file mode follows a reload and a revert

    private let checkKeys: [DefaultsKey] = [.checkSpellingWhileTyping, .checkGrammarWithSpelling,
                                            .correctSpellingAutomatically, .smartQuotes, .smartDashes,
                                            .dataDetectors, .textReplacement]

    private func turnEveryCheckOn() {
        for key in checkKeys { Defaults.store.set(true, forKey: key.rawValue) }
    }

    private func checks(_ view: NSTextView) -> [Bool] {
        [view.isContinuousSpellCheckingEnabled, view.isGrammarCheckingEnabled, view.isAutomaticSpellingCorrectionEnabled,
         view.isAutomaticQuoteSubstitutionEnabled, view.isAutomaticDashSubstitutionEnabled,
         view.isAutomaticDataDetectionEnabled, view.isAutomaticTextReplacementEnabled]
    }

    private let allOff = [false, false, false, false, false, false, false]
    /// Every setting on; data detection (6th) stays off: since 1.2.0 new
    /// windows always start with it off.
    private let allOn = [true, true, true, true, true, false, true]
    private let smallText = String(repeating: "small\n", count: 10)        // 60 bytes
    private let largeText = String(repeating: "large file line\n", count: 100) // 1,600 bytes

    private enum Change { case reload, revert }

    /// Writes `text` over the document's file and takes it in by `change`.
    private func replaceOnDisk(_ document: TextDocument, with text: String, by change: Change) throws {
        let url = try XCTUnwrap(document.fileURL)
        try Data(text.utf8).write(to: url)
        switch change {
        case .reload:
            document.reloadAfterOutsideChange()
            // A large file reloads in the background (M8 review row 19).
            runLoop(upTo: 5) { !document.isReloading }
        case .revert:
            try document.revert(toContentsOf: url, ofType: TextDocument.plainTextType)
        }
        XCTAssertEqual(document.textStorage.string, text, "\(change) did not take the new text")
    }

    private func smallBecomesLarge(by change: Change) throws {
        turnEveryCheckOn()
        TextDocument.largeFileThreshold = 1_000
        let (document, controller) = try open(smallText, name: "grows-\(change).txt")
        XCTAssertFalse(document.isLargeFile)
        XCTAssertEqual(checks(controller.textView), allOn)
        try replaceOnDisk(document, with: largeText, by: change)
        XCTAssertTrue(document.isLargeFile, "\(change) did not record the new size")
        XCTAssertEqual(checks(controller.textView), allOff, "\(change): checks still on for a large file")
        XCTAssertEqual(controller.window?.title,
                       "grows-\(change).txt \u{2014} " + DocumentWindowController.largeFileTitleNote)
        // Wrap to Page keeps them off.
        document.togglePageBreaks(nil)
        XCTAssertEqual(checks(controller.textView), allOff)
    }

    private func largeBecomesSmall(by change: Change) throws {
        turnEveryCheckOn()
        TextDocument.largeFileThreshold = 1_000
        let (document, controller) = try open(largeText, name: "shrinks-\(change).txt")
        XCTAssertTrue(document.isLargeFile)
        XCTAssertEqual(checks(controller.textView), allOff)
        try replaceOnDisk(document, with: smallText, by: change)
        XCTAssertFalse(document.isLargeFile, "\(change) did not record the new size")
        XCTAssertEqual(checks(controller.textView), allOn, "\(change): the window's settings did not come back")
        XCTAssertEqual(controller.window?.title, "shrinks-\(change).txt")
    }

    func testRow2ReloadSmallToLarge() throws { try smallBecomesLarge(by: .reload) }
    func testRow2ReloadLargeToSmall() throws { try largeBecomesSmall(by: .reload) }
    func testRow2RevertSmallToLarge() throws { try smallBecomesLarge(by: .revert) }
    func testRow2RevertLargeToSmall() throws { try largeBecomesSmall(by: .revert) }

    /// The window's own choice (spelling turned off from the Edit menu)
    /// comes back after a large spell, not the setting.
    func testRow2LargeAndBackRestoresTheWindowsOwnChoice() throws {
        turnEveryCheckOn()
        TextDocument.largeFileThreshold = 1_000
        let (document, controller) = try open(smallText, name: "own.txt")
        controller.textView.toggleContinuousSpellChecking(nil)
        XCTAssertFalse(controller.textView.isContinuousSpellCheckingEnabled)
        try replaceOnDisk(document, with: largeText, by: .reload)
        XCTAssertEqual(checks(controller.textView), allOff)
        try replaceOnDisk(document, with: smallText + "more\n", by: .revert)
        XCTAssertEqual(checks(controller.textView), [false, true, true, true, true, false, true])
    }

    // MARK: Row 5: PDF layout managers off the main thread

    func testRow5PDFLayoutManagersHaveBackgroundLayoutOff() throws {
        let text = NSAttributedString(string: lines(50), attributes: TextViewFactory.plainTextAttributes())
        let piece = PDFRenderer.Pagination.Piece(text, range: NSRange(location: 0, length: text.length), width: 300)
        XCTAssertFalse(piece.layoutManager.backgroundLayoutEnabled)
    }

    // MARK: Row 9: the idle timer stops on close and its state resets on a mode switch

    func testRow9ClosingTheWindowStopsTheIdleTimer() throws {
        let (document, controller) = try open(lines(2_000), name: "close.txt")
        document.togglePageBreaks(nil)
        XCTAssertNotNil(controller.idleLayoutTimer)
        document.close()
        documents.removeAll { $0 === document }
        XCTAssertNil(controller.idleLayoutTimer, "the idle timer outlived the window")
        // An edit after the close does not start it again.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "late edit\n")
        XCTAssertNil(controller.idleLayoutTimer, "an edit after close started the idle timer")
    }

    /// Edits made in Wrap to Window are not seen by the idle state, so the
    /// switch to Wrap to Page starts its glyph pass from the start again.
    func testRow9SwitchToWrapToPageResetsTheIdleState() throws {
        let text = lines(1_000)
        let (document, controller) = try open(text, name: "modes.txt")
        document.togglePageBreaks(nil)
        runLoop(upTo: 10) { allLaidOut(controller) }
        XCTAssertGreaterThan(controller.idleGlyphsDone, 0)
        document.togglePageBreaks(nil)
        XCTAssertNil(controller.idleLayoutTimer, "the idle timer kept running in Wrap to Window")
        controller.textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        document.togglePageBreaks(nil)
        XCTAssertEqual(controller.idleGlyphsDone, 0, "Wrap to Page kept a glyph mark from before the Wrap to Window edits")
        runLoop(upTo: 10) { allLaidOut(controller) }
        XCTAssertTrue(allLaidOut(controller))
    }
}
