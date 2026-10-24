import AppKit
import XCTest
@testable import QuickEdit

/// M3 n2 (encodings list, Open and Save panels, xattr) and n3 (alerts and
/// line endings) at the unit level.
@MainActor
final class EncodingDocumentTests: XCTestCase {
    private var folder: URL!
    private var documents: [TextDocument] = []
    /// A defaults suite of this test's own (M6 review row 14).
    private var saved: SavedSettings!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickEditEncodingDocTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        saved = SavedSettings()
        TextDocument.testHooks.withLock { $0 = .init() }
    }

    override func tearDown() async throws {
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        saved.restore()
        TextDocument.testHooks.withLock { $0 = .init() }
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    private func file(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// "café" in Windows-1252 with the xattr TextEdit writes for it. Without
    /// the xattr, "Automatic" reads these bytes as Mac Roman, as AppKit does
    /// (vote V2 in docs/decisions.md).
    private func latinFile(_ name: String) throws -> URL {
        let url = try file(name, [0x63, 0x61, 0x66, 0xE9])
        try PlainTextIO.writeAttribute(for: .windowsCP1252, to: url)
        return url
    }

    private func open(_ url: URL, window: Bool = true) throws -> TextDocument {
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        if window { document.makeWindowControllers() }
        documents.append(document)
        return document
    }

    private func textView(of document: TextDocument) throws -> NSTextView {
        try XCTUnwrap((document.windowControllers.first as? DocumentWindowController)?.textView)
    }

    /// One keystroke as the event loop delivers it (see ReviewFixTests.type).
    private func type(_ text: String, into textView: NSTextView, of document: NSDocument) {
        let undoManager = document.undoManager!
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        textView.insertText(text, replacementRange: textView.selectedRange())
        undoManager.endUndoGrouping()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    /// Return, as the key binding sends it: through the text view's delegate.
    private func pressReturn(in textView: NSTextView, of document: NSDocument) {
        let undoManager = document.undoManager!
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        undoManager.endUndoGrouping()
    }

    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func titles(_ popUp: NSPopUpButton) -> [String] {
        popUp.itemArray.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    // MARK: n2 step 1: the encodings list and pop-ups

    func testOpenPopUpHasAutomaticFirstThenTextEditsList() {
        let popUp = EncodingPopUpButton(selected: nil, includeAutomatic: true)
        let expected = ["Automatic"] + EncodingManager.defaultEncodings().map { String.localizedName(of: $0) }
            + ["---", "Customize Encodings List\u{2026}"]
        XCTAssertEqual(titles(popUp), expected)
        XCTAssertEqual(popUp.indexOfSelectedItem, 0)
        XCTAssertNil(popUp.selectedEncoding)
        XCTAssertEqual(EncodingManager.defaultEncodings().prefix(4), [.utf16, .utf8, .macOSRoman, .windowsCP1252])
        XCTAssertEqual(EncodingManager.defaultEncodings().count, 10, "Mac Roman, the system encoding here, is in the list")
    }

    func testSavePopUpHasNoAutomaticAndAddsAMissingSelection() {
        let koi8 = EncodingManager.fromCF(.KOI8_R)
        let popUp = EncodingPopUpButton(selected: koi8, includeAutomatic: false)
        XCTAssertFalse(titles(popUp).contains("Automatic"))
        XCTAssertEqual(popUp.selectedEncoding, koi8)
        XCTAssertEqual(titles(popUp).suffix(3), [String.localizedName(of: koi8), "---", "Customize Encodings List\u{2026}"])
    }

    func testCustomizeItemAndSeparatorNeverStaySelected() {
        let popUp = EncodingPopUpButton(selected: .utf8, includeAutomatic: false)
        popUp.selectItem(at: popUp.numberOfItems - 1)
        XCTAssertEqual(popUp.selectedEncoding, .utf8)
        popUp.selectItem(at: popUp.numberOfItems - 2)
        XCTAssertEqual(popUp.selectedEncoding, .utf8)
    }

    func testListChangeRefillsPopUpsAndRevertRestoresTheDefault() {
        let popUp = EncodingPopUpButton(selected: .utf8, includeAutomatic: true)
        EncodingManager.shared.setEnabled([.utf8, .shiftJIS])
        XCTAssertEqual(titles(popUp), ["Automatic", String.localizedName(of: .utf8), String.localizedName(of: .shiftJIS),
                                       "---", "Customize Encodings List\u{2026}"])
        XCTAssertEqual(popUp.selectedEncoding, .utf8, "the selection survives the refill")
        XCTAssertEqual(EncodingManager.enabledEncodings(), [.utf8, .shiftJIS])
        EncodingManager.shared.revertToDefault()
        XCTAssertEqual(EncodingManager.enabledEncodings(), EncodingManager.defaultEncodings())
        XCTAssertNil(Defaults.store.object(forKey: DefaultsKey.encodings.rawValue))
    }

    func testCustomizePanelIsBuiltInCodeWithACheckboxPerEncoding() throws {
        let panel = EncodingManager.shared.makePanel()
        XCTAssertEqual(panel.title, "Customize Encodings List")
        XCTAssertTrue(panel.worksWhenModal)
        let table = try XCTUnwrap(panel.contentView?.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, EncodingManager.allAvailableEncodings.count)
        XCTAssertGreaterThan(table.numberOfRows, 50)
        XCTAssertEqual(EncodingManager.allAvailableEncodings.first.map { String.localizedName(of: $0) }?.hasPrefix("Unicode"), true,
                       "Unicode encodings sort first")
        let buttons = panel.contentView?.subviews.compactMap { ($0 as? NSButton)?.title }
        XCTAssertEqual(buttons, ["Select all", "Clear all", "Revert to default"])
        // A checkbox click turns that encoding off in the list.
        let utf8Row = try XCTUnwrap(EncodingManager.allAvailableEncodings.firstIndex(of: .utf8))
        table.scrollRowToVisible(utf8Row)
        let checkbox = try XCTUnwrap(table.view(atColumn: 0, row: utf8Row, makeIfNecessary: true) as? NSButton)
        XCTAssertEqual(checkbox.state, .on)
        checkbox.performClick(nil)
        XCTAssertFalse(EncodingManager.enabledEncodings().contains(.utf8))
        EncodingManager.shared.revertToDefault()
    }

    // MARK: n2 step 2: the Open panel

    func testOpenPanelStartsAtThePlainTextEncodingDefault() {
        Defaults.store.set(Int(String.Encoding.windowsCP1252.rawValue), forKey: DefaultsKey.plainTextEncoding.rawValue)
        XCTAssertEqual(TextDocument.defaultOpenEncoding(), .windowsCP1252)
        let popUp = EncodingPopUpButton(selected: TextDocument.defaultOpenEncoding(), includeAutomatic: true)
        XCTAssertEqual(popUp.selectedEncoding, .windowsCP1252)
    }

    func testPlainTextEncodingDefaultAppliesToOpensWithoutThePanel() throws {
        Defaults.store.set(Int(String.Encoding.windowsCP1252.rawValue), forKey: DefaultsKey.plainTextEncoding.rawValue)
        let url = try file("default.txt", Array("caf\u{E9}".utf8))
        let document = try open(url, window: false)
        XCTAssertEqual(document.format.encoding, .windowsCP1252)
        XCTAssertEqual(document.textStorage.string, "caf\u{C3}\u{A9}")
    }

    func testAutomaticInTheOpenPanelOverridesTheDefault() throws {
        Defaults.store.set(Int(String.Encoding.windowsCP1252.rawValue), forKey: DefaultsKey.plainTextEncoding.rawValue)
        let url = try file("auto.txt", Array("caf\u{E9}".utf8))
        DocumentController.setOpenPanelEncoding(nil, for: [url])
        let document = try open(url, window: false)
        XCTAssertEqual(document.format.encoding, .utf8)
    }

    // MARK: n2 step 3: the Save panel

    /// A Save panel that was never shown has no real URL; this one reports
    /// the URL a user would have picked.
    private final class ChosenURLSavePanel: NSSavePanel {
        var chosenURL: URL?
        override var url: URL? { chosenURL }
    }

    private func savePopUp(_ panel: NSSavePanel) throws -> EncodingPopUpButton {
        try XCTUnwrap(panel.accessoryView?.subviews.compactMap { $0 as? EncodingPopUpButton }.first)
    }

    func testSavePanelDisablesEncodingsThatCannotHoldTheText() throws {
        let url = try file("ru.txt", Array("Привет\n".utf8))
        let document = try open(url, window: false)
        let panel = NSSavePanel()
        XCTAssertTrue(document.prepareSavePanel(panel))
        let popUp = try savePopUp(panel)
        XCTAssertEqual(popUp.selectedEncoding, .utf8, "starts at the document's encoding")
        var enabled: [String.Encoding: Bool] = [:]
        for item in popUp.itemArray { if let e = EncodingManager.encoding(of: item) { enabled[e] = item.isEnabled } }
        XCTAssertEqual(enabled[.utf8], true)
        XCTAssertEqual(enabled[.utf16], true)
        XCTAssertEqual(enabled[.macOSRoman], false)
        XCTAssertEqual(enabled[.windowsCP1252], false)
        XCTAssertEqual(enabled[EncodingManager.fromCF(.shiftJIS)], true, "Shift JIS has Cyrillic letters")
    }

    func testDisableCheckIsSkippedForLargeTexts() {
        let popUp = EncodingPopUpButton(selected: .utf8, includeAutomatic: false)
        let big = String(repeating: "Привет ", count: 5_000_000 / popUp.numberOfItems / 7 + 1)
        TextDocument.disableUnfitItems(in: popUp, text: big)
        let encodingItems = popUp.itemArray.filter { EncodingManager.encoding(of: $0) != nil }
        XCTAssertTrue(encodingItems.allSatisfy(\.isEnabled), "items x characters >= 5,000,000: no check")
        TextDocument.disableUnfitItems(in: popUp, text: "Привет")
        XCTAssertFalse(encodingItems.allSatisfy(\.isEnabled))
    }

    func testSavePanelStartsAtUTF8WhenTheTextNoLongerFits() throws {
        let url = try latinFile("latin.txt")
        let document = try open(url, window: false)
        XCTAssertEqual(document.format.encoding, .windowsCP1252)
        XCTAssertEqual(document.initialSaveEncoding(), .windowsCP1252)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "日本 ")
        XCTAssertEqual(document.initialSaveEncoding(), .utf8)
    }

    func testSuggestedEncodingHonorsTheWriteDefaultWhenItFits() throws {
        let document = try open(try file("ja.txt", Array("日本\n".utf8)), window: false)
        XCTAssertEqual(document.suggestedSaveEncoding(), .utf8, "no write default: UTF-8")
        Defaults.store.set(Int(String.Encoding.shiftJIS.rawValue), forKey: DefaultsKey.plainTextEncodingForWrite.rawValue)
        XCTAssertEqual(document.suggestedSaveEncoding(), .shiftJIS, "the write default holds this text")
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\u{20AC} ")
        XCTAssertEqual(document.suggestedSaveEncoding(), .utf8, "the write default no longer fits")
    }

    /// The panel's choice is written, recorded in the xattr, and becomes the
    /// document's encoding; autosave keeps using the document's encoding.
    func testSaveAsWithAChosenEncodingWritesItAndKeepsIt() async throws {
        let url = try file("change.txt", Array("caf\u{E9}\r\n".utf8))
        let document = try open(url, window: false)
        let panel = ChosenURLSavePanel()
        XCTAssertTrue(document.prepareSavePanel(panel))
        let popUp = try savePopUp(panel)
        let index = popUp.indexOfItem(withRepresentedObject: NSNumber(value: String.Encoding.windowsCP1252.rawValue))
        XCTAssertGreaterThanOrEqual(index, 0)
        popUp.selectItem(at: index)
        _ = popUp.sendAction(popUp.action, to: popUp.target)
        let out = folder.appendingPathComponent("out.txt")
        panel.chosenURL = out // as if the user picked it; NSDocument then saves to it
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: out, ofType: TextDocument.plainTextType, for: .saveAsOperation) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(error)
        XCTAssertEqual(Array(try Data(contentsOf: out)), [0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A], "Windows-1252, CRLF kept")
        XCTAssertEqual(PlainTextIO.readAttribute(of: out), "windows-1252;1280")
        XCTAssertEqual(document.format, .init(encoding: .windowsCP1252, hasBOM: false, lineEnding: .crlf))

        // A later save with no panel writes the document's (new) encoding.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\u{E8}")
        let again: Error? = await withCheckedContinuation { continuation in
            document.save(to: out, ofType: TextDocument.plainTextType, for: .saveOperation) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(again)
        XCTAssertEqual(Array(try Data(contentsOf: out)), [0xE8, 0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A])
    }

    func testAPanelThatDidNotSaveLeavesNoChoiceBehind() async throws {
        let url = try file("cancel.txt", Array("abc\n".utf8))
        let document = try open(url, window: false)
        let panel = NSSavePanel()
        XCTAssertTrue(document.prepareSavePanel(panel))
        let popUp = try savePopUp(panel)
        popUp.selectItem(at: popUp.indexOfItem(withRepresentedObject: NSNumber(value: String.Encoding.utf16.rawValue)))
        _ = popUp.sendAction(popUp.action, to: popUp.target)
        // The panel was cancelled (it never named this URL); then Cmd+S.
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: url, ofType: TextDocument.plainTextType, for: .saveOperation) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(error)
        XCTAssertEqual(Array(try Data(contentsOf: url)), Array("abc\n".utf8), "still UTF-8")
        XCTAssertEqual(document.format.encoding, .utf8)
    }

    // MARK: n2 step 4: the xattr

    func testSaveWritesTheTextEncodingAttribute() async throws {
        let url = try file("attr.txt", Array("x\n".utf8))
        let document = try open(url, window: false)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "y")
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: url, ofType: TextDocument.plainTextType, for: .saveOperation) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(error)
        XCTAssertEqual(PlainTextIO.readAttribute(of: url), "utf-8;134217984")
    }

    // MARK: n3 step 3: line endings

    func testReturnTypesTheDocumentsLineEnding() throws {
        for (name, bytes, expected) in [("crlf.txt", Array("a\r\nb\r\n".utf8), "a\r\nb\r\nX\r\n"),
                                         ("cr.txt", Array("a\rb\r".utf8), "a\rb\rX\r"),
                                         ("lf.txt", Array("a\nb\n".utf8), "a\nb\nX\n")] {
            let document = try open(try file(name, bytes))
            let textView = try textView(of: document)
            textView.setSelectedRange(NSRange(location: document.textStorage.length, length: 0))
            type("X", into: textView, of: document)
            pressReturn(in: textView, of: document)
            XCTAssertEqual(document.textStorage.string, expected, name)
        }
    }

    func testNewDocumentTypesLF() throws {
        let document = TextDocument()
        document.makeWindowControllers()
        documents.append(document)
        let textView = try textView(of: document)
        pressReturn(in: textView, of: document)
        XCTAssertEqual(document.textStorage.string, "\n")
    }

    func testPastedTextKeepsItsLineEndings() throws {
        let document = try open(try file("paste.txt", Array("a\r\n".utf8)))
        let textView = try textView(of: document)
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("QuickEditTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("one\ntwo\rthree", forType: .string)
        XCTAssertTrue(textView.readSelection(from: pasteboard, type: .string))
        pasteboard.releaseGlobally()
        XCTAssertEqual(document.textStorage.string, "a\r\none\ntwo\rthree")
    }

    // MARK: n3 step 1: the encoding no longer fits (with a fake presenter)

    final class FakePresenter: DocumentAlertPresenter {
        var encodingAnswer = false
        var savePanelSaves = false
        var lossyAnswer = LossyOverwriteChoice.cancel
        private(set) var encodingQuestions: [String] = []
        private(set) var savePanelRuns = 0
        private(set) var lossyQuestions = 0

        // Answers on the next main-queue turn, as a sheet would.
        func askToChooseAnotherEncoding(_ document: TextDocument, encodingName: String, completion: @escaping (Bool) -> Void) {
            encodingQuestions.append(encodingName)
            let answer = encodingAnswer
            DispatchQueue.main.async { completion(answer) }
        }

        func runSavePanel(_ document: TextDocument, completion: @escaping (Bool) -> Void) {
            savePanelRuns += 1
            let saves = savePanelSaves
            DispatchQueue.main.async { completion(saves) }
        }

        func askBeforeOverwritingLossyFile(_ document: TextDocument, completion: @escaping (LossyOverwriteChoice) -> Void) {
            lossyQuestions += 1
            let answer = lossyAnswer
            DispatchQueue.main.async { completion(answer) }
        }

        private(set) var reloadErrors: [Error] = []
        func presentReloadError(_ document: TextDocument, error: Error) { reloadErrors.append(error) }
    }

    private func latinDocument(_ presenter: FakePresenter) throws -> (TextDocument, NSTextView) {
        let document = try open(try latinFile("latin-\(UUID().uuidString).txt"))
        XCTAssertEqual(document.format.encoding, .windowsCP1252)
        document.alertPresenter = presenter
        let textView = try textView(of: document)
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        return (document, textView)
    }

    func testCharacterThatFitsAsksNothing() throws {
        let presenter = FakePresenter()
        let (document, textView) = try latinDocument(presenter)
        type("\u{E8}", into: textView, of: document)
        XCTAssertEqual(presenter.encodingQuestions, [])
    }

    func testCancelUndoesOnlyTheEditThatDidNotFit() async throws {
        let presenter = FakePresenter()
        let (document, textView) = try latinDocument(presenter)
        type("s", into: textView, of: document)
        type("日", into: textView, of: document)
        XCTAssertEqual(presenter.encodingQuestions, ["Western (Windows Latin 1)"])
        let undone = try await waitFor(2) { document.textStorage.string == "cafés" }
        XCTAssertTrue(undone, "text is \(document.textStorage.string.debugDescription)")
        XCTAssertEqual(presenter.savePanelRuns, 0)
    }

    func testOKOpensTheSavePanelAndASaveKeepsTheEdit() async throws {
        let presenter = FakePresenter()
        presenter.encodingAnswer = true
        presenter.savePanelSaves = true
        let (document, textView) = try latinDocument(presenter)
        type("日", into: textView, of: document)
        let ran = try await waitFor(2) { presenter.savePanelRuns == 1 }
        XCTAssertTrue(ran)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(document.textStorage.string, "café日")
    }

    func testOKThenCancellingTheSavePanelUndoes() async throws {
        let presenter = FakePresenter()
        presenter.encodingAnswer = true
        let (document, textView) = try latinDocument(presenter)
        type("日", into: textView, of: document)
        let undone = try await waitFor(2) { presenter.savePanelRuns == 1 && document.textStorage.string == "café" }
        XCTAssertTrue(undone, "text is \(document.textStorage.string.debugDescription)")
    }

    func testUntitledAndUnicodeDocumentsAreNotChecked() throws {
        let presenter = FakePresenter()
        let untitled = TextDocument()
        untitled.makeWindowControllers()
        documents.append(untitled)
        untitled.format = .init(encoding: .windowsCP1252, hasBOM: false, lineEnding: .lf)
        untitled.alertPresenter = presenter
        type("日", into: try textView(of: untitled), of: untitled)
        let utf8 = try open(try file("u.txt", Array("x".utf8)))
        utf8.alertPresenter = presenter
        type("日", into: try textView(of: utf8), of: utf8)
        XCTAssertEqual(presenter.encodingQuestions, [])
    }

    func testCheckLooksOnlyAtTheInsertedCharacters() throws {
        let url = try file("big-latin.txt", [0x63, 0x61, 0x66, 0xE9])
        let document = try open(url, window: false)
        // The document already holds a character the encoding cannot hold
        // (as after Cancel was not possible); a fitting insertion passes.
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "日")
        XCTAssertFalse(document.insertionDoesNotFit("abc"))
        XCTAssertTrue(document.insertionDoesNotFit("ab日"))
    }

    // MARK: n3 step 2: a lossily loaded file

    private func lossyDocument(_ presenter: FakePresenter) throws -> (TextDocument, URL) {
        // A fallback that cannot hold 0x81 (M6 review row 3: no longer ASCII).
        TextDocument.testHooks.withLock { $0.fallbackEncoding = .windowsCP1252 }
        let url = try file("lossy-\(UUID().uuidString).txt", EncodingFixtures.invalidEverywhere)
        let document = try open(url)
        TextDocument.testHooks.withLock { $0.fallbackEncoding = nil }
        XCTAssertTrue(document.loadedLossily)
        document.alertPresenter = presenter
        return (document, url)
    }

    func testFirstEditOfALossyFileAsksAndCancelUndoes() async throws {
        let presenter = FakePresenter()
        let (document, _) = try lossyDocument(presenter)
        let before = document.textStorage.string
        type("x", into: try textView(of: document), of: document)
        XCTAssertEqual(presenter.lossyQuestions, 1)
        let undone = try await waitFor(2) { document.textStorage.string == before }
        XCTAssertTrue(undone)
        XCTAssertTrue(document.loadedLossily)
    }

    func testOverwriteLetsTheFileBeWritten() async throws {
        let presenter = FakePresenter()
        presenter.lossyAnswer = .overwrite
        let (document, url) = try lossyDocument(presenter)
        type("x", into: try textView(of: document), of: document)
        let cleared = try await waitFor(2) { !document.loadedLossily }
        XCTAssertTrue(cleared)
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: url, ofType: TextDocument.plainTextType, for: .saveOperation) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(error)
        XCTAssertEqual(presenter.lossyQuestions, 1, "asked once")
    }

    func testDuplicateMakesACopyAndLeavesTheFileAlone() async throws {
        let presenter = FakePresenter()
        presenter.lossyAnswer = .duplicate
        let (document, url) = try lossyDocument(presenter)
        let before = document.textStorage.string
        let controller = NSDocumentController.shared
        let count = controller.documents.count
        type("x", into: try textView(of: document), of: document)
        let duplicated = try await waitFor(2) { controller.documents.count == count + 1 }
        XCTAssertTrue(duplicated)
        XCTAssertEqual(document.textStorage.string, before, "the edit is taken back in the original")
        XCTAssertEqual(Array(try Data(contentsOf: url)), EncodingFixtures.invalidEverywhere)
        for copy in controller.documents where copy !== document && copy.fileURL == nil {
            copy.updateChangeCount(.changeCleared)
            copy.close()
        }
    }

    func testSaveOverALossyFileAsksAndCancelKeepsTheBytes() async throws {
        let presenter = FakePresenter()
        let (document, url) = try lossyDocument(presenter)
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: url, ofType: TextDocument.plainTextType, for: .saveOperation) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual((error as? CocoaError)?.code, .userCancelled)
        XCTAssertEqual(presenter.lossyQuestions, 1)
        XCTAssertEqual(Array(try Data(contentsOf: url)), EncodingFixtures.invalidEverywhere)
    }

    func testRealAlertTextsMatchTextEdit() {
        let encoding = SheetAlertPresenter.encodingAlert(encodingName: "Western (Windows Latin 1)")
        XCTAssertEqual(encoding.messageText,
                       "This document can no longer be saved using its original Western (Windows Latin 1) encoding.")
        XCTAssertEqual(encoding.informativeText, "Please choose another encoding (such as UTF-8).")
        XCTAssertEqual(encoding.buttons.map(\.title), ["OK", "Cancel"])
        let lossy = SheetAlertPresenter.lossyAlert()
        XCTAssertEqual(lossy.messageText, "Are you sure you want to modify the document in place?")
        XCTAssertEqual(lossy.buttons.map(\.title), ["Duplicate", "Cancel", "Overwrite"])
    }
}
