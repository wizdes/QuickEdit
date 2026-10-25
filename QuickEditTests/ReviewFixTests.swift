import AppKit
import Synchronization
import XCTest
@testable import QuickEdit

/// Regression tests for the M1 code review (docs/reviews/M1-code.md), one
/// section per accepted row.
@MainActor
final class ReviewFixTests: XCTestCase {
    private var folder: URL!
    private let type = TextDocument.plainTextType
    /// Documents with windows; closed (with their windows) in tearDown.
    private var documents: [NSDocument] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickEditReviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for document in documents { document.close() }
        documents = []
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// A document with a real window controller and text view.
    private func openWithWindow(_ url: URL) throws -> (TextDocument, DocumentWindowController) {
        let document = try TextDocument(contentsOf: url, ofType: type)
        document.makeWindowControllers()
        documents.append(document)
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        return (document, controller)
    }

    // MARK: Row 1: revert to shorter text

    func testRevertToShorterTextKeepsSelectionInsideAndTypingWorks() throws {
        let url = try file("revert.txt", "a long first version of the text\n")
        let (document, controller) = try openWithWindow(url)
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: document.textStorage.length, length: 0))

        try Data("ab".utf8).write(to: url)
        try document.revert(toContentsOf: url, ofType: type)

        XCTAssertEqual(document.textStorage.string, "ab")
        let selection = textView.selectedRange()
        // Typing with a selection past the end throws NSRangeException and
        // kills the test host, so stop here when the selection is outside.
        guard NSMaxRange(selection) <= document.textStorage.length else {
            XCTFail("selection \(selection) is past the end of \(document.textStorage.length) characters after revert")
            return
        }
        textView.insertText("Z", replacementRange: selection)
        XCTAssertTrue(document.textStorage.string.contains("Z"))
        XCTAssertEqual(document.textStorage.length, 3)
    }

    // MARK: Rows 2 and 4: the save path

    private func append(_ text: String, to document: TextDocument) {
        let storage = document.textStorage
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: text)
        document.updateChangeCount(.changeDone)
    }

    /// Starts a real NSDocument save and returns a waiter for its result.
    private func startSave(_ document: TextDocument, to url: URL,
                           _ op: NSDocument.SaveOperationType) -> XCTestExpectation {
        let done = expectation(description: "save \(op.rawValue)")
        document.save(to: url, ofType: type, for: op) { error in
            XCTAssertNil(error)
            done.fulfill()
        }
        return done
    }

    /// Row 2: the bytes come from the storage at the moment the write copies
    /// it (input is blocked then), not from a copy made when save was called.
    func testSaveCopiesTextWhenTheWriteRuns() async throws {
        let url = try file("copy-time.txt", "one\n")
        let document = try TextDocument(contentsOf: url, ofType: type)
        append("two\n", to: document)
        let saved = startSave(document, to: url, .saveOperation)
        // Same main-loop turn: NSDocument has not started the write yet.
        append("three\n", to: document)
        await fulfillment(of: [saved], timeout: 10)
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "one\ntwo\nthree\n")
    }

    /// Row 2: two saves back to back with an edit in between.
    func testTwoSavesBackToBackWithEditBetween() async throws {
        let url = try file("twice.txt", "one\n")
        let document = try TextDocument(contentsOf: url, ofType: type)
        append("two\n", to: document)
        let first = startSave(document, to: url, .autosaveInPlaceOperation)
        append("three\n", to: document)
        let second = startSave(document, to: url, .saveOperation)
        await fulfillment(of: [first, second], timeout: 10, enforceOrder: true)
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "one\ntwo\nthree\n")
        XCTAssertFalse(document.isDocumentEdited, "both edits are on disk after the second save")
    }

    /// Row 4: AppKit lets the user type again while the bytes are written.
    /// An edit made during the write lands, is not in the file, and keeps
    /// the document edited.
    func testEditDuringWriteLandsAndStaysUnsaved() async throws {
        let url = try file("unblock.txt", "one\n")
        let document = try TextDocument(contentsOf: url, ofType: type)
        append("two\n", to: document)
        let editLanded = DispatchSemaphore(value: 0)
        let sawEditDuringWrite = Mutex(false)
        // Touched only on the main thread, inside the block below.
        nonisolated(unsafe) let shared = document
        TextDocument.testHooks.withLock {
            $0.afterUnblock = {
                // The text is copied. Ask the main thread for an edit and wait
                // for it; if the main thread is still blocked, this times out.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let storage = shared.textStorage
                        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "three\n")
                        shared.updateChangeCount(.changeDone)
                    }
                    editLanded.signal()
                }
                let landed = editLanded.wait(timeout: .now() + 3) == .success
                sawEditDuringWrite.withLock { $0 = landed }
            }
        }
        defer { TextDocument.testHooks.withLock { $0.afterUnblock = nil } }
        let saved = startSave(document, to: url, .saveOperation)
        await fulfillment(of: [saved], timeout: 10)
        XCTAssertTrue(sawEditDuringWrite.withLock { $0 }, "the edit did not land while the write was running")
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "one\ntwo\n")
        XCTAssertEqual(document.textStorage.string, "one\ntwo\nthree\n")
        XCTAssertTrue(document.isDocumentEdited, "the edit made during the write is still unsaved")
    }
    // MARK: Row 3: the ".txt" checkbox only changes the allowed types

    func testExtensionCheckboxKeepsTypedNameAndMatchesTextEdit() throws {
        let document = TextDocument()
        let panel = NSSavePanel()
        XCTAssertTrue(document.prepareSavePanel(panel))
        let checkbox = try XCTUnwrap(panel.accessoryView?.subviews.compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "appendTxtExtension" })
        XCTAssertEqual(checkbox.state, .on, "AddExtensionToNewPlainTextFiles defaults to YES")
        XCTAssertEqual(panel.allowedContentTypes, [.plainText])
        XCTAssertTrue(panel.allowsOtherFileTypes)

        panel.nameFieldStringValue = "typed name"
        checkbox.performClick(nil) // off
        XCTAssertEqual(checkbox.state, .off)
        XCTAssertEqual(panel.nameFieldStringValue, "typed name", "unchecking must keep the typed name")
        XCTAssertEqual(panel.allowedContentTypes, [])
        XCTAssertFalse(panel.allowsOtherFileTypes, "TextEdit sets allowsOtherFileTypes to the checkbox state")

        checkbox.performClick(nil) // on again
        XCTAssertEqual(panel.nameFieldStringValue, "typed name")
        XCTAssertEqual(panel.allowedContentTypes, [.plainText])
        XCTAssertTrue(panel.allowsOtherFileTypes)
    }
    // MARK: Row 6: real text-view edits, and save as an undo boundary

    /// One keystroke as the event loop delivers it: the text view's change
    /// inside its own undo group. Inside a unit test the outer run loop never
    /// comes back to close automatic groups, so the tests turn them off and
    /// group by hand. NSDocument counts the change on the next run-loop turn.
    private func type(_ text: String, into textView: NSTextView, of document: NSDocument) {
        let undoManager = document.undoManager!
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        textView.insertText(text, replacementRange: textView.selectedRange())
        undoManager.endUndoGrouping()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    func testTypingInTextViewMarksDocumentEdited() throws {
        let url = try file("typed.txt", "abc")
        let (document, controller) = try openWithWindow(url)
        XCTAssertFalse(document.isDocumentEdited)
        let textView = controller.textView
        XCTAssertTrue(textView.undoManager === document.undoManager, "the text view must use the document's undo manager")
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        type("d", into: textView, of: document)
        XCTAssertEqual(document.textStorage.string, "abcd")
        XCTAssertTrue(document.isDocumentEdited, "a keystroke in the text view must mark the document edited")
        document.undoManager?.undo()
        XCTAssertEqual(document.textStorage.string, "abc")
        XCTAssertFalse(document.isDocumentEdited, "undoing back to the saved text clears the edited mark")
    }

    func testSaveIsAnUndoBoundaryForTyping() throws {
        let url = try file("boundary.txt", "")
        let (document, controller) = try openWithWindow(url)
        let textView = controller.textView
        type("a", into: textView, of: document)
        let saved = startSave(document, to: url, .saveOperation)
        wait(for: [saved], timeout: 10)
        type("b", into: textView, of: document)
        XCTAssertEqual(document.textStorage.string, "ab")
        document.undoManager?.undo()
        XCTAssertEqual(document.textStorage.string, "a", "one Undo after a save must stop at the saved text")
    }
    // MARK: Row 7: open through NSDocumentController (the background read)

    private func openThroughController(_ url: URL) async throws -> TextDocument {
        let result: (NSDocument?, Error?) = await withCheckedContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { document, _, error in
                continuation.resume(returning: (document, error))
            }
        }
        XCTAssertNil(result.1)
        return try XCTUnwrap(result.0 as? TextDocument)
    }

    func testOpenThroughDocumentControllerReadsOffMainThread() async throws {
        let url = try file("valid.txt", "valid text\n")
        let readOnMain = Mutex<[Bool]>([])
        TextDocument.testHooks.withLock { $0.onRead = { isMain in readOnMain.withLock { $0.append(isMain) } } }
        defer { TextDocument.testHooks.withLock { $0.onRead = nil } }
        let document = try await openThroughController(url)
        defer { document.close() }
        XCTAssertEqual(document.textStorage.string, "valid text\n")
        XCTAssertTrue(NSDocumentController.shared.documents.contains(document))
        XCTAssertEqual(readOnMain.withLock { $0 }, [false], "the file must be read once, off the main thread")
    }

    // MARK: Row 13: a .md file is a plain-text document

    func testMarkdownFileOpensAsPlainTextAndSaves() async throws {
        let url = try file("notes.md", "# title\n")
        let document = try await openThroughController(url)
        defer { document.close() }
        XCTAssertEqual(document.fileType, TextDocument.plainTextType)
        XCTAssertTrue(document.writableTypes(for: .saveOperation).contains(document.fileType ?? ""),
                      "Save must be able to write the document's own type")
        append("more\n", to: document)
        let saved = startSave(document, to: url, .saveOperation)
        await fulfillment(of: [saved], timeout: 10)
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "# title\nmore\n")
        XCTAssertEqual(url.pathExtension, "md")
    }
    // MARK: Row 8: window size and the autosave delay

    func testNewWindowShowsThirtyLinesAndNinetyColumns() throws {
        let document = TextDocument()
        document.makeWindowControllers()
        documents.append(document)
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        let font = TextViewFactory.plainFont()
        let scrollView = try XCTUnwrap(controller.textView.enclosingScrollView)
        let visible = scrollView.contentSize
        XCTAssertEqual(visible.height, 30 * TextViewFactory.lineHeight(of: font), accuracy: 0.5,
                       "the text area is HeightInChars (30) lines tall")
        XCTAssertEqual(visible.width, (90 * TextViewFactory.xAdvance(of: font)
                       + 2 * NSTextContainer().lineFragmentPadding).rounded(.up), accuracy: 0.5,
                       "the text area is WidthInChars (90) x-advances wide plus padding")
    }

    func testAutosavingDelayComesFromDefaults() throws {
        let shared = try XCTUnwrap(NSDocumentController.shared as? DocumentController)
        XCTAssertEqual(shared.autosavingDelay, 30, "registered AutosavingDelay is 30 s")
        UserDefaults.standard.set(7, forKey: DefaultsKey.autosavingDelay.rawValue)
        defer { UserDefaults.standard.removeObject(forKey: DefaultsKey.autosavingDelay.rawValue) }
        XCTAssertEqual(DocumentController().autosavingDelay, 7, "a new controller reads the AutosavingDelay default")
    }

    // MARK: Row 12: -QEOpenPath only from launch arguments

    func testOpenPathComesOnlyFromLaunchArguments() {
        XCTAssertEqual(AppDelegate.testOpenPath(in: ["QuickEdit", "-QEOpenPath", "/tmp/a.txt"]), "/tmp/a.txt")
        XCTAssertNil(AppDelegate.testOpenPath(in: ["QuickEdit", "-QEOpenPath"]), "a missing value is no path")
        XCTAssertNil(AppDelegate.testOpenPath(in: ["QuickEdit"]))
        // A value saved in the app's defaults (defaults write) must be ignored.
        UserDefaults.standard.set("/tmp/from-defaults.txt", forKey: "QEOpenPath")
        defer { UserDefaults.standard.removeObject(forKey: "QEOpenPath") }
        XCTAssertNil(AppDelegate().testOpenPath, "QEOpenPath must not be read from user defaults")
    }
    // MARK: Row 14: new windows cascade

    func testSecondWindowCascadesFromTheFirst() throws {
        var frames: [NSRect] = []
        for _ in 0..<2 {
            let document = TextDocument()
            document.makeWindowControllers()
            documents.append(document)
            document.showWindows()
            frames.append(try XCTUnwrap(document.windowControllers.first?.window).frame)
        }
        XCTAssertGreaterThan(frames[1].minX, frames[0].minX, "the second window moves right: \(frames)")
        XCTAssertLessThan(frames[1].maxY, frames[0].maxY, "the second window's top moves down: \(frames)")
        XCTAssertEqual(frames[1].size, frames[0].size)
    }
}
