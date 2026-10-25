import AppKit
import XCTest
@testable import QuickEdit

/// Fixes for the M3 + M5 code review (docs/reviews/M3-M5-code.md, rows 1-10
/// and 12-15). Each test names its row.
@MainActor
final class M35ReviewFixTests: XCTestCase {
    private typealias FakePresenter = EncodingDocumentTests.FakePresenter

    private var folder: URL!
    private var documents: [TextDocument] = []
    /// A defaults suite of this test's own (M6 review row 14).
    private var saved: SavedSettings!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickEditM35Tests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: Helpers

    private func file(_ name: String, _ bytes: [UInt8], attribute: String? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        if let attribute {
            let status = attribute.withCString { setxattr(url.path, PlainTextIO.encodingAttribute, $0, strlen($0), 0, 0) }
            XCTAssertEqual(status, 0, "setxattr")
        }
        return url
    }

    private func open(_ url: URL, window: Bool = true) throws -> TextDocument {
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        if window { document.makeWindowControllers() }
        documents.append(document)
        return document
    }

    private func controller(of document: TextDocument) throws -> DocumentWindowController {
        try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
    }

    private func save(_ document: TextDocument, to url: URL, _ operation: NSDocument.SaveOperationType) async -> Error? {
        await withCheckedContinuation { continuation in
            document.save(to: url, ofType: TextDocument.plainTextType, for: operation) { continuation.resume(returning: $0) }
        }
    }

    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Writes new bytes over the file in place (the xattr stays), as an
    /// editor that does not replace the file would.
    private func overwriteInPlace(_ url: URL, _ bytes: [UInt8]) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(bytes))
        try handle.close()
    }

    // MARK: Row 1: a decode that does not write back the same bytes is lossy

    /// cp932 (`String.Encoding.shiftJIS` is Windows-31J on macOS): FA 40 is an
    /// IBM extension that reads as U+2170 and writes back as EE EF.
    static let cp932FA40: [UInt8] = [0x61, 0xFA, 0x40, 0x0A]
    /// EUC-JP 8E E0: reads as U+FFA0, which EUC-JP cannot write.
    static let eucJP8EE0: [UInt8] = [0x61, 0x8E, 0xE0, 0x0A]
    /// ISO-2022-JP with a JIS-Roman escape: reads as "a", writes back as plain "a".
    static let iso2022JISRoman: [UInt8] = [0x1B, 0x28, 0x4A, 0x61, 0x1B, 0x28, 0x42]

    func testRow1ExplicitDecodesThatDoNotRoundTripAreLossy() throws {
        for (name, bytes, encoding) in [("cp932 FA 40", Self.cp932FA40, String.Encoding.shiftJIS),
                                        ("EUC-JP 8E E0", Self.eucJP8EE0, .japaneseEUC),
                                        ("ISO-2022-JP ESC ( J", Self.iso2022JISRoman, .iso2022JP)] {
            let decoded = try PlainTextIO.decode(Data(bytes), preferred: encoding)
            XCTAssertEqual(decoded.format.encoding, encoding, name)
            XCTAssertTrue(decoded.lossy, "\(name) does not write back the same bytes, so it must be lossy")
        }
        // Bytes that write back the same stay clean.
        let clean = try PlainTextIO.decode(Data([0x63, 0x61, 0x66, 0xE9]), preferred: .windowsCP1252)
        XCTAssertFalse(clean.lossy)
        let japanese = try PlainTextIO.decode(Data(EncodingFixtures.bytes(EncodingFixtures.japanese, .shiftJIS)),
                                              preferred: .shiftJIS)
        XCTAssertFalse(japanese.lossy)
    }

    func testRow1AttributeAndFallbackDecodesThatDoNotRoundTripAreLossy() throws {
        let url = try file("cp932-attr.txt", Self.cp932FA40, attribute: "cp932;1056")
        let byAttribute = try PlainTextIO.decode(Data(Self.cp932FA40), url: url)
        XCTAssertEqual(byAttribute.format.encoding, .shiftJIS)
        XCTAssertTrue(byAttribute.lossy, "xattr decode")
        let byFallback = try PlainTextIO.decode(Data(Self.cp932FA40), fallback: .shiftJIS)
        XCTAssertEqual(byFallback.format.encoding, .shiftJIS)
        XCTAssertTrue(byFallback.lossy, "fallback decode")
    }

    /// The Open panel's explicit cp932 choice: the document is lossy and a
    /// save over the file asks first; Cancel keeps the bytes.
    func testRow1Cp932ChoiceMarksTheDocumentLossyAndGuardsTheSave() async throws {
        let url = try file("cp932.txt", Self.cp932FA40)
        DocumentController.setOpenPanelEncoding(.shiftJIS, for: [url])
        let document = try open(url)
        XCTAssertEqual(document.format.encoding, .shiftJIS)
        XCTAssertTrue(document.loadedLossily)
        let presenter = FakePresenter()
        document.alertPresenter = presenter
        let error = await save(document, to: url, .saveOperation)
        XCTAssertEqual((error as? CocoaError)?.code, .userCancelled)
        XCTAssertEqual(presenter.lossyQuestions, 1)
        XCTAssertEqual(Array(try Data(contentsOf: url)), Self.cp932FA40, "the file is untouched")
    }

    /// The same through the xattr, and for EUC-JP and ISO-2022-JP.
    func testRow1AttributeAndOtherEncodingsGuardTheSave() async throws {
        for (name, bytes, attribute) in [("cp932-x.txt", Self.cp932FA40, "cp932;1056"),
                                         ("eucjp-x.txt", Self.eucJP8EE0, "euc-jp;2336"),
                                         ("iso2022-x.txt", Self.iso2022JISRoman, "iso-2022-jp;2080")] {
            let url = try file(name, bytes, attribute: attribute)
            let document = try open(url, window: false)
            XCTAssertTrue(document.loadedLossily, name)
            let presenter = FakePresenter()
            document.alertPresenter = presenter
            let error = await save(document, to: url, .saveOperation)
            XCTAssertEqual((error as? CocoaError)?.code, .userCancelled, name)
            XCTAssertEqual(presenter.lossyQuestions, 1, name)
            XCTAssertEqual(Array(try Data(contentsOf: url)), bytes, name)
        }
    }

    // MARK: Row 2: "Automatic" from the Open panel is kept for revert and reload

    func testRow2AutomaticChoiceSurvivesRevert() throws {
        Defaults.store.set(Int(String.Encoding.windowsCP1252.rawValue), forKey: DefaultsKey.plainTextEncoding.rawValue)
        let url = try file("auto-revert.txt", Array("caf\u{E9}\n".utf8))
        DocumentController.setOpenPanelEncoding(nil, for: [url])
        let document = try open(url)
        XCTAssertEqual(document.textStorage.string, "caf\u{E9}\n")
        try document.revert(toContentsOf: url, ofType: TextDocument.plainTextType)
        XCTAssertEqual(document.textStorage.string, "caf\u{E9}\n", "revert must read with Automatic, not the default")
        XCTAssertEqual(document.format.encoding, .utf8)
    }

    func testRow2AutomaticChoiceSurvivesAnOutsideChangeReload() async throws {
        Defaults.store.set(Int(String.Encoding.windowsCP1252.rawValue), forKey: DefaultsKey.plainTextEncoding.rawValue)
        let url = try file("auto-reload.txt", Array("caf\u{E9}\n".utf8))
        DocumentController.setOpenPanelEncoding(nil, for: [url])
        let document = try open(url)
        try Data("caf\u{E9}!\n".utf8).write(to: url)
        document.reloadAfterOutsideChange()
        _ = try await waitFor(2) { document.textStorage.string != "caf\u{E9}\n" }
        XCTAssertEqual(document.textStorage.string, "caf\u{E9}!\n", "reload must read with Automatic, not the default")
    }

    // MARK: Row 3: Save As onto the loaded file is guarded too

    func testRow3SaveAsOntoTheLossyFileAsks() async throws {
        let url = try file("saveas-lossy.txt", Self.cp932FA40, attribute: "cp932;1056")
        let document = try open(url, window: false)
        XCTAssertTrue(document.loadedLossily)
        let presenter = FakePresenter()
        document.alertPresenter = presenter
        for operation in [NSDocument.SaveOperationType.saveAsOperation, .saveToOperation] {
            let error = await save(document, to: url, operation)
            XCTAssertEqual((error as? CocoaError)?.code, .userCancelled, "operation \(operation.rawValue)")
        }
        XCTAssertEqual(presenter.lossyQuestions, 2)
        XCTAssertEqual(Array(try Data(contentsOf: url)), Self.cp932FA40)
    }

    // MARK: Row 4: reload compares UTF-16 code units

    func testRow4ReloadSeesACanonicallyEquivalentChange() async throws {
        let url = try file("nfc.txt", Array("caf\u{E9}\n".utf8))
        let document = try open(url)
        try Data("cafe\u{301}\n".utf8).write(to: url)
        document.reloadAfterOutsideChange()
        _ = try await waitFor(2) { document.textStorage.length == 6 }
        XCTAssertEqual(Array(document.textStorage.string.utf16), Array("cafe\u{301}\n".utf16))
    }

    // MARK: Row 6: Customize Encodings refills the Save pop-up with the fit check

    func testRow6NewListItemsGetTheFitCheck() throws {
        EncodingManager.shared.setEnabled([.utf8])
        let url = try file("ru-save.txt", Array("Привет\n".utf8))
        let document = try open(url, window: false)
        let panel = NSSavePanel()
        XCTAssertTrue(document.prepareSavePanel(panel))
        let popUp = try XCTUnwrap(panel.accessoryView?.subviews.compactMap { $0 as? EncodingPopUpButton }.first)
        EncodingManager.shared.setEnabled([.utf8, .macOSRoman, .windowsCP1251])
        var enabled: [String.Encoding: Bool] = [:]
        for item in popUp.itemArray { if let e = EncodingManager.encoding(of: item) { enabled[e] = item.isEnabled } }
        XCTAssertEqual(enabled[.utf8], true)
        XCTAssertEqual(enabled[.macOSRoman], false, "Mac Roman cannot hold Cyrillic")
        XCTAssertEqual(enabled[.windowsCP1251], true, "Windows Cyrillic holds it")
        EncodingManager.shared.revertToDefault()
    }

    // MARK: Row 8: a successful reload of a legacy-encoded file

    func testRow8ReloadOfAWindows1252File() async throws {
        let url = try file("latin-reload.txt", [0x63, 0x61, 0x66, 0xE9, 0x0A], attribute: "windows-1252;1280")
        let document = try open(url)
        XCTAssertEqual(document.textStorage.string, "caf\u{E9}\n")
        try overwriteInPlace(url, [0x63, 0x61, 0x66, 0xE8, 0x21, 0x0A])
        document.reloadAfterOutsideChange()
        _ = try await waitFor(2) { document.textStorage.string != "caf\u{E9}\n" }
        XCTAssertEqual(document.textStorage.string, "caf\u{E8}!\n")
        XCTAssertEqual(document.format.encoding, .windowsCP1252)
        XCTAssertFalse(document.loadedLossily)
        XCTAssertFalse(document.isDocumentEdited)
    }

    // MARK: Row 9: the Save panel's encoding applies only to the save that panel made

    /// A Save panel that was never shown has no real URL; this one reports
    /// the URL a user would have picked (or left in the panel).
    private final class ChosenURLSavePanel: NSSavePanel {
        var chosenURL: URL?
        override var url: URL? { chosenURL }
    }

    private func choose(_ encoding: String.Encoding, in panel: NSSavePanel) throws {
        let popUp = try XCTUnwrap(panel.accessoryView?.subviews.compactMap { $0 as? EncodingPopUpButton }.first)
        let index = popUp.indexOfItem(withRepresentedObject: NSNumber(value: encoding.rawValue))
        XCTAssertGreaterThanOrEqual(index, 0)
        popUp.selectItem(at: index)
        _ = popUp.sendAction(popUp.action, to: popUp.target)
    }

    /// The panel is shown, UTF-16 picked, then cancelled; its URL still names
    /// the file. The next Cmd+S writes the document's own encoding.
    func testRow9CancelledPanelDoesNotSetTheNextSave() async throws {
        let url = try file("cancelled.txt", Array("abc\n".utf8))
        let document = try open(url, window: false)
        let panel = ChosenURLSavePanel()
        panel.chosenURL = url
        document.beginSavePanelSession()
        XCTAssertTrue(document.prepareSavePanel(panel))
        try choose(.utf16, in: panel)
        document.endSavePanelSession() // the panel was cancelled
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        let error = await save(document, to: url, .saveOperation)
        XCTAssertNil(error)
        XCTAssertEqual(Array(try Data(contentsOf: url)), Array("xabc\n".utf8), "still UTF-8")
    }

    /// An autosave while the panel is up neither takes nor clears its choice.
    func testRow9AutosaveDuringThePanelKeepsThePanelChoice() async throws {
        let url = try file("autosave-during.txt", Array("caf\u{E9}\n".utf8))
        let document = try open(url, window: false)
        let panel = ChosenURLSavePanel()
        let out = folder.appendingPathComponent("autosave-out.txt")
        panel.chosenURL = out
        document.beginSavePanelSession()
        XCTAssertTrue(document.prepareSavePanel(panel))
        try choose(.windowsCP1252, in: panel)
        let autosaved = await save(document, to: url, .autosaveInPlaceOperation)
        XCTAssertNil(autosaved)
        XCTAssertEqual(Array(try Data(contentsOf: url)), Array("caf\u{E9}\n".utf8), "autosave keeps UTF-8")
        let error = await save(document, to: out, .saveAsOperation)
        document.endSavePanelSession()
        XCTAssertNil(error)
        XCTAssertEqual(Array(try Data(contentsOf: out)), [0x63, 0x61, 0x66, 0xE9, 0x0A], "the panel's Windows Latin 1")
    }

    /// The state machine alone.
    func testRow9SessionStateMachine() {
        let url = URL(fileURLWithPath: "/tmp/a.txt"), other = URL(fileURLWithPath: "/tmp/b.txt")
        var session = SavePanelSession()
        XCTAssertNil(session.encodingForSave(.saveOperation, to: url, panelURL: url), "no panel: nothing")
        session.begin()
        session.choose(.utf16)
        XCTAssertNil(session.encodingForSave(.autosaveInPlaceOperation, to: url, panelURL: url), "autosave: nothing")
        XCTAssertNil(session.encodingForSave(.saveOperation, to: other, panelURL: url), "another URL: nothing")
        XCTAssertEqual(session.encodingForSave(.saveAsOperation, to: url, panelURL: url), .utf16, "the panel's save")
        XCTAssertNil(session.encodingForSave(.saveOperation, to: url, panelURL: url), "used once")
        session.begin()
        session.choose(.utf8)
        session.end()
        session.choose(.utf16)
        XCTAssertNil(session.encodingForSave(.saveOperation, to: url, panelURL: url), "ended (cancelled): nothing")
    }

    // MARK: Row 10: the xattr is best effort, and written without an IANA name

    func testRow10AttributeFailureDoesNotFailTheSave() async throws {
        let url = try file("attr-fails.txt", Array("abc\n".utf8))
        let document = try open(url, window: false)
        TextDocument.testHooks.withLock { $0.failAttributeWrite = true }
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        let error = await save(document, to: url, .saveOperation)
        XCTAssertNil(error, "a failed xattr must not fail the save")
        XCTAssertEqual(Array(try Data(contentsOf: url)), Array("xabc\n".utf8))
    }

    func testRow10EncodingWithoutAnIANANameStillGetsAnAttribute() async throws {
        let cf = CFStringConvertNSStringEncodingToEncoding(String.Encoding.nonLossyASCII.rawValue)
        XCTAssertNil(CFStringConvertEncodingToIANACharSetName(cf), "Non-lossy ASCII has no IANA name")
        XCTAssertEqual(PlainTextIO.attributeValue(for: .nonLossyASCII), ";\(cf)")
        // A file that had another encoding's xattr: a save as Non-lossy ASCII replaces it.
        let url = try file("nonlossy.txt", Array("abc\n".utf8), attribute: "windows-1252;1280")
        let document = try open(url, window: false)
        document.format = .init(encoding: .nonLossyASCII, hasBOM: false, lineEnding: .lf)
        let error = await save(document, to: url, .saveOperation)
        XCTAssertNil(error)
        XCTAssertEqual(PlainTextIO.readAttribute(of: url), ";\(cf)")
        XCTAssertEqual(PlainTextIO.encodingNamedByAttribute(of: url), .nonLossyASCII)
        // AppKit reads the same value (probed on macOS 27.0.1: NSString usedEncoding 7).
        var used: UInt = 0
        _ = try NSString(contentsOf: url, usedEncoding: &used)
        XCTAssertEqual(used, String.Encoding.nonLossyASCII.rawValue)
    }

    // MARK: Row 12: Option-Return and insertParagraphSeparator: type the line ending

    func testRow12OtherNewlineCommandsTypeTheDocumentsLineEnding() throws {
        let document = try open(try file("crlf-cmds.txt", Array("a\r\n".utf8)))
        let textView = try controller(of: document).textView
        for command in [#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                        #selector(NSResponder.insertParagraphSeparator(_:))] {
            textView.setSelectedRange(NSRange(location: document.textStorage.length, length: 0))
            textView.doCommand(by: command)
        }
        XCTAssertEqual(document.textStorage.string, "a\r\n\r\n\r\n")
        // insertLineBreak: stays U+2028, as in AppKit.
        textView.doCommand(by: #selector(NSResponder.insertLineBreak(_:)))
        XCTAssertEqual(document.textStorage.string, "a\r\n\r\n\r\n\u{2028}")
    }

    // MARK: Row 13: added pages get the plain typing attributes

    func testRow13AddedPagesGetTypingAttributes() throws {
        let text = (0..<400).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let document = try open(try file("pages13.txt", Array(text.utf8)))
        let controller = try controller(of: document)
        document.togglePageBreaks(nil)
        controller.layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: document.textStorage.length))
        XCTAssertGreaterThan(controller.textViews.count, 1)
        let plain = TextViewFactory.plainTextAttributes()
        let font = try XCTUnwrap(plain[.font] as? NSFont)
        let style = try XCTUnwrap(plain[.paragraphStyle] as? NSParagraphStyle)
        for (index, view) in controller.textViews.enumerated() {
            XCTAssertEqual(view.typingAttributes[.font] as? NSFont, font, "page \(index + 1) font")
            XCTAssertEqual(view.defaultParagraphStyle?.defaultTabInterval, style.defaultTabInterval, "page \(index + 1) tabs")
        }
    }

    // MARK: Row 14: Replace All (many ranges) gets the encoding check

    func testRow14ReplaceAllWithAnUnencodableStringAsks() async throws {
        let url = try file("replace-all.txt", [0x61, 0x20, 0x61, 0x20, 0x61, 0x0A], attribute: "windows-1252;1280")
        let document = try open(url)
        let presenter = FakePresenter()
        document.alertPresenter = presenter
        let textView = try controller(of: document).textView
        // What a Replace All does on the text view: one multi-range check,
        // the replacements, then one didChangeText.
        let ranges = [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1), NSRange(location: 4, length: 1)]
        // Only the last replacement does not fit.
        let strings = ["b", "b", "\u{65E5}"]
        XCTAssertTrue(textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: strings))
        textView.textStorage?.beginEditing()
        for (range, string) in zip(ranges, strings).reversed() { textView.textStorage?.replaceCharacters(in: range, with: string) }
        textView.textStorage?.endEditing()
        textView.didChangeText()
        let asked = try await waitFor(2) { presenter.encodingQuestions.count == 1 }
        XCTAssertTrue(asked, "questions: \(presenter.encodingQuestions)")
    }

    // MARK: Row 15: input method composition

    func testRow15NoQuestionWhileComposingThenOneOnCommit() async throws {
        let url = try file("compose.txt", [0x61, 0x0A], attribute: "windows-1252;1280")
        let document = try open(url)
        let presenter = FakePresenter()
        document.alertPresenter = presenter
        let textView = try controller(of: document).textView
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.setMarkedText("\u{306B}", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setMarkedText("\u{306B}\u{307B}", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(presenter.encodingQuestions, [], "no question while composing")
        textView.insertText("\u{65E5}\u{672C}", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(textView.hasMarkedText())
        let asked = try await waitFor(2) { presenter.encodingQuestions.count == 1 }
        XCTAssertTrue(asked, "one question when the composition commits: \(presenter.encodingQuestions)")
    }
}
