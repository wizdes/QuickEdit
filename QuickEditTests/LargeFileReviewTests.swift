import AppKit
import os
import XCTest
@testable import QuickEdit

/// Fixes for the very-large-file review (docs/reviews/M8-code.md rows 14
/// to 25). Each test is named after its row. Small files with small
/// limits; the 1 GB reload is in LargeFileSpeedTests.
@MainActor
final class LargeFileReviewTests: XCTestCase {
    private var folder: URL!
    private var documents: [NSDocument] = []
    private var saved: SavedSettings!
    private var savedLargeThreshold = 0
    private var savedReadOnlyThreshold = 0

    override func setUp() async throws {
        saved = SavedSettings()
        savedLargeThreshold = TextDocument.largeFileThreshold
        savedReadOnlyThreshold = TextDocument.readOnlyThreshold
        ScalingScrollView.animatesZoom = false
        TextDocument.largeFileThreshold = 10
        TextDocument.readOnlyThreshold = 20
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-largereview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ScalingScrollView.animatesZoom = true
        TextDocument.largeFileThreshold = savedLargeThreshold
        TextDocument.readOnlyThreshold = savedReadOnlyThreshold
        LargeFileOriginal.failCloneForTests = false
        TextDocument.testHooks.withLock { $0.fallbackEncoding = nil }
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        saved.restore()
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    private let lines = Array("first line\nsecond line\nthird line\n".utf8)

    private func write(_ bytes: [UInt8], name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func open(_ url: URL) throws -> (TextDocument, DocumentWindowController) {
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        document.makeWindowControllers()
        documents.append(document)
        return (document, try XCTUnwrap(document.windowControllers.first as? DocumentWindowController))
    }

    private func save(_ document: TextDocument, to url: URL, _ op: NSDocument.SaveOperationType) async -> Error? {
        await withCheckedContinuation { continuation in
            document.save(to: url, ofType: TextDocument.plainTextType, for: op) { continuation.resume(returning: $0) }
        }
    }

    private func runLoop(upTo seconds: Double, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func reload(_ document: TextDocument) {
        document.reloadAfterOutsideChange()
        runLoop(upTo: 10) { !document.isReloading }
        XCTAssertFalse(document.isReloading, "the reload did not end in 10 s")
    }

    private func clonePath(_ document: TextDocument) -> URL? {
        document.keptOriginal?.file
    }

    // MARK: Row 14: a clone, not the mapping

    /// After open, another app overwrites the file in place, then cuts it
    /// short. Save As still writes the bytes as opened, and the process
    /// does not take the file's size in memory for it.
    func testRow14SaveAsKeepsTheOpenedBytesAfterTheFileIsOverwrittenAndCut() async throws {
        let megabytes = 32
        let url = folder.appendingPathComponent("big.txt")
        try LargeFileFixtures.write(to: url, bytes: megabytes * 1024 * 1024)
        let opened = try Data(contentsOf: url)
        let (document, _) = try open(url)
        XCTAssertTrue(document.isTooLargeToEdit)
        XCTAssertNotNil(clonePath(document), "no clone was taken on this volume")

        // Overwrite every byte in place (same file, same size).
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(repeating: 0x7A, count: opened.count))
        try handle.close()
        let sampler = PeakSampler()
        let out = folder.appendingPathComponent("copy.txt")
        let error = await save(document, to: out, .saveToOperation)
        let grew = sampler.stop()
        XCTAssertNil(error)
        XCTAssertTrue(try Data(contentsOf: out) == opened, "Save To after an overwrite did not write the bytes as opened")
        XCTAssertLessThan(grew, Double(megabytes) / 2, "Save To took +\(Int(grew)) MB for a \(megabytes) MB file")

        // Cut it short (truncate in place).
        let cut = try FileHandle(forWritingTo: url)
        try cut.truncate(atOffset: 10)
        try cut.close()
        let out2 = folder.appendingPathComponent("copy2.txt")
        let error2 = await save(document, to: out2, .saveAsOperation)
        XCTAssertNil(error2)
        XCTAssertTrue(try Data(contentsOf: out2) == opened, "Save As after a cut did not write the bytes as opened")
        XCTAssertFalse(document.isReloading)
    }

    /// The clone sits in its own folder, which goes when the document closes.
    func testRow14CloneFolderGoesWithTheDocument() throws {
        let (document, _) = try open(try write(lines, name: "big.txt"))
        let clone = try XCTUnwrap(clonePath(document))
        XCTAssertEqual(Array(try Data(contentsOf: clone)), lines)
        let cloneFolder = clone.deletingLastPathComponent()
        XCTAssertTrue(cloneFolder.path.hasPrefix(LargeFileOriginal.root.path))
        XCTAssertTrue(cloneFolder.lastPathComponent.hasPrefix("\(getpid())-"), cloneFolder.lastPathComponent)
        document.close()
        documents.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloneFolder.path), "the clone folder stayed after close")
    }

