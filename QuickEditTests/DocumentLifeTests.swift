import AppKit
import XCTest
@testable import QuickEdit

/// M2 document life at the unit level: the transient untitled window (n2),
/// revert and outside changes (n3), and window state restoration (n5).
@MainActor
final class DocumentLifeTests: XCTestCase {
    private var folder: URL!
    private let type = TextDocument.plainTextType
    private var controller: NSDocumentController { NSDocumentController.shared }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickEditLifeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        closeAllDocuments()
    }

    override func tearDown() async throws {
        closeAllDocuments()
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    /// The test host opens an untitled window at launch; every test starts
    /// with no documents so "the only document" means the test's own.
    private func closeAllDocuments() {
        for document in controller.documents { document.close() }
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// An untitled document shown in a window, marked transient the way a
    /// launch-time window is.
    private func transientUntitled() throws -> TextDocument {
        let document = try XCTUnwrap(try controller.openUntitledDocumentAndDisplay(true) as? TextDocument)
        document.isTransient = true
        return document
    }

    private func open(_ url: URL, display: Bool = true) -> XCTestExpectation {
        let done = expectation(description: "open \(url.lastPathComponent)")
        controller.openDocument(withContentsOf: url, display: display) { document, _, error in
            XCTAssertNil(error)
            XCTAssertNotNil(document)
            done.fulfill()
        }
        return done
    }

    private func window(of document: NSDocument?) -> NSWindow? { document?.windowControllers.first?.window }

    // MARK: n2: transient untitled window

    func testOpeningAFileReplacesTheTransientWindowInPlace() async throws {
        let transient = try transientUntitled()
        let oldWindow = try XCTUnwrap(window(of: transient))
        oldWindow.setFrameTopLeftPoint(NSPoint(x: 140, y: 700))
        transient.isTransient = true // moving the window clears it, as in TextEdit
        let oldFrame = oldWindow.frame
        let url = try file("replaces.txt", "file text\n")
        await fulfillment(of: [open(url)], timeout: 10)

        XCTAssertEqual(controller.documents.count, 1, "the transient document is closed")
        let opened = try XCTUnwrap(controller.document(for: url))
        XCTAssertFalse(controller.documents.contains(transient))
        let newWindow = try XCTUnwrap(window(of: opened))
        XCTAssertTrue(newWindow.isVisible)
        XCTAssertEqual(newWindow.frame, oldFrame, "the file's window takes the transient window's place")
        XCTAssertFalse(oldWindow.isVisible)
    }

    func testOpeningTwoFilesReplacesWithTheFirstAndCascadesTheSecond() async throws {
        let transient = try transientUntitled()
        let oldFrame = try XCTUnwrap(window(of: transient)).frame
        let first = try file("first.txt", "1\n"), second = try file("second.txt", "2\n")
        let a = open(first), b = open(second)
        await fulfillment(of: [a, b], timeout: 10)
        XCTAssertEqual(controller.documents.count, 2)
        let firstWindow = try XCTUnwrap(window(of: controller.document(for: first)))
        let secondWindow = try XCTUnwrap(window(of: controller.document(for: second)))
        XCTAssertEqual(firstWindow.frame, oldFrame, "the first file takes the transient window's place")
        XCTAssertTrue(secondWindow.isVisible)
        XCTAssertGreaterThan(secondWindow.frame.minX, firstWindow.frame.minX, "the second window cascades")
    }

    func testEditedUntitledWindowIsNotReplaced() async throws {
        let transient = try transientUntitled()
        transient.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "typed")
        transient.updateChangeCount(.changeDone)
        XCTAssertFalse(transient.isTransient, "an edit ends the transient state")
        let url = try file("beside.txt", "x\n")
        await fulfillment(of: [open(url)], timeout: 10)
        XCTAssertEqual(controller.documents.count, 2)
        XCTAssertTrue(controller.documents.contains(transient))
        transient.updateChangeCount(.changeCleared) // so close() does not ask
    }

    func testNewDocumentEndsTheTransientState() throws {
        let transient = try transientUntitled()
        _ = try controller.openUntitledDocumentAndDisplay(true)
        XCTAssertFalse(transient.isTransient, "a second document ends the first one's transient state")
    }

    func testUntitledWindowMadeWithoutLaunchEventIsNotTransient() throws {
        // No Apple event is being handled here, as with File > New.
        let document = try XCTUnwrap(try controller.openUntitledDocumentAndDisplay(true) as? TextDocument)
        XCTAssertFalse(document.isTransient)
    }

    // MARK: n3: revert and changes made by another app

    private func openShown(_ url: URL) async throws -> TextDocument {
        await fulfillment(of: [open(url)], timeout: 10)
        return try XCTUnwrap(controller.document(for: url) as? TextDocument)
    }

    /// Writes the file from a separate process, as another app would, with
    /// no file coordination.
    private func writeFromAnotherProcess(_ text: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' \"$1\" > \"$2\"", "sh", text, url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    /// Polls by suspending, so work queued on the main queue (where this
    /// test also runs) gets its turn. Spinning the run loop here would not
    /// run main-queue blocks.
    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    func testRevertKeepsTheWindowAndTextViewAndPutsCaretAtStart() async throws {
        let url = try file("revert.txt", "saved text\n")
        let document = try await openShown(url)
        let windowController = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        let textView = windowController.textView
        let window = try XCTUnwrap(windowController.window)
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        let undoManager = try XCTUnwrap(document.undoManager)
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        textView.insertText("EDIT ", replacementRange: textView.selectedRange())
        undoManager.endUndoGrouping()
        undoManager.groupsByEvent = true
        let edited = try await waitFor(2) { document.isDocumentEdited }
        XCTAssertTrue(edited)

        try document.revert(toContentsOf: url, ofType: type)

        XCTAssertEqual(document.textStorage.string, "saved text\n")
        XCTAssertEqual(Array(try PlainTextIO.encode(document.textStorage.string, as: document.format)),
                       Array(try Data(contentsOf: url)), "the text matches the file bytes")
        XCTAssertTrue(document.windowControllers.first === windowController, "same window controller")
        XCTAssertTrue(windowController.window === window, "same window")
        XCTAssertTrue(textView.textStorage === document.textStorage, "the text view still shows the storage")
        XCTAssertNil(textView.textLayoutManager, "still a TextKit 1 view")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0), "caret at the start")
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertFalse(undoManager.canUndo, "undo cannot reach edits made to the old text")
    }

    func testFileChangedByAnotherAppReloadsWhenNotEdited() async throws {
        let url = try file("outside.txt", "before\n")
        let document = try await openShown(url)
        try writeFromAnotherProcess("after\n", to: url)
        // macOS reports an uncoordinated change to the file presenter about
        // 3 s after the write (measured 3.15 s on 2026-10-23), so allow 6 s.
        let reloaded = try await waitFor(6) { document.textStorage.string == "after\n" }
        XCTAssertTrue(reloaded,
                      "the window still shows \(document.textStorage.string.debugDescription)")
        XCTAssertFalse(document.isDocumentEdited)
    }

    func testFileChangedByAnotherAppIsNotReloadedOverAnEdit() async throws {
        let url = try file("outside-edited.txt", "before\n")
        let document = try await openShown(url)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "mine ")
        document.updateChangeCount(.changeDone)
        try writeFromAnotherProcess("theirs\n", to: url)
        try await Task.sleep(for: .seconds(5)) // past the ~3 s notice delay
        XCTAssertEqual(document.textStorage.string, "mine before\n", "an edited document must not reload")
        XCTAssertTrue(document.isDocumentEdited)
        document.updateChangeCount(.changeCleared) // so close() does not ask
    }

    // MARK: n5: window state restoration

    private func archive(_ controller: NSWindowController) throws -> NSKeyedUnarchiver {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        controller.encodeRestorableState(with: archiver)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = true
        return unarchiver
    }

    private func bigText() -> String {
        (0..<20_000).map { "line \($0) of the restoration fixture\n" }.joined()
    }

    /// The first character on screen in `textView`.
    private func firstVisibleCharacter(_ textView: NSTextView) throws -> Int {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        var rect = textView.visibleRect
        rect.origin.y -= textView.textContainerOrigin.y
        rect.size.height = 1
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        return layoutManager.characterIndexForGlyph(at: glyphs.location)
    }

    func testSelectionAndScrollAreRestored() async throws {
        let text = bigText()
        let url = try file("restore.txt", text)
        let document = try await openShown(url)
        let first = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        let middle = (text as NSString).range(of: "line 10000 of")
        first.textView.setSelectedRange(middle)
        first.textView.scrollRangeToVisible(middle)
        let savedTop = try firstVisibleCharacter(first.textView)
        let state = try archive(first)

        // A fresh window on the same document, as after relaunch.
        let second = DocumentWindowController(document: document)
        XCTAssertEqual(second.textView.selectedRange(), NSRange(location: 0, length: 0))
        second.restoreState(with: state)
        XCTAssertEqual(second.textView.selectedRange(), middle, "the selection comes back")
        second.showWindow(nil)
        let scrolled = try await waitFor(2) { second.textView.visibleRect.minY > 1000 }
        XCTAssertTrue(scrolled, "the window scrolls back to the saved place: \(second.textView.visibleRect)")
        // The same first line on screen as when the state was saved (one line of slack).
        let lineLength = ("line 10000 of the restoration fixture\n" as NSString).length
        let restoredTop = try firstVisibleCharacter(second.textView)
        XCTAssertLessThanOrEqual(abs(restoredTop - savedTop), lineLength,
                                 "first visible character \(restoredTop), saved \(savedTop)")
        second.close()
    }

    func testRestoredSelectionPastTheEndIsClamped() async throws {
        let url = try file("shrunk.txt", "a long text that will shrink\n")
        let document = try await openShown(url)
        let first = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        first.textView.setSelectedRange(NSRange(location: 20, length: 5))
        let state = try archive(first)
        try Data("tiny".utf8).write(to: url)
        try document.revert(toContentsOf: url, ofType: type)
        let second = DocumentWindowController(document: document)
        second.restoreState(with: state)
        XCTAssertLessThanOrEqual(NSMaxRange(second.textView.selectedRange()), document.textStorage.length)
        second.close()
    }
}
