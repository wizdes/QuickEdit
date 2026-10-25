import AppKit
import Synchronization
import XCTest
@testable import QuickEdit

/// Fixes for the third very-large-file review (docs/reviews/M8-code.md
/// rows 27 to 38): the clone is taken first and the text comes from it,
/// the file access ends after the clone, a reload stays out of the way of
/// PDF output, Duplicate and Close. Small files with small limits.
@MainActor
final class LargeFileReloadTests: XCTestCase {
    private var folder: URL!
    private var documents: [TextDocument] = []
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
        TextDocument.hidesWindowsForTests = true
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-largereload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        TextDocument.testHooks.withLock {
            $0.beforeReloadFill = nil
            $0.afterReadFill = nil
            $0.pdfTemporaryFile = nil
            $0.beforeReloadCheck = nil
            $0.afterSaveEnded = nil
        }
        for document in documents {
            // Sleeping (not running the run loop) lets the main queue run
            // the reload's last steps.
            let end = Date().addingTimeInterval(10)
            while document.isReloading, Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        TextDocument.hidesWindowsForTests = false
        ScalingScrollView.animatesZoom = true
        TextDocument.largeFileThreshold = savedLargeThreshold
        TextDocument.readOnlyThreshold = savedReadOnlyThreshold
        LargeFileOriginal.failCloneForTests = false
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

    /// A save, waited for by running the run loop. The tests here are not
    /// `async`: an async test runs inside a main-queue block, where the
    /// run loop cannot run the main-queue blocks a reload sends.
    private func save(_ document: TextDocument, to url: URL, _ op: NSDocument.SaveOperationType) -> Error? {
        var result: Error??
        document.save(to: url, ofType: TextDocument.plainTextType, for: op) { result = .some($0) }
        runLoop(upTo: 10) { result != nil }
        guard let result else {
            XCTFail("the save did not end in 10 s")
            return CocoaError(.fileWriteUnknown)
        }
        return result
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

    /// This process's clone folders now.
    private func ownCloneFolders() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: LargeFileOriginal.root.path)) ?? []
        return Set(names.filter { $0.hasPrefix("\(getpid())-") })
    }

    private func enabled(_ document: TextDocument, _ action: Selector) -> Bool {
        document.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }

    /// Holds a large reload in its fill (the `beforeReloadFill` hook)
    /// until `release()`. Counts how many fills started.
    final class FillHold: @unchecked Sendable {
        private let gate = DispatchSemaphore(value: 0)
        private let state = Mutex((fills: 0, released: false))
        var fills: Int { state.withLock { $0.fills } }

        init() {
            TextDocument.testHooks.withLock { hooks in
                hooks.beforeReloadFill = { [self] in
                    let first = state.withLock { s -> Bool in
                        s.fills += 1
                        return s.fills == 1 && !s.released
                    }
                    if first { gate.wait() }
                }
            }
        }

        func release() {
            let wasHeld = state.withLock { s -> Bool in
                defer { s.released = true }
                return !s.released
            }
            if wasHeld { gate.signal() }
        }
    }

    /// Answers NSDocument's canClose callback.
    final class CloseAnswer: NSObject {
        var answer: Bool?
        @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
            answer = shouldClose
        }
    }

    // MARK: Row 27: the file access ends after the clone

    /// While a large reload is held in its fill: another file access runs
    /// at once, and a synchronous access, canClose (as Quit asks), Save
    /// To, Duplicate and Close all answer at once instead of hanging.
    func testRow27NothingWaitsForAReloadThatIsFilling() throws {
        let url = try write(lines, name: "big.txt")
        let (document, _) = try open(url)
        try Data("a new version of the file, longer than before\n".utf8).write(to: url)
        let hold = FillHold()
        defer { hold.release() }
        document.reloadAfterOutsideChange()
        runLoop(upTo: 5) { hold.fills == 1 }
        XCTAssertEqual(hold.fills, 1, "the reload did not reach its fill")

        var probeRan = false
        document.performAsynchronousFileAccess { done in
            probeRan = true
            done()
        }
        runLoop(upTo: 2) { probeRan }
        XCTAssertTrue(probeRan, "the reload still holds the document's file access while it fills")
        guard probeRan else {
            // With the access held, each call below would hang the test run.
            hold.release()
            runLoop(upTo: 10) { !document.isReloading }
            return
        }

        // Through Objective-C: AppKit keeps the block after it returns,
        // which Swift would stop as an escaped non-escaping closure.
        let syncRan = Mutex(false)
        let syncBlock: @convention(block) () -> Void = { syncRan.withLock { $0 = true } }
        document.perform(#selector(NSDocument.performSynchronousFileAccess(_:)), with: syncBlock)
        XCTAssertTrue(syncRan.withLock { $0 }, "a synchronous file access did not run")

        let answer = CloseAnswer()
        document.canClose(withDelegate: answer, shouldClose: #selector(CloseAnswer.document(_:shouldClose:contextInfo:)),
                          contextInfo: nil)
        runLoop(upTo: 2) { answer.answer != nil }
        XCTAssertEqual(answer.answer, true, "canClose (Quit) did not answer during a reload")

        let out = folder.appendingPathComponent("during-reload.txt")
        let saveError = save(document, to: out, .saveToOperation)
        XCTAssertNotNil(saveError, "Save To ran while the text was being filled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))

        XCTAssertThrowsError(try document.duplicate(), "Duplicate ran while the text was being filled")

        document.close()
        hold.release()
        runLoop(upTo: 10) { !document.isReloading }
        XCTAssertFalse(document.isReloading)
    }

    // MARK: Row 28: clone first, then show and save the clone's bytes

    /// The file changes right after the text was filled at open. The
    /// window and Save To still agree, and a reload then sees the change.
    func testRow28OpenShowsAndSavesTheSameBytes() throws {
        let url = try write(lines, name: "big.txt")
        let later = Array("FIRST LINE\nSECOND LINE\nTHIRD LINE\n".utf8)
        XCTAssertEqual(later.count, lines.count)
        TextDocument.testHooks.withLock { hooks in
            hooks.afterReadFill = { url in
                do { try Data(later).write(to: url) } catch { XCTFail("could not change \(url.path): \(error)") }
            }
        }
        let (document, _) = try open(url)
        TextDocument.testHooks.withLock { $0.afterReadFill = nil }
        let shown = Array(document.textStorage.string.utf8)
        let out = folder.appendingPathComponent("copy.txt")
        let error = save(document, to: out, .saveToOperation)
        XCTAssertNil(error)
        XCTAssertEqual(Array(try Data(contentsOf: out)), shown, "Save To wrote other bytes than the window shows")
        reload(document)
        XCTAssertEqual(Array(document.textStorage.string.utf8), later, "the reload kept the old text: the change was taken as unchanged")
    }

    // MARK: Row 29: no clone, no Save As for a read-only file

    func testRow29WithoutACloneSaveAsIsOffAndTheTitleSaysSo() throws {
        LargeFileOriginal.failCloneForTests = true
        let url = try write(lines, name: "noclone.txt")
        let (document, controller) = try open(url)
        XCTAssertTrue(document.isTooLargeToEdit)
        let title = controller.window?.title ?? ""
        XCTAssertEqual(title, "noclone.txt \u{2014} " + DocumentWindowController.readOnlyTitleNote(byteCount: lines.count)
                       + "; Save As unavailable on this disk")
        XCTAssertFalse(enabled(document, #selector(NSDocument.saveAs(_:))), "Save As is on")
        XCTAssertFalse(enabled(document, #selector(NSDocument.saveTo(_:))), "Save To is on")
        XCTAssertFalse(enabled(document, #selector(NSDocument.duplicate(_:))), "Duplicate is on")
        for operation in [NSDocument.SaveOperationType.saveToOperation, .saveAsOperation] {
            let out = folder.appendingPathComponent("refused-\(operation.rawValue).txt")
            let error = save(document, to: out, operation)
            XCTAssertNotNil(error, "operation \(operation.rawValue) wrote a copy")
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        }
        XCTAssertNil(document.keptOriginal)
    }

    /// Below the read-only limit a disk that cannot clone changes nothing:
    /// Save As writes the text.
    func testRow29WithoutACloneAnEditableLargeFileSavesAsBefore() throws {
        LargeFileOriginal.failCloneForTests = true
        TextDocument.readOnlyThreshold = 1_000
        let url = try write(lines, name: "editable.txt")
        let (document, controller) = try open(url)
        XCTAssertFalse(document.isTooLargeToEdit)
        XCTAssertFalse(controller.window?.title.contains("unavailable") ?? true)
        XCTAssertTrue(enabled(document, #selector(NSDocument.saveAs(_:))))
        controller.textView.insertText("new ", replacementRange: NSRange(location: 0, length: 0))
        let out = folder.appendingPathComponent("saved.txt")
        let error = save(document, to: out, .saveToOperation)
        XCTAssertNil(error)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "new " + String(decoding: lines, as: UTF8.self))
    }

    // MARK: Row 30: no PDF or Duplicate during a reload; a reload waits for a PDF

    func testRow30PDFAndDuplicateAreOffDuringAReload() throws {
        let url = try write(lines, name: "big.txt")
        let (document, _) = try open(url)
        try Data("a new version of the file, longer than before\n".utf8).write(to: url)
        let hold = FillHold()
        defer { hold.release() }
        document.reloadAfterOutsideChange()
        runLoop(upTo: 5) { hold.fills == 1 }
        XCTAssertFalse(enabled(document, #selector(NSDocument.saveToPDF(_:))), "Export as PDF is on during a reload")
        XCTAssertFalse(enabled(document, #selector(TextDocument.printToPDF(_:))), "Print is on during a reload")
        XCTAssertFalse(enabled(document, #selector(NSDocument.duplicate(_:))), "Duplicate is on during a reload")
        var panelShown = false
        document.pdfPanelRunner = { _, _, completion in
            panelShown = true
            completion(nil)
        }
        document.saveToPDF(nil)
        document.printToPDF(nil)
        XCTAssertFalse(panelShown, "a PDF panel opened during a reload")
        hold.release()
        runLoop(upTo: 10) { !document.isReloading }
    }

    func testRow30AReloadWaitsUntilARunningExportEnds() throws {
        // Over TextDocument.backgroundPDFThreshold, so the export runs in the background.
        let text = String(repeating: "a line of text for the background export\n", count: 4_000)
        let url = try write(Array(text.utf8), name: "export.txt")
        let (document, _) = try open(url)
        let pdf = folder.appendingPathComponent("export.pdf")
        let gate = DispatchSemaphore(value: 0)
        let drawn = Mutex(false)
        TextDocument.testHooks.withLock { hooks in
            hooks.pdfTemporaryFile = { _ in
                drawn.withLock { $0 = true }
                gate.wait()
            }
        }
        var released = false
        func release() { if !released { released = true; gate.signal() } }
        defer { release() }
        document.pdfPanelRunner = { _, _, completion in completion(pdf) }
        document.saveToPDF(nil)
        runLoop(upTo: 10) { drawn.withLock { $0 } }
        XCTAssertNotNil(document.pdfJob)

        let newText = "the file after another app changed it\n"
        try Data(newText.utf8).write(to: url)
        document.reloadAfterOutsideChange()
        XCTAssertFalse(document.isReloading, "a reload started while the export read the text")
        runLoop(upTo: 0.3) { false }
        XCTAssertEqual(document.textStorage.string, text)

        release()
        runLoop(upTo: 20) { document.pdfJob == nil && !document.isReloading && document.textStorage.string == newText }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path))
        XCTAssertEqual(document.textStorage.string, newText, "the waiting reload did not run after the export")
    }

    // MARK: Row 31: Close cancels a reload

    func testRow31CloseCancelsTheReloadAndRemovesItsClone() throws {
        let before = ownCloneFolders()
        let url = try write(lines, name: "big.txt")
        let (document, _) = try open(url)
        try Data("a new version of the file, longer than before\n".utf8).write(to: url)
        let hold = FillHold()
        defer { hold.release() }
        document.reloadAfterOutsideChange()
        runLoop(upTo: 5) { hold.fills == 1 }
        // One more change meanwhile: it must not start a reload after Close.
        try Data("a third version\n".utf8).write(to: url)
        document.reloadAfterOutsideChange()
        document.close()
        hold.release()
        runLoop(upTo: 10) { !document.isReloading }
        runLoop(upTo: 0.5) { false }
        XCTAssertFalse(document.isReloading)
        XCTAssertEqual(hold.fills, 1, "a closed document reloaded again")
        XCTAssertNil(document.keptOriginal)
        XCTAssertEqual(ownCloneFolders(), before, "a clone folder stayed after Close")
    }

    // MARK: Row 32: the encoding tag counts

    func testRow32AnEncodingTagChangeIsReloaded() throws {
        let bytes = Array("caf".utf8) + [0xE9] + Array(" au lait, a line of text\n".utf8)
        let url = try write(bytes, name: "tag.txt")
        try PlainTextIO.writeAttribute(for: .isoLatin1, to: url)
        let (document, _) = try open(url)
        XCTAssertTrue(document.textStorage.string.hasPrefix("caf\u{E9}"))
        try PlainTextIO.writeAttribute(for: .macOSRoman, to: url)
        reload(document)
        XCTAssertTrue(document.textStorage.string.hasPrefix("caf\u{C8}"),
                      "same bytes, new encoding tag: the text was kept (\(document.textStorage.string.prefix(4)))")
        XCTAssertEqual(document.format.encoding, .macOSRoman)
    }

    // MARK: Row 33: a date-only change keeps undo in an editable large file

    func testRow33DateOnlyChangeKeepsTextAndUndo() throws {
        TextDocument.readOnlyThreshold = 10_000
        let url = try write(lines, name: "editable.txt")
        let (document, controller) = try open(url)
        XCTAssertTrue(document.isLargeFile)
        controller.textView.insertText("edit ", replacementRange: NSRange(location: 0, length: 0))
        let error = save(document, to: url, .saveOperation)
        XCTAssertNil(error)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertTrue(document.undoManager?.canUndo ?? false)
        // A reload fills the text on a background thread: count behind a lock.
        let edits = Mutex(0)
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                              object: document.textStorage, queue: nil) { _ in
            edits.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        reload(document)
        XCTAssertEqual(edits.withLock { $0 }, 0, "a date-only change replaced the text")
        XCTAssertTrue(document.undoManager?.canUndo ?? false, "a date-only change cleared undo")
        XCTAssertEqual(document.textStorage.string, "edit " + String(decoding: lines, as: UTF8.self))
    }

    // MARK: Row 34: Wrap to Page lays out again after a reload

    func testRow34WrapToPageLaysOutTheNewTextAfterAReload() throws {
        TextDocument.readOnlyThreshold = 100_000_000
        let text = (0..<2_000).map { "line \($0) of the page test" }.joined(separator: "\n") + "\n"
        let url = try write(Array(text.utf8), name: "pages.txt")
        let (document, controller) = try open(url)
        document.togglePageBreaks(nil)
        let manager = controller.layoutManager
        runLoop(upTo: 10) { manager.firstUnlaidCharacterIndex() >= document.textStorage.length }
        let pagesBefore = controller.numberOfPages
        XCTAssertGreaterThan(pagesBefore, 5)
        try Data((text + text + text).utf8).write(to: url)
        reload(document)
        XCTAssertEqual(document.textStorage.length, (text as NSString).length * 3)
        runLoop(upTo: 10) { manager.firstUnlaidCharacterIndex() >= document.textStorage.length }
        XCTAssertGreaterThanOrEqual(manager.firstUnlaidCharacterIndex(), document.textStorage.length,
                                    "idle layout did not lay out the reloaded text")
        XCTAssertGreaterThan(controller.numberOfPages, pagesBefore * 2)
    }

    // MARK: Row 36: a change during a held reload makes one more reload

    func testRow36ChangeDuringAHeldReloadIsTakenToo() throws {
        let url = try write(lines, name: "log.txt")
        let (document, _) = try open(url)
        try Data("second version of the log file\n".utf8).write(to: url)
        let hold = FillHold()
        defer { hold.release() }
        document.reloadAfterOutsideChange()
        runLoop(upTo: 5) { hold.fills == 1 }
        XCTAssertEqual(hold.fills, 1)
        let last = "third version of the log file, longer\n"
        try Data(last.utf8).write(to: url)
        document.reloadAfterOutsideChange()
        hold.release()
        // Only the reload that ends: no new outside-change notice is waited for.
        runLoop(upTo: 10) { !document.isReloading && document.textStorage.string == last }
        XCTAssertEqual(document.textStorage.string, last, "the change made during the reload was lost")
        XCTAssertEqual(hold.fills, 2)
    }

    // MARK: Row 37: the real edit actions on a read-only file

    private func crlfFile(_ name: String) throws -> (TextDocument, DocumentWindowController, URL, [UInt8]) {
        let crlf = Array("one\r\ntwo\r\nthree\r\nfour\r\n".utf8)
        let url = try write(crlf, name: name)
        let (document, controller) = try open(url)
        return (document, controller, url, crlf)
    }

    /// Runs the find bar's Replace All: the find and replace strings go in
    /// the bar's own fields. Returns false when the bar has no replace field.
    @discardableResult
    private func replaceAll(_ find: String, with replacement: String, in controller: DocumentWindowController) -> Bool {
        let view = controller.textView
        let show = NSMenuItem()
        show.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        view.performTextFinderAction(show)
        func fields(in root: NSView?) -> [NSTextField] {
            guard let root else { return [] }
            return root.subviews.flatMap { sub -> [NSTextField] in
                (sub is NSTextField && (sub as! NSTextField).isEditable ? [sub as! NSTextField] : []) + fields(in: sub)
            }
        }
        let barFields = fields(in: controller.scrollView.findBarView)
        let finderPasteboard = NSPasteboard(name: .find)
        let savedFind = finderPasteboard.string(forType: .string)
        defer {
            if let savedFind {
                finderPasteboard.clearContents()
                finderPasteboard.setString(savedFind, forType: .string)
            }
        }
        guard barFields.count >= 2 else {
            // No replace field: still send Replace All, as the menu would.
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.replaceAll.rawValue
            view.performTextFinderAction(item)
            return false
        }
        barFields[0].stringValue = find
        barFields[1].stringValue = replacement
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.replaceAll.rawValue
        view.performTextFinderAction(item)
        return true
    }

    func testRow37ReplaceAllChangesNothing() throws {
        // Control: the same Replace All edits an editable file.
        TextDocument.readOnlyThreshold = 1_000
        let (editable, editableController, _, _) = try crlfFile("editable.txt")
        XCTAssertTrue(replaceAll("two", with: "TWO", in: editableController), "no replace field on an editable file")
        XCTAssertTrue(editable.textStorage.string.contains("TWO"), "the test's Replace All did not replace (control)")

        TextDocument.readOnlyThreshold = 20
        let (document, controller, url, crlf) = try crlfFile("readonly.txt")
        XCTAssertTrue(document.isTooLargeToEdit)
        let original = document.textStorage.string
        replaceAll("two", with: "TWO", in: controller)
        XCTAssertEqual(document.textStorage.string, original, "Replace All edited a read-only file")
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertEqual(Array(try Data(contentsOf: url)), crlf)
    }

    /// Edit > Paste reads the general pasteboard; it is saved first and
    /// put back after.
    func testRow37PasteChangesNothing() throws {
        let general = NSPasteboard.general
        let savedItems: [NSPasteboardItem] = (general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            general.clearContents()
            if !savedItems.isEmpty { general.writeObjects(savedItems) }
        }
        general.clearContents()
        general.setString("pasted", forType: .string)

        TextDocument.readOnlyThreshold = 1_000
        let (editable, editableController, _, _) = try crlfFile("editable.txt")
        editableController.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editableController.textView.paste(nil)
        XCTAssertTrue(editable.textStorage.string.hasPrefix("pasted"), "the test's paste did not paste (control)")

        TextDocument.readOnlyThreshold = 20
        let (document, controller, _, _) = try crlfFile("readonly.txt")
        let original = document.textStorage.string
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.textView.paste(nil)
        controller.textView.pasteAsPlainText(nil)
        XCTAssertEqual(document.textStorage.string, original, "Paste edited a read-only file")
        XCTAssertFalse(document.isDocumentEdited)
    }

    /// A drop through the text view's own drag destination methods, with
    /// a fake dragging info on a private pasteboard.
    func testRow37DropChangesNothing() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("qe-drop-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("dropped", forType: .string)

        func drop(on controller: DocumentWindowController) {
            let view = controller.textView
            let point = view.convert(NSPoint(x: 5, y: 5), to: nil)
            let info = FakeDrag(pasteboard: board, window: controller.window, location: point)
            _ = view.draggingEntered(info)
            _ = view.draggingUpdated(info)
            if view.prepareForDragOperation(info) {
                _ = view.performDragOperation(info)
                view.concludeDragOperation(info)
            }
            view.draggingEnded(info)
        }

        TextDocument.readOnlyThreshold = 1_000
        let (editable, editableController, _, _) = try crlfFile("editable.txt")
        drop(on: editableController)
        XCTAssertTrue(editable.textStorage.string.contains("dropped"), "the test's drop did not drop (control)")

        TextDocument.readOnlyThreshold = 20
        let (document, controller, _, _) = try crlfFile("readonly.txt")
        let original = document.textStorage.string
        drop(on: controller)
        XCTAssertEqual(document.textStorage.string, original, "a drop edited a read-only file")
        XCTAssertFalse(document.isDocumentEdited)
    }

    /// File > Duplicate (the real `duplicate()`), then Save As of the copy:
    /// the file's own bytes.
    func testRow37DuplicateThenSaveAsKeepsTheBytes() throws {
        let (document, _, _, crlf) = try crlfFile("readonly.txt")
        let copy = try XCTUnwrap(try document.duplicate() as? TextDocument)
        documents.append(copy)
        XCTAssertTrue(copy.isTooLargeToEdit)
        XCTAssertEqual(copy.textStorage.string, document.textStorage.string)
        if copy.windowControllers.isEmpty { copy.makeWindowControllers() }
        let copyController = try XCTUnwrap(copy.windowControllers.first as? DocumentWindowController)
        XCTAssertFalse(copyController.textView.isEditable)
        let saved = folder.appendingPathComponent("saved-copy.txt")
        let error = save(copy, to: saved, .saveAsOperation)
        XCTAssertNil(error)
        XCTAssertEqual(Array(try Data(contentsOf: saved)), crlf)
    }

    // MARK: Row 40: no edits from the moment a reload starts

    /// The reload is held in its check part (before the fill). Typing then
    /// is refused; canClose answers at once with nothing lost; an autosave
    /// of an edited document never reports success without writing.
    func testRow40NoEditIsLostWhileAReloadChecksTheFile() throws {
        TextDocument.readOnlyThreshold = 1_000
        let url = try write(lines, name: "editable.txt")
        let (document, controller) = try open(url)
        try Data("another app wrote this version of the file\n".utf8).write(to: url)
        let gate = DispatchSemaphore(value: 0)
        let held = Mutex(false)
        TextDocument.testHooks.withLock { hooks in
            hooks.beforeReloadCheck = {
                held.withLock { $0 = true }
                gate.wait()
            }
        }
        var released = false
        func release() { if !released { released = true; gate.signal() } }
        defer { release() }
        document.reloadAfterOutsideChange()
        runLoop(upTo: 5) { held.withLock { $0 } }
        XCTAssertTrue(held.withLock { $0 }, "the reload did not reach its check")
        let before = document.textStorage.string
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.textView.insertText("typed ", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(document.textStorage.string, before, "an edit was taken while the reload checked the file")
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertFalse(controller.textView.isEditable, "the views still take edits during the check")

        if !document.isDocumentEdited {
            let answer = CloseAnswer()
            document.canClose(withDelegate: answer, shouldClose: #selector(CloseAnswer.document(_:shouldClose:contextInfo:)),
                              contextInfo: nil)
            runLoop(upTo: 2) { answer.answer != nil }
            XCTAssertEqual(answer.answer, true)
        }

        // An edited document (marked by hand: the views refuse keys) is
        // not reported as autosaved while nothing is written.
        let stamp = try Data(contentsOf: url)
        document.updateChangeCount(.changeDone)
        var autosaved: Error??
        document.autosave(withImplicitCancellability: false) { autosaved = .some($0) }
        runLoop(upTo: 5) { autosaved != nil }
        let wrote = try Data(contentsOf: url) != stamp || document.autosavedContentsFileURL != nil
        XCTAssertTrue((autosaved ?? nil) != nil || wrote, "autosave reported success without writing the edited document")
        document.updateChangeCount(.changeCleared)

        release()
        runLoop(upTo: 10) { !document.isReloading }
        XCTAssertFalse(document.isReloading)
        XCTAssertTrue(controller.textView.isEditable, "the views stayed read-only after the reload")
    }

    // MARK: Row 41: the clone after a save leaves no gap

    /// Another app writes the file right after QuickEdit's save of an
    /// editable large file ended. The next reload must take that text.
    func testRow41AWriteRightAfterASaveIsSeenByTheNextReload() throws {
        TextDocument.readOnlyThreshold = 1_000
        let url = try write(lines, name: "editable.txt")
        let (document, controller) = try open(url)
        controller.textView.insertText("edit ", replacementRange: NSRange(location: 0, length: 0))
        let other = "written by another app right after the save\n"
        TextDocument.testHooks.withLock { hooks in
            hooks.afterSaveEnded = { url in
                do { try Data(other.utf8).write(to: url) } catch { XCTFail("could not write \(url.path): \(error)") }
            }
        }
        let error = save(document, to: url, .saveOperation)
        TextDocument.testHooks.withLock { $0.afterSaveEnded = nil }
        XCTAssertNil(error)
        XCTAssertFalse(document.isDocumentEdited)
        reload(document)
        XCTAssertEqual(document.textStorage.string, other, "the other app's write was taken as unchanged")
    }

    // MARK: Row 42: a reload waits for the PDF Save panel

    func testRow42AReloadWaitsForThePDFPanelAndRunsWhenItIsCancelled() throws {
        let url = try write(lines, name: "big.txt")
        let (document, _) = try open(url)
        var panelDone: ((URL?) -> Void)?
        document.pdfPanelRunner = { _, _, completion in panelDone = completion }
        document.saveToPDF(nil)
        XCTAssertNotNil(panelDone, "the PDF panel did not open")
        XCTAssertTrue(document.isPDFPanelOpen)
        let newText = "the file after another app changed it\n"
        try Data(newText.utf8).write(to: url)
        document.reloadAfterOutsideChange()
        XCTAssertFalse(document.isReloading, "a reload started while the PDF panel was open")
        runLoop(upTo: 0.3) { false }
        XCTAssertEqual(Array(document.textStorage.string.utf8), lines)
        panelDone?(nil) // Cancel
        runLoop(upTo: 10) { document.textStorage.string == newText && !document.isReloading }
        XCTAssertEqual(document.textStorage.string, newText, "the reload did not run after the panel was cancelled")
    }

    // MARK: Row 38: stale clone folders and reused process numbers

    /// kinfo_proc start time of `pid`, in microseconds since 1970.
    private static func startTime(of pid: pid_t) -> UInt64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
    }

    func testRow38StaleCleanupChecksTheProcessStartTime() throws {
        let start = try XCTUnwrap(Self.startTime(of: getpid()))
        let root = folder.appendingPathComponent("originals")
        var deadPid: Int32 = 99_999
        while deadPid > 1000, !(kill(deadPid, 0) == -1 && errno == ESRCH) { deadPid -= 1 }
        let ours = root.appendingPathComponent("\(getpid())-\(start)-\(UUID().uuidString)")
        let reused = root.appendingPathComponent("\(getpid())-\(start - 5_000_000)-\(UUID().uuidString)")
        let dead = root.appendingPathComponent("\(deadPid)-\(start)-\(UUID().uuidString)")
        for dir in [ours, reused, dead] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("clone.txt"))
        }
        let removed = LargeFileOriginal.removeStaleFolders(in: root)
        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), [reused.lastPathComponent, dead.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: ours.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: reused.path), "a folder of an earlier process with the same number stayed")

        let (document, _) = try open(try write(lines, name: "big.txt"))
        let clone = try XCTUnwrap(clonePath(document))
        XCTAssertTrue(clone.deletingLastPathComponent().lastPathComponent.hasPrefix("\(getpid())-\(start)-"),
                      clone.deletingLastPathComponent().lastPathComponent)
    }
}

/// A drag for `testRow37DropChangesNothing`: a copy of a string from a
/// private pasteboard at one point in the window.
@MainActor
final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    init(pasteboard: NSPasteboard, window: NSWindow?, location: NSPoint) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
        draggingLocation = location
    }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 4242 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