    /// A file below the large-file limit keeps no clone; an editable
    /// large file keeps one, for the reload check (review row 33).
    func testRow14NoCloneBelowTheLimit() throws {
        TextDocument.largeFileThreshold = 1_000
        TextDocument.readOnlyThreshold = 2_000
        let (document, _) = try open(try write(lines, name: "small.txt"))
        XCTAssertNil(document.keptOriginal)
        TextDocument.largeFileThreshold = 10
        let (large, _) = try open(try write(lines, name: "large.txt"))
        XCTAssertFalse(large.isTooLargeToEdit)
        XCTAssertNotNil(large.keptOriginal)
    }

    /// At launch, folders of QuickEdit processes that are gone are removed;
    /// those of running ones (this test host) stay.
    func testRow14StaleCloneFoldersAreRemovedAtLaunch() throws {
        let root = folder.appendingPathComponent("originals")
        var dead: Int32 = 99_999
        while dead > 1000, !(kill(dead, 0) == -1 && errno == ESRCH) { dead -= 1 }
        let gone = root.appendingPathComponent("\(dead)-\(UUID().uuidString)")
        let start = try XCTUnwrap(LargeFileOriginal.startTime(of: getpid()))
        let alive = root.appendingPathComponent("\(getpid())-\(start)-\(UUID().uuidString)")
        for dir in [gone, alive] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("clone.txt"))
        }
        let removed = LargeFileOriginal.removeStaleFolders(in: root)
        XCTAssertEqual(removed.map(\.lastPathComponent), [gone.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alive.path))
    }

    // (A volume that cannot clone: LargeFileReloadTests, row 29. The
    // "Save As while the file is unchanged" path is gone.)

    // MARK: Row 15: a failed read changes nothing

    func testRow15FailedRevertKeepsSizeModeAndBytes() async throws {
        let url = try write(lines, name: "big.txt")
        let (document, controller) = try open(url)
        // Bytes the xattr's UTF-8 does not fit: the read throws.
        try Data(repeating: 0xFF, count: 200).write(to: url)
        try PlainTextIO.writeAttribute(for: .utf8, to: url)
        XCTAssertThrowsError(try document.revert(toContentsOf: url, ofType: TextDocument.plainTextType))
        XCTAssertEqual(document.readByteCount, lines.count)
        XCTAssertTrue(document.isTooLargeToEdit)
        XCTAssertFalse(controller.textView.isEditable)
        let out = folder.appendingPathComponent("copy.txt")
        let error = await save(document, to: out, .saveToOperation)
        XCTAssertNil(error)
        XCTAssertEqual(Array(try Data(contentsOf: out)), lines, "Save As wrote the rejected file's bytes")
    }

    func testRow15FailedRevertOfASmallFileStaysEditable() throws {
        TextDocument.readOnlyThreshold = 100
        let url = try write(Array("short\n".utf8), name: "small.txt")
        let (document, controller) = try open(url)
        try Data(repeating: 0xFF, count: 500).write(to: url)
        try PlainTextIO.writeAttribute(for: .utf8, to: url)
        XCTAssertThrowsError(try document.revert(toContentsOf: url, ofType: TextDocument.plainTextType))
        XCTAssertEqual(document.readByteCount, 6)
        XCTAssertFalse(document.isTooLargeToEdit)
        XCTAssertTrue(controller.textView.isEditable)
    }

    // MARK: Row 16: read from bytes

    func testRow16ReadFromDataFollowsTheLimit() async throws {
        let document = TextDocument()
        documents.append(document)
        try document.read(from: Data(lines), ofType: TextDocument.plainTextType)
        XCTAssertEqual(document.readByteCount, lines.count)
        XCTAssertTrue(document.isTooLargeToEdit)
        let out = folder.appendingPathComponent("from-data.txt")
        let error = await save(document, to: out, .saveToOperation)
        XCTAssertNil(error)
        XCTAssertEqual(Array(try Data(contentsOf: out)), lines)
    }

    // MARK: Rows 17 and 18: lossy bytes, and the copy opens again

    /// Bytes no encoding holds (the fallback is set to Windows Latin 1,
    /// which cannot hold 0x81: ASCII holds every byte since M6 review
    /// row 3). Only the original-bytes path writes them back; the copy has
    /// no UTF-8 tag and opens again as the original does.
    func testRow17And18LossyFileSaveAsKeepsBytesAndTheCopyOpens() async throws {
        TextDocument.testHooks.withLock { $0.fallbackEncoding = .windowsCP1252 }
        let bytes = EncodingFixtures.invalidEverywhere + Array(repeating: UInt8(0x61), count: 30)
        let url = try write(bytes, name: "lossy.txt")
        let (document, _) = try open(url)
        XCTAssertTrue(document.loadedLossily)
        XCTAssertTrue(document.isTooLargeToEdit)
        // The text re-encoded would not give these bytes back.
        XCTAssertNotEqual(try PlainTextIO.encode(document.textStorage.string, as: document.format), Data(bytes))
        for operation in [NSDocument.SaveOperationType.saveToOperation, .saveAsOperation] {
            let out = folder.appendingPathComponent("copy-\(operation.rawValue).txt")
            let error = await save(document, to: out, operation)
            XCTAssertNil(error)
            XCTAssertEqual(Array(try Data(contentsOf: out)), bytes, "operation \(operation.rawValue)")
            XCTAssertNil(PlainTextIO.readAttribute(of: out), "the copy got an encoding tag")
            let copy = try TextDocument(contentsOf: out, ofType: TextDocument.plainTextType)
            documents.append(copy)
            XCTAssertEqual(copy.textStorage.string, document.textStorage.string)
        }
    }

    // MARK: Row 19: reload of a large file

    final class ReloadErrors: DocumentAlertPresenter {
        var count = 0
        func askToChooseAnotherEncoding(_ document: TextDocument, encodingName: String, completion: @escaping (Bool) -> Void) { completion(false) }
        func runSavePanel(_ document: TextDocument, completion: @escaping (Bool) -> Void) { completion(false) }
        func askBeforeOverwritingLossyFile(_ document: TextDocument, completion: @escaping (LossyOverwriteChoice) -> Void) { completion(.cancel) }
        func presentReloadError(_ document: TextDocument, error: Error) { count += 1 }
    }

    func testRow19LargeReloadRunsInTheBackgroundAndTakesTheNewText() throws {
        let url = try write(lines, name: "big.txt")
        let (document, controller) = try open(url)
        controller.textView.setSelectedRange(NSRange(location: 30, length: 3))
        let newText = "a new first line\nand a second, longer than before\n"
        try Data(newText.utf8).write(to: url)
        // The fill waits until the test has looked at the detached window.
        let hold = DispatchSemaphore(value: 0)
        TextDocument.testHooks.withLock { $0.beforeReloadFill = { hold.wait() } }
        defer { TextDocument.testHooks.withLock { $0.beforeReloadFill = nil } }
        document.reloadAfterOutsideChange()
        XCTAssertTrue(document.isReloading)
        XCTAssertEqual(Array(document.textStorage.string.utf8), lines, "the large reload ran on the main thread")
        // While the text is away the window takes no input and draws.
        runLoop(upTo: 5) { !controller.textView.isSelectable }
        XCTAssertTrue(document.isReloading)
        XCTAssertFalse(controller.textView.isEditable)
        XCTAssertFalse(controller.textView.isSelectable)
        let content = try XCTUnwrap(controller.window?.contentView)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        hold.signal()
        runLoop(upTo: 10) { !document.isReloading }
        XCTAssertEqual(document.textStorage.string, newText)
        XCTAssertEqual(document.readByteCount, newText.utf8.count)
        XCTAssertFalse(controller.textView.isEditable, "still too large: read-only")
        XCTAssertTrue(controller.textView.isSelectable)
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 30, length: 3))
        XCTAssertTrue(controller.textView.layoutManager?.textStorage === document.textStorage)
        XCTAssertFalse(document.isDocumentEdited)
        // The clone now holds the new bytes.
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(clonePath(document))), Data(newText.utf8))
        content.cacheDisplay(in: content.bounds, to: rep)
    }

    /// Same bytes (only the date changed): the text is not replaced.
    func testRow19UnchangedBytesKeepTheText() throws {
        let url = try write(lines, name: "big.txt")
        let (document, _) = try open(url)
        var edits = 0
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                              object: document.textStorage, queue: nil) { _ in edits += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        try Data(lines).write(to: url)
        reload(document)
        XCTAssertEqual(edits, 0, "the same bytes replaced the text")
        XCTAssertEqual(Array(document.textStorage.string.utf8), lines)
    }

    // (The change-during-a-reload test holds the first reload now:
    // LargeFileReloadTests.testRow36ChangeDuringAHeldReloadIsTakenToo.)

    /// Bytes that do not decode: one error, the text stays.
    func testRow19UndecodableReloadShowsOneErrorAndKeepsTheText() throws {
        let url = try write(lines, name: "big.txt")
        let (document, controller) = try open(url)
        let errors = ReloadErrors()
        document.alertPresenter = errors
        try Data(repeating: 0xFF, count: 100).write(to: url)
        try PlainTextIO.writeAttribute(for: .utf8, to: url)
        reload(document)
        reload(document)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(Array(document.textStorage.string.utf8), lines)
        XCTAssertTrue(controller.textView.isSelectable)
    }

    /// A large file that can still be edited: reload takes the new text
    /// and it stays editable.
    func testRow19LargeEditableReload() throws {
        TextDocument.readOnlyThreshold = 1_000
        let url = try write(lines, name: "editable.txt")
        let (document, controller) = try open(url)
        try Data("new text for an editable large file\n".utf8).write(to: url)
        reload(document)
        XCTAssertEqual(document.textStorage.string, "new text for an editable large file\n")
        XCTAssertTrue(controller.textView.isEditable)
    }

    // MARK: Row 20: no route edits a read-only file

    func testRow20NoRouteEditsAReadOnlyFile() async throws {
        let crlf = Array("one\r\ntwo\r\nthree\r\nfour\r\n".utf8)
        let url = try write(crlf, name: "crlf.txt")
        let (document, controller) = try open(url)
        XCTAssertEqual(document.format.lineEnding, .crlf)
        let view = controller.textView
        let original = document.textStorage.string
        view.setSelectedRange(NSRange(location: 3, length: 0))
        // Return (QuickEdit types the file's own line ending).
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        view.insertNewline(nil)
        // Paste from the general pasteboard (read only), Services and drop
        // from a private one.
        view.paste(nil)
        let board = NSPasteboard(name: NSPasteboard.Name("qe-route-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("pasted", forType: .string)
        XCTAssertFalse(view.readSelection(from: board, type: .string), "Services wrote into the text")
        XCTAssertFalse(view.readSelection(from: board), "a drop wrote into the text")
        // (A drop lands through the same readSelection(from:type:), above.)
        // Replace All: the find bar replaces only in an editable client, and
        // the text view refuses the change itself.
        XCTAssertFalse(view.isEditable)
        XCTAssertFalse(view.shouldChangeText(in: NSRange(location: 0, length: 3), replacementString: "x"))
        // Undo has nothing.
        XCTAssertFalse(document.undoManager?.canUndo ?? false)
        document.undoManager?.undo()
        XCTAssertEqual(document.textStorage.string, original)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertEqual(Array(try Data(contentsOf: url)), crlf)

        // Duplicate (it writes as an autosave elsewhere, then opens that
        // file), then Save of the copy: the original bytes.
        let duplicate = folder.appendingPathComponent("duplicate.txt")
        try document.write(to: duplicate, ofType: TextDocument.plainTextType, for: .autosaveElsewhereOperation,
                           originalContentsURL: nil)
        XCTAssertEqual(Array(try Data(contentsOf: duplicate)), crlf)
        let (copy, copyController) = try open(duplicate)
        XCTAssertTrue(copy.isTooLargeToEdit)
        XCTAssertFalse(copyController.textView.isEditable)
        let saved = folder.appendingPathComponent("saved-copy.txt")
        let error = await save(copy, to: saved, .saveAsOperation)
        XCTAssertNil(error)
        XCTAssertEqual(Array(try Data(contentsOf: saved)), crlf)
    }

    // MARK: Row 21: becoming read-only clears undo

    func testRow21BecomingReadOnlyClearsUndo() throws {
        TextDocument.largeFileThreshold = 1_000
        TextDocument.readOnlyThreshold = 1_000
        for route in ["reload", "revert"] {
            let url = try write(Array("short text\n".utf8), name: "grows-\(route).txt")
            let (document, controller) = try open(url)
            controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
            controller.textView.insertText("edit ", replacementRange: NSRange(location: 0, length: 0))
            // As after a save: not edited, with something to undo.
            document.updateChangeCount(.changeCleared)
            XCTAssertFalse(document.isDocumentEdited)
            XCTAssertTrue(document.undoManager?.canUndo ?? false, "\(route): nothing to undo before")
            try Data(String(repeating: "large file line\n", count: 100).utf8).write(to: url)
            if route == "reload" {
                reload(document)
            } else {
                try document.revert(toContentsOf: url, ofType: TextDocument.plainTextType)
            }
            XCTAssertTrue(document.isTooLargeToEdit, route)
            XCTAssertFalse(document.undoManager?.canUndo ?? true, "\(route): undo kept on a read-only file")
        }
    }

    // MARK: Row 22: the new view order, then Wrap to Page or zoom at once

    func testRow22WrapToPageAndZoomRightAfterOpen() throws {
        TextDocument.largeFileThreshold = 1_000_000
        TextDocument.readOnlyThreshold = 1_000_000
        let text = (0..<200).map { "line \($0) of the order test" }.joined(separator: "\n")
        let (document, controller) = try open(try write(Array(text.utf8), name: "order.txt"))
        XCTAssertTrue(controller.scrollView.documentView === controller.textView)
        XCTAssertTrue(controller.textView.layoutManager === controller.layoutManager)
        XCTAssertTrue(controller.window?.firstResponder === controller.textView)
        XCTAssertGreaterThan(controller.textView.frame.height, controller.scrollView.contentSize.height)
        document.togglePageBreaks(nil)
        XCTAssertNotNil(controller.pagesView)
        XCTAssertTrue(controller.window?.firstResponder === controller.textView)
        XCTAssertEqual(controller.textView.string, text)
        document.togglePageBreaks(nil)
        XCTAssertTrue(controller.scrollView.documentView === controller.textView)

        let (_, zoomed) = try open(try write(Array(text.utf8), name: "zoom.txt"))
        zoomed.scrollView.zoomIn(nil)
        XCTAssertEqual(zoomed.scrollView.magnification, 2.0)
        XCTAssertTrue(zoomed.scrollView.documentView === zoomed.textView)
        let content = try XCTUnwrap(zoomed.window?.contentView)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
    }

    // MARK: Row 24: Prevent Editing outlives a trip through read-only

    func testRow24PreventEditingStaysOnAfterReadOnlyAndBack() throws {
        TextDocument.readOnlyThreshold = 100
        let url = try write(Array("short\n".utf8), name: "prevent.txt")
        let (document, controller) = try open(url)
        document.toggleReadOnly(nil)
        XCTAssertTrue(document.preventsEditing)
        try Data(String(repeating: "large file line\n", count: 20).utf8).write(to: url)
        try document.revert(toContentsOf: url, ofType: TextDocument.plainTextType)
        XCTAssertTrue(document.isTooLargeToEdit)
        try Data("short again\n".utf8).write(to: url)
        try document.revert(toContentsOf: url, ofType: TextDocument.plainTextType)
        XCTAssertFalse(document.isTooLargeToEdit)
        XCTAssertTrue(document.preventsEditing)
        XCTAssertFalse(controller.textView.isEditable, "Prevent Editing was lost")
        let item = NSMenuItem(title: "", action: #selector(TextDocument.toggleReadOnly(_:)), keyEquivalent: "")
        XCTAssertTrue(document.validateMenuItem(item))
        XCTAssertEqual(item.title, "Allow Editing")
    }

    // MARK: Row 25: the Save panel does no whole-text work when its pop-up is off

    func testRow25SavePanelOfAReadOnlyFileSkipsTheTextCheck() throws {
        let (document, _) = try open(try write(lines, name: "big.txt"))
        let panel = NSSavePanel()
        XCTAssertTrue(document.prepareSavePanel(panel))
        let popUp = try XCTUnwrap(panel.accessoryView?.subviews.compactMap { $0 as? EncodingPopUpButton }.first)
        XCTAssertFalse(popUp.isEnabled)
        XCTAssertNil(popUp.refreshEnabledItems, "a read-only file's pop-up still checks the whole text")
        XCTAssertEqual(popUp.selectedEncoding, document.format.encoding)
    }
}

/// Peak footprint growth, sampled every millisecond on another thread
/// behind a lock (M8 review row 23).
final class PeakSampler: Sendable {
    private let peak: OSAllocatedUnfairLock<Double>
    private let base: Double
    private let timer: DispatchSourceTimer

    init() {
        let start = LargeFileTests.footprintMB()
        base = start
        peak = OSAllocatedUnfairLock(initialState: start)
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(1))
        timer.setEventHandler { [peak] in
            let now = LargeFileTests.footprintMB()
            peak.withLock { $0 = max($0, now) }
        }
        timer.resume()
    }

    /// The highest footprint so far, in MB.
    var highest: Double { peak.withLock { $0 } }
    var start: Double { base }

    /// Stops sampling; returns the growth over the start, in MB.
    @discardableResult
    func stop() -> Double {
        timer.cancel()
        let now = LargeFileTests.footprintMB()
        return peak.withLock { $0 = max($0, now); return $0 } - base
    }
}
