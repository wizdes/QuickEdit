import AppKit
import XCTest
@testable import QuickEdit

/// 1.2.0 change 1: an untitled window whose text is empty or only
/// whitespace closes with no save sheet, on Close and on Quit, and its
/// autosaved copy goes, so it does not come back at the next launch. The
/// check reads at most the first `TextDocument.blankScanLimit` characters.
@MainActor
final class BlankUntitledCloseTests: XCTestCase {
    private var before: [NSDocument] = []
    /// What the last `canClose` call told this test, if anything yet.
    private var replies: [Bool] = []

    override func setUp() async throws {
        before = NSDocumentController.shared.documents
        replies = []
    }

    override func tearDown() async throws {
        for document in NSDocumentController.shared.documents where !before.contains(where: { $0 === document }) {
            for controller in document.windowControllers {
                if let window = controller.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
            document.updateChangeCount(.changeCleared)
            document.close()
        }
    }

    /// The `shouldClose` callback `canClose` sends.
    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        replies.append(shouldClose)
    }

    /// An untitled document with a window on screen, holding `text`, edited.
    private func editedUntitled(_ text: String) throws -> (TextDocument, NSWindow) {
        let document = try XCTUnwrap(try NSDocumentController.shared.openUntitledDocumentAndDisplay(false) as? TextDocument)
        document.makeWindowControllers()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        window.orderFront(nil)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        document.updateChangeCount(.changeDone)
        return (document, window)
    }

    private func askToClose(_ document: TextDocument) {
        document.canClose(withDelegate: self,
                          shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
        // AppKit may answer on a later turn; a sheet, if any, appears at once.
        for _ in 0..<10 where replies.isEmpty { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: Close

    func testEmptyOrWhitespaceUntitledClosesWithoutASheet() throws {
        for text in ["", " ", "\n\n\n", " \t\r\n  \u{00A0}\u{2028}"] {
            replies = []
            let (document, window) = try editedUntitled(text)
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertTrue(document.isBlankUntitled, "\(text.debugDescription) counts as blank")
            askToClose(document)
            XCTAssertNil(window.attachedSheet, "a save sheet for \(text.debugDescription)")
            XCTAssertEqual(replies, [true], "canClose must say yes at once for \(text.debugDescription)")
            XCTAssertFalse(document.isDocumentEdited, "the edit is forgotten, so nothing is kept")
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            document.close()
        }
    }

    func testUntitledWithTextStillAsks() throws {
        let (document, window) = try editedUntitled("  x  ")
        XCTAssertFalse(document.isBlankUntitled)
        askToClose(document)
        XCTAssertNotNil(window.attachedSheet, "text that is not only whitespace gets the save sheet")
        XCTAssertFalse(replies.contains(true))
    }

    /// Only the first 1 MB is read: a longer text is not checked and asks,
    /// so a huge paste never stalls the close.
    func testOverTheScanLimitAsks() throws {
        let (document, window) = try editedUntitled(String(repeating: " ", count: TextDocument.blankScanLimit + 1))
        XCTAssertFalse(document.isBlankUntitled)
        askToClose(document)
        XCTAssertNotNil(window.attachedSheet)
    }

    /// A file on disk is never "blank untitled", even when it is empty.
    func testNamedEmptyFileIsNotBlankUntitled() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-blank-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("empty.txt")
        try Data().write(to: url)
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        XCTAssertFalse(document.isBlankUntitled)
    }

    /// The autosaved copy of a blank untitled document is removed, so the
    /// window does not come back at the next launch.
    func testAutosavedCopyIsRemoved() throws {
        let (document, _) = try editedUntitled("   \n")
        let saved = expectation(description: "autosave")
        document.autosave(withImplicitCancellability: false) { error in
            XCTAssertNil(error)
            saved.fulfill()
        }
        wait(for: [saved], timeout: 10)
        let url = try XCTUnwrap(document.autosavedContentsFileURL, "the autosave wrote no copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        askToClose(document)
        XCTAssertEqual(replies, [true])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the autosaved copy is still at \(url.path)")
        XCTAssertNil(document.autosavedContentsFileURL)
    }

    // MARK: Relaunch

    /// AppKit restores an autosaved untitled document on a background
    /// thread and calls updateChangeCount there (crash report 2026-10-26
    /// 21:15, NSDocument initForURL:withContentsOfURL:ofType:error:). The
    /// override must not trap off the main thread.
    func testChangeCountFromABackgroundThreadDoesNotTrap() throws {
        nonisolated(unsafe) let document = TextDocument()
        let done = expectation(description: "background change count")
        DispatchQueue.global(qos: .userInitiated).async {
            // Through the Objective-C entry point, as AppKit calls it.
            let selector = #selector(NSDocument.updateChangeCount(_:))
            typealias Call = @convention(c) (AnyObject, Selector, UInt) -> Void
            let call = unsafeBitCast(document.method(for: selector), to: Call.self)
            call(document, selector, NSDocument.ChangeType.changeDone.rawValue)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(document.isDocumentEdited)
        document.updateChangeCount(.changeCleared)
    }

    // MARK: Quit

    /// Quit reviews the unsaved documents first: blank untitled ones are
    /// dropped (no question, no autosaved copy, window closed); others stay.
    func testQuitDropsBlankUntitledDocumentsOnly() throws {
        let (blank, blankWindow) = try editedUntitled(" \n ")
        let (kept, _) = try editedUntitled("keep me")
        TextDocument.discardBlankUntitledDocuments()
        XCTAssertFalse(blank.isDocumentEdited)
        XCTAssertFalse(blankWindow.isVisible, "the blank window closed")
        XCTAssertFalse(NSDocumentController.shared.documents.contains { $0 === blank })
        XCTAssertTrue(NSDocumentController.shared.documents.contains { $0 === kept })
        XCTAssertTrue(kept.isDocumentEdited)
    }

    /// A blank untitled window stays off the saved window list, so the
    /// next launch does not bring back an empty tab; real text puts it on
    /// the list, and emptying it again takes it off.
    func testBlankWindowStaysOffTheSavedWindowList() throws {
        let (blank, window) = try editedUntitled("  ")
        XCTAssertFalse(window.isRestorable, "the blank window would come back empty at the next launch")
        blank.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        blank.updateChangeCount(.changeDone)
        XCTAssertTrue(window.isRestorable, "a window with text must come back")
        blank.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
        blank.updateChangeCount(.changeDone)
        XCTAssertFalse(window.isRestorable)
        TextDocument.discardBlankUntitledDocuments(closing: false)
        XCTAssertFalse(window.isRestorable)
    }

    /// The review step of Quit forgets a blank window's edits and its
    /// autosaved copy but keeps the window, as the quit may be cancelled.
    func testQuitReviewKeepsTheBlankWindowOpen() throws {
        let (blank, blankWindow) = try editedUntitled("\t")
        TextDocument.discardBlankUntitledDocuments(closing: false)
        XCTAssertFalse(blank.isDocumentEdited)
        XCTAssertTrue(blankWindow.isVisible)
        XCTAssertNil(blank.autosavedContentsFileURL)
    }
}
