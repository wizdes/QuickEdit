import AppKit
import Synchronization
import XCTest
@testable import QuickEdit

/// Fixes from the M2 code review (docs/reviews/M2-code.md), each test written
/// to fail before its fix.
@MainActor
final class M2ReviewFixTests: XCTestCase {
    private var folder: URL!
    private let type = TextDocument.plainTextType
    private var controller: NSDocumentController { NSDocumentController.shared }

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickEditM2Fix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        closeAllDocuments()
    }

    override func tearDown() async throws {
        TextDocument.testHooks.withLock { $0 = .init() }
        closeAllDocuments()
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    private func closeAllDocuments() {
        for document in controller.documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
    }

    private func file(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: Row 1: an edit made while a file loads keeps the untitled window

    func testTypingIntoTransientWindowDuringASlowOpenIsKept() async throws {
        let transient = try XCTUnwrap(try controller.openUntitledDocumentAndDisplay(true) as? TextDocument)
        transient.isTransient = true
        let url = try file("slow.txt", Array("slow file\n".utf8))

        // Hold the background read until the test has typed.
        let started = Atomic<Bool>(false)
        let gate = DispatchSemaphore(value: 0)
        TextDocument.testHooks.withLock {
            $0.onRead = { isMain in
                guard !isMain else { return }
                started.store(true, ordering: .sequentiallyConsistent)
                _ = gate.wait(timeout: .now() + 10)
            }
        }
        let done = expectation(description: "open")
        var opened: NSDocument?
        controller.openDocument(withContentsOf: url, display: true) { document, _, error in
            XCTAssertNil(error)
            opened = document
            done.fulfill()
        }
        let readStarted = try await waitFor(10) { started.load(ordering: .sequentiallyConsistent) }
        XCTAssertTrue(readStarted, "the read never started")

        // The user types into the untitled window while the file loads.
        let textView = try XCTUnwrap((transient.windowControllers.first as? DocumentWindowController)?.textView)
        textView.insertText("typed while loading", replacementRange: textView.selectedRange())
        transient.updateChangeCount(.changeDone)
        gate.signal()
        await fulfillment(of: [done], timeout: 10)

        XCTAssertTrue(controller.documents.contains(transient), "the edited untitled document was closed")
        XCTAssertEqual(transient.textStorage.string, "typed while loading")
        XCTAssertTrue(transient.windowControllers.first?.window?.isVisible ?? false)
        let openedWindow = try XCTUnwrap(opened?.windowControllers.first?.window)
        XCTAssertTrue(openedWindow.isVisible, "the file opens in its own window")
        XCTAssertEqual(controller.documents.count, 2)
    }

    // MARK: Row 4: the restored scroll puts the saved first line at the top

    private func openShown(_ url: URL) async throws -> TextDocument {
        let done = expectation(description: "open")
        controller.openDocument(withContentsOf: url, display: true) { _, _, error in
            XCTAssertNil(error)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 10)
        return try XCTUnwrap(controller.document(for: url) as? TextDocument)
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

    func testRestoredScrollPutsTheSavedLineAtTheTop() async throws {
        let line = "line %05d of the restoration fixture\n"
        let text = (0..<20_000).map { String(format: line, $0) }.joined()
        let lineLength = (String(format: line, 0) as NSString).length
        let url = try file("restore-top.txt", Array(text.utf8))
        let document = try await openShown(url)
        let first = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        // Scroll the first window so line 10000 is the top line.
        let saved = 10_000 * lineLength
        let layoutManager = try XCTUnwrap(first.textView.layoutManager)
        let glyph = layoutManager.glyphIndexForCharacter(at: saved)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        first.textView.scroll(NSPoint(x: 0, y: lineRect.minY + first.textView.textContainerOrigin.y))
        XCTAssertEqual(try firstVisibleCharacter(first.textView) / lineLength, 10_000, "test setup")

        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        first.encodeRestorableState(with: archiver)
        archiver.finishEncoding()
        let state = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        state.requiresSecureCoding = true

        let second = DocumentWindowController(document: document)
        second.showWindow(nil)
        second.restoreState(with: state)
        _ = try await waitFor(2) { second.textView.visibleRect.minY > 1000 }
        let top = try firstVisibleCharacter(second.textView)
        XCTAssertLessThanOrEqual(abs(top - saved), lineLength,
                                 "first visible character \(top) (line \(top / lineLength)), saved \(saved) (line 10000)")
        second.close()
    }

    // MARK: Row 10: .json, .html and extension-less files open as plain text

    private func openHidden(_ url: URL) async -> (NSDocument?, Error?) {
        await withCheckedContinuation { continuation in
            controller.openDocument(withContentsOf: url, display: false) { document, _, error in
                continuation.resume(returning: (document, error))
            }
        }
    }

    func testJSONHTMLAndExtensionlessFilesOpenAsPlainText() async throws {
        for (name, text) in [("data.json", "{\"a\": 1}\n"), ("page.html", "<p>hi</p>\n"), ("README", "no extension\n")] {
            let url = try file(name, Array(text.utf8))
            let (document, error) = await openHidden(url)
            XCTAssertNil(error, "\(name): \(String(describing: error))")
            let textDocument = try XCTUnwrap(document as? TextDocument, name)
            XCTAssertEqual(textDocument.textStorage.string, text, name)
        }
    }

    func testExtensionlessFileSavesAsPlainText() async throws {
        let url = try file("NOTES", Array("notes\n".utf8))
        let (opened, error) = await openHidden(url)
        XCTAssertNil(error)
        let document = try XCTUnwrap(opened as? TextDocument)
        document.textStorage.replaceCharacters(in: NSRange(location: 5, length: 0), with: " more")
        document.updateChangeCount(.changeDone)
        let out = folder.appendingPathComponent("NOTES-saved.txt")
        let saveError: Error? = await withCheckedContinuation { continuation in
            document.save(to: out, ofType: TextDocument.plainTextType, for: .saveAsOperation) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(saveError)
        XCTAssertEqual(try Data(contentsOf: out), Data("notes more\n".utf8))
    }

    // MARK: Row 3: outside changes compare the text, not the date

    /// Runs a shell command as another process (another app), no coordination.
    private func shell(_ command: String, _ args: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command, "sh"] + args
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, command)
    }

    private func openWithWindow(_ url: URL) throws -> (TextDocument, NSTextView, EncodingDocumentTests.FakePresenter) {
        let document = try TextDocument(contentsOf: url, ofType: type)
        document.makeWindowControllers()
        controller.addDocument(document)
        let presenter = EncodingDocumentTests.FakePresenter()
        document.alertPresenter = presenter
        let textView = try XCTUnwrap((document.windowControllers.first as? DocumentWindowController)?.textView)
        return (document, textView, presenter)
    }

    private func saveInPlace(_ document: TextDocument) async throws {
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: document.fileURL!, ofType: type, for: .saveOperation) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(error)
    }

    func testDateOnlyChangeDoesNotReloadAndKeepsUndo() async throws {
        let url = try file("touch.txt", Array("one\n".utf8))
        let (document, textView, _) = try openWithWindow(url)
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        document.undoManager?.groupsByEvent = false
        document.undoManager?.beginUndoGrouping()
        textView.insertText("two", replacementRange: textView.selectedRange())
        document.undoManager?.endUndoGrouping()
        try await saveInPlace(document)
        XCTAssertTrue(document.undoManager?.canUndo ?? false)
        textView.setSelectedRange(NSRange(location: 2, length: 3))
        try shell("touch -t 209901010000 \"$1\"", url.path) // a later date, same bytes
        document.reloadAfterOutsideChange()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(document.textStorage.string, "one\ntwo")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 3), "the caret must not jump")
        XCTAssertTrue(document.undoManager?.canUndo ?? false, "a date-only change must not reload and drop undo")
    }

    func testOlderDatedReplacementReloads() async throws {
        let url = try file("older.txt", Array("before\n".utf8))
        let (document, _, _) = try openWithWindow(url)
        try shell("printf 'replaced\\n' > \"$1\" && touch -t 200001010000 \"$1\"", url.path)
        document.reloadAfterOutsideChange()
        _ = try await waitFor(2) { document.textStorage.string == "replaced\n" }
        XCTAssertEqual(document.textStorage.string, "replaced\n", "different bytes with an older date must reload")
        XCTAssertFalse(document.isDocumentEdited)
    }

    func testAppendedTextReloadsAndKeepsTheCaret() async throws {
        let url = try file("log.txt", Array("line 1\nline 2\n".utf8))
        let (document, textView, _) = try openWithWindow(url)
        textView.setSelectedRange(NSRange(location: 7, length: 4))
        try shell("printf 'line 3\\n' >> \"$1\"", url.path)
        document.reloadAfterOutsideChange()
        _ = try await waitFor(2) { document.textStorage.string.hasSuffix("line 3\n") }
        XCTAssertEqual(document.textStorage.string, "line 1\nline 2\nline 3\n")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 7, length: 4), "the selection stays")
    }

    func testShrunkFileClampsTheSelection() async throws {
        let url = try file("shrink.txt", Array("a long line of text\n".utf8))
        let (document, textView, _) = try openWithWindow(url)
        textView.setSelectedRange(NSRange(location: 10, length: 5))
        try shell("printf 'short' > \"$1\"", url.path)
        document.reloadAfterOutsideChange()
        _ = try await waitFor(2) { document.textStorage.string == "short" }
        XCTAssertEqual(document.textStorage.string, "short")
        XCTAssertLessThanOrEqual(NSMaxRange(textView.selectedRange()), 5)
    }

    func testUndecodableReplacementShowsOneErrorOnly() async throws {
        let url = try file("strict.txt", Array("utf8 text\n".utf8))
        DocumentController.setOpenPanelEncoding(.utf8, for: [url]) // opened as UTF-8 explicitly
        let (document, _, presenter) = try openWithWindow(url)
        try shell("printf 'bad \\377\\n' > \"$1\"", url.path)
        document.reloadAfterOutsideChange()
        _ = try await waitFor(2) { presenter.reloadErrors.count == 1 }
        XCTAssertEqual(presenter.reloadErrors.count, 1)
        document.reloadAfterOutsideChange() // a second notice for the same change
        try shell("touch -t 209901010000 \"$1\"", url.path) // and a date-only change
        document.reloadAfterOutsideChange()
        // macOS also delivers its own notices about 3 s after each write.
        try await Task.sleep(for: .seconds(4.5))
        XCTAssertEqual(presenter.reloadErrors.count, 1, "the error is shown once")
        XCTAssertEqual(document.textStorage.string, "utf8 text\n", "the old text stays")
    }
}
