import AppKit
import XCTest
@testable import QuickEdit

/// M8, vote V3 result B (docs/decisions.md): very large files. The UTF-8
/// check reads the mapped bytes in place and the storage is filled from
/// them, with no whole-text String on the way; files above
/// `TextDocument.readOnlyThreshold` open read-only. These tests use small
/// files and a small limit; the 1 GB checks are in LargeFileSpeedTests.
@MainActor
final class LargeFileTests: XCTestCase {
    private var folder: URL!
    private var documents: [NSDocument] = []
    private var saved: SavedSettings!
    private var savedLargeThreshold = 0
    private var savedReadOnlyThreshold = 0

    override func setUp() async throws {
        saved = SavedSettings()
        savedLargeThreshold = TextDocument.largeFileThreshold
        savedReadOnlyThreshold = TextDocument.readOnlyThreshold
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-largefile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        TextDocument.largeFileThreshold = savedLargeThreshold
        TextDocument.readOnlyThreshold = savedReadOnlyThreshold
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        saved.restore()
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

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

    /// The file's identity and age: a write (atomic or not) changes one of them.
    private func stamp(_ url: URL) throws -> [String] {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileResourceIdentifierKey])
        return [String(describing: values.contentModificationDate), String(describing: values.fileResourceIdentifier)]
    }

    // MARK: 1. The UTF-8 check on the mapped bytes (no String copy)

    /// Byte sequences at every edge of the UTF-8 rules (Unicode table 3-7).
    static let utf8EdgeCases: [[UInt8]] = [
        [], [0x41], [0x7F], [0x80], [0xBF], [0xC0, 0x80], [0xC1, 0xBF], [0xC2, 0x80], [0xDF, 0xBF], [0xC2],
        [0xE0, 0x80, 0x80], [0xE0, 0x9F, 0xBF], [0xE0, 0xA0, 0x80], [0xE1, 0x80, 0x80], [0xEC, 0xBF, 0xBF],
        [0xED, 0x80, 0x80], [0xED, 0x9F, 0xBF], [0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF], [0xEE, 0x80, 0x80],
        [0xEF, 0xBF, 0xBF], [0xEF, 0xBF, 0xBE], [0xEF, 0xBB, 0xBF], [0xE1, 0x80], [0xF0, 0x80, 0x80, 0x80],
        [0xF0, 0x8F, 0xBF, 0xBF], [0xF0, 0x90, 0x80, 0x80], [0xF3, 0xBF, 0xBF, 0xBF], [0xF4, 0x8F, 0xBF, 0xBF],
        [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80], [0xF8, 0x88, 0x80, 0x80, 0x80], [0xFE], [0xFF],
        [0x61, 0xE2, 0x82, 0xAC, 0x62], [0x61, 0xE2, 0x82, 0x62], [0xF0, 0x9F, 0x98, 0x80, 0x0A],
        [0xF0, 0x9F, 0x98], Array("plain ascii line\r\n".utf8),
    ]

    /// The answer the old code gave: Swift's own strict check.
    private func oldCheck(_ bytes: [UInt8]) -> Bool { String(validating: bytes, as: UTF8.self) != nil }

    func testUTF8CheckMatchesSwiftsStrictCheckAtEveryEdge() {
        for bytes in Self.utf8EdgeCases {
            XCTAssertEqual(PlainTextIO.isValidUTF8(Data(bytes)), oldCheck(bytes), "bytes \(bytes)")
            // The same bytes inside ASCII, so the check's fast ASCII
            // stretch meets them at other offsets.
            let padded = Array(repeating: UInt8(0x61), count: 37) + bytes + Array(repeating: UInt8(0x62), count: 41)
            XCTAssertEqual(PlainTextIO.isValidUTF8(Data(padded)), oldCheck(padded), "padded bytes \(bytes)")
        }
    }

    func testUTF8CheckMatchesSwiftsStrictCheckOnRandomBytes() {
        var generator = SeededGenerator(seed: 0x51E8)
        // Bytes drawn mostly from UTF-8's lead and continuation ranges, so
        // valid and invalid sequences both occur often.
        let pool: [ClosedRange<UInt8>] = [0x20...0x7E, 0x80...0xBF, 0xC0...0xDF, 0xE0...0xEF, 0xF0...0xFF]
        var valid = 0
        for _ in 0..<5_000 {
            let count = Int.random(in: 0...24, using: &generator)
            let bytes = (0..<count).map { _ in UInt8.random(in: pool.randomElement(using: &generator)!, using: &generator) }
            let expected = oldCheck(bytes)
            if expected { valid += 1 }
            XCTAssertEqual(PlainTextIO.isValidUTF8(Data(bytes)), expected, "bytes \(bytes)")
        }
        XCTAssertGreaterThan(valid, 200, "too few valid samples: the test proves little")
    }

    /// decode gives the same result as before for every edge case: the
    /// strict UTF-8 text, or else the fallback encoding.
    func testDecodeGivesTheSameResultsAsTheStringCheck() throws {
        for bytes in Self.utf8EdgeCases + Self.utf8EdgeCases.map({ PlainTextIO.utf8BOM + $0 }) {
            let decoded = try PlainTextIO.decode(Data(bytes), fallback: .macOSRoman)
            // The old rule: a UTF-8 BOM whose body checks is taken off;
            // else the whole file as strict UTF-8; else the fallback.
            let hasBOM = bytes.starts(with: PlainTextIO.utf8BOM)
            if hasBOM, let text = String(validating: bytes.dropFirst(3), as: UTF8.self) {
                XCTAssertEqual(decoded.text, text, "bytes \(bytes)")
                XCTAssertEqual(decoded.format.encoding, .utf8)
                XCTAssertTrue(decoded.format.hasBOM)
            } else if let text = String(validating: bytes, as: UTF8.self) {
                XCTAssertEqual(decoded.text, text, "bytes \(bytes)")
                XCTAssertEqual(decoded.format.encoding, .utf8)
                XCTAssertFalse(decoded.format.hasBOM)
            } else {
                XCTAssertEqual(decoded.format.encoding, .macOSRoman, "bytes \(bytes)")
                XCTAssertEqual(decoded.text, String(data: Data(bytes), encoding: .macOSRoman))
            }
            XCTAssertFalse(decoded.lossy)
        }
    }

    /// The in-place result keeps the bytes and never makes a String: the
    /// body is the mapped data itself (no BOM), and the String a caller
    /// asks for later is the strict UTF-8 text.
    func testDecodeInPlaceKeepsTheBytesForUTF8() throws {
        let body = Array("caf\u{E9} \u{1F600}\r\nline two\r\n".utf8)
        for bom in [false, true] {
            let data = Data((bom ? PlainTextIO.utf8BOM : []) + body)
            let content = try PlainTextIO.decodeInPlace(data)
            guard case .utf8(let bytes) = content.body else { return XCTFail("UTF-8 was copied into a String") }
            XCTAssertEqual(Array(bytes), body)
            XCTAssertEqual(content.format, .init(encoding: .utf8, hasBOM: bom, lineEnding: .crlf))
            XCTAssertFalse(content.lossy)
            XCTAssertEqual(content.decodedText, try PlainTextIO.decode(data))
            XCTAssertEqual(content.decodedText.text, String(validating: body, as: UTF8.self))
        }
        // An explicit UTF-8 choice and an xattr naming UTF-8 take the same path.
        let chosen = try PlainTextIO.decodeInPlace(Data(body), preferred: .utf8)
        guard case .utf8 = chosen.body else { return XCTFail("chosen UTF-8 was copied into a String") }
        let url = try write(body, name: "xattr.txt")
        try PlainTextIO.writeAttribute(for: .utf8, to: url)
        let named = try PlainTextIO.decodeInPlace(Data(contentsOf: url), url: url)
        guard case .utf8 = named.body else { return XCTFail("xattr UTF-8 was copied into a String") }
        // Bytes that do not fit a chosen UTF-8 still throw the same error.
        XCTAssertThrowsError(try PlainTextIO.decodeInPlace(Data([0x61, 0xFF]), preferred: .utf8)) { error in
            XCTAssertEqual(error as? PlainTextIO.Error, .inapplicableEncoding(.utf8))
        }
    }

    /// The storage fill in pieces gives the same text and attributes as
    /// the old fill in one piece (AppKit's font fallback included), whatever
    /// the piece size: pieces never split a character, and a U+FEFF that
    /// starts a piece stays.
    func testStorageFillInPiecesGivesTheSameText() throws {
        let text = "a\u{FEFF}b caf\u{E9} \u{1F600}\u{1F468}\u{200D}\u{1F469} \u{4E2D}\u{6587}\r\nend\n"
        let bytes = Data(text.utf8)
        let attributes = TextViewFactory.plainTextAttributes()
        let reference = NSTextStorage()
        reference.beginEditing()
        reference.replaceCharacters(in: NSRange(location: 0, length: 0), with: NSAttributedString(string: text, attributes: attributes))
        reference.endEditing()
        for piece in 1...12 {
            let storage = NSTextStorage()
            LargeFileText.fill(storage, withUTF8: bytes, attributes: attributes, pieceBytes: piece)
            XCTAssertEqual(storage.string, text, "piece size \(piece)")
            XCTAssertTrue(storage.isEqual(to: reference), "piece size \(piece): other attributes than the old fill")
            XCTAssertEqual(storage.attributes(at: 0, effectiveRange: nil)[.font] as? NSFont, attributes[.font] as? NSFont)
        }
        let empty = NSTextStorage(string: "old")
        LargeFileText.fill(empty, withUTF8: Data(), attributes: attributes, pieceBytes: 4)
        XCTAssertEqual(empty.length, 0)
    }

    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Reading a 64 MB ASCII file needs one copy of the text (the
    /// storage's), not two: the old UTF-8 check made a whole String first,
    /// so the read peaked at about twice the file.
    func testReadMakesNoSecondCopyOfTheText() throws {
        let megabytes = 64
        let url = folder.appendingPathComponent("64mb.txt")
        try LargeFileFixtures.write(to: url, bytes: megabytes * 1024 * 1024)
        let sampler = PeakSampler()
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        let grew = sampler.stop()
        documents.append(document)
        XCTAssertEqual(document.textStorage.length, megabytes * 1024 * 1024)
        print(String(format: "M8-V3 read of %d MB: peak footprint +%.0f MB", megabytes, grew))
        XCTAssertLessThan(grew, Double(megabytes) * 1.5,
                          "the read peaked at +\(Int(grew)) MB for a \(megabytes) MB file: a second copy of the text")
    }

    // MARK: 3. Read-only above the limit

    func testDefaultReadOnlyLimitIs512Megabytes() {
        XCTAssertEqual(TextDocument.defaultReadOnlyThreshold, 512 * 1024 * 1024)
        XCTAssertEqual(savedReadOnlyThreshold, TextDocument.defaultReadOnlyThreshold)
    }

    private func readOnlyDocument(_ bytes: [UInt8], name: String = "big.txt") throws -> (TextDocument, DocumentWindowController, URL) {
        TextDocument.largeFileThreshold = 10
        TextDocument.readOnlyThreshold = 20
        XCTAssertGreaterThan(bytes.count, 20, "the test file must be over the limit")
        let url = try write(bytes, name: name)
        let (document, controller) = try open(url)
        return (document, controller, url)
    }

    private var lines: [UInt8] { Array("first line\nsecond line\nthird line\n".utf8) }

    func testFileAboveTheLimitIsReadOnlyAndSaysSo() throws {
        let (document, controller, _) = try readOnlyDocument(lines)
        XCTAssertTrue(document.isTooLargeToEdit)
        XCTAssertFalse(controller.textView.isEditable)
        XCTAssertTrue(controller.textView.isSelectable)
        let note = DocumentWindowController.readOnlyTitleNote(byteCount: lines.count)
        XCTAssertEqual(controller.window?.title, "big.txt \u{2014} " + note)
        XCTAssertTrue(note.contains("Read only"), note)
        XCTAssertTrue(note.contains("too large to edit"), note)
        XCTAssertTrue(note.contains(ByteCountFormatter.string(fromByteCount: Int64(lines.count), countStyle: .file)), note)
        XCTAssertEqual(DocumentWindowController.readOnlyTitleNote(byteCount: 1_073_741_824),
                       "Read only: file too large to edit (1.07 GB)")
        // Wrap to Page and back: every view stays read-only.
        document.togglePageBreaks(nil)
        XCTAssertTrue(controller.textViews.allSatisfy { !$0.isEditable })
        document.togglePageBreaks(nil)
        XCTAssertFalse(controller.textView.isEditable)
    }

    func testFileAtTheLimitIsEditable() throws {
        TextDocument.readOnlyThreshold = lines.count
        let (document, controller) = try open(try write(lines, name: "limit.txt"))
        XCTAssertFalse(document.isTooLargeToEdit)
        XCTAssertTrue(controller.textView.isEditable)
        XCTAssertFalse(controller.window?.title.contains("Read only") ?? true)
    }

    func testTypingChangesNothing() throws {
        let (document, controller, _) = try readOnlyDocument(lines)
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        controller.textView.deleteForward(nil)
        XCTAssertEqual(document.textStorage.string, String(decoding: lines, as: UTF8.self))
        XCTAssertFalse(document.isDocumentEdited)
    }

    func testAllowEditingCannotMakeItEditable() throws {
        let (document, controller, _) = try readOnlyDocument(lines)
        let item = NSMenuItem(title: "Prevent Editing", action: #selector(TextDocument.toggleReadOnly(_:)), keyEquivalent: "")
        XCTAssertFalse(document.validateMenuItem(item), "Allow/Prevent Editing must be off for a file too large to edit")
        XCTAssertEqual(item.title, "Allow Editing")
        document.toggleReadOnly(nil)
        XCTAssertFalse(controller.textView.isEditable)
        document.toggleReadOnly(nil)
        XCTAssertFalse(controller.textView.isEditable)
    }

    /// Edit menu items that change text are off; view, select, copy and
    /// find are on.
    func testEditingMenuItemsAreOffAndViewingItemsOn() throws {
        let (_, controller, _) = try readOnlyDocument(lines)
        let view = controller.textView
        view.setSelectedRange(NSRange(location: 0, length: 5))
        func enabled(_ action: Selector, tag: Int = 0) -> Bool {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            item.tag = tag
            return view.validateMenuItem(item)
        }
        for action in [#selector(NSText.cut(_:)), #selector(NSText.paste(_:)), #selector(NSText.delete(_:)),
                       #selector(NSResponder.uppercaseWord(_:)), #selector(NSResponder.lowercaseWord(_:)),
                       #selector(NSResponder.capitalizeWord(_:)), #selector(NSTextView.complete(_:))] {
            XCTAssertFalse(enabled(action), "\(action) is on in a read-only file")
        }
        let finder = #selector(NSTextView.performTextFinderAction(_:))
        XCTAssertFalse(enabled(finder, tag: NSTextFinder.Action.replaceAll.rawValue), "Replace All is on")
        XCTAssertFalse(enabled(finder, tag: NSTextFinder.Action.replace.rawValue), "Replace is on")
        XCTAssertTrue(enabled(#selector(NSText.copy(_:))))
        XCTAssertTrue(enabled(#selector(NSText.selectAll(_:))))
        XCTAssertTrue(enabled(finder, tag: NSTextFinder.Action.showFindInterface.rawValue))
        XCTAssertTrue(enabled(finder, tag: NSTextFinder.Action.nextMatch.rawValue))
    }

    func testCopySelectLineAndFindWork() throws {
        let (_, controller, _) = try readOnlyDocument(lines)
        let view = controller.textView
        try LinePanelController.selectLines("2", in: view)
        XCTAssertEqual((view.string as NSString).substring(with: view.selectedRange()), "second line\n")
        let board = NSPasteboard(name: NSPasteboard.Name("qe-largefile-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: board, types: view.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string), "second line\n")
        XCTAssertTrue(view.usesFindBar)
        let found = (view.string as NSString).range(of: "third")
        XCTAssertEqual(found.location, 23)
    }

    /// Save As (and Save To) write the file's own bytes: line endings,
    /// encoding and BOM as found, whatever the text would encode to.
    func testSaveAsWritesTheOriginalBytes() async throws {
        TextDocument.largeFileThreshold = 10
        TextDocument.readOnlyThreshold = 20
        // UTF-16 BE with a BOM and mixed endings; windows-1252 named by the
        // xattr; UTF-8 with a BOM; bytes that only the fallback holds.
        let utf16 = PlainTextIO.utf16BEBOM + Array("one\r\ntwo\rthree\nfour\r\n".data(using: .utf16BigEndian)!)
        let cp1252: [UInt8] = Array("price \u{80} and caf".utf8) + [0xE9, 0x0D, 0x0A] + Array("second line here\r\n".utf8)
        let utf8BOM = PlainTextIO.utf8BOM + Array("bom file with \u{E9} and\nlines\n".utf8)
        let macRoman: [UInt8] = Array("bytes ".utf8) + [0xFF, 0xFE, 0x80, 0x0D] + Array(" not UTF-8 at all\r".utf8)
        for (index, bytes) in [utf16, cp1252, utf8BOM, macRoman].enumerated() {
            let url = try write(bytes, name: "in-\(index).txt")
            if index == 1 { try PlainTextIO.writeAttribute(for: .windowsCP1252, to: url) }
            let (document, controller) = try open(url)
            XCTAssertTrue(document.isTooLargeToEdit, "file \(index)")
            XCTAssertFalse(controller.textView.isEditable)
            for operation in [NSDocument.SaveOperationType.saveToOperation, .saveAsOperation] {
                let out = folder.appendingPathComponent("out-\(index)-\(operation.rawValue).txt")
                let error = await save(document, to: out, operation)
                XCTAssertNil(error, "file \(index), operation \(operation.rawValue)")
                XCTAssertEqual(Array(try Data(contentsOf: out)), bytes, "file \(index), operation \(operation.rawValue)")
                // The copy opens again, to the same text (M8 review row 17).
                let copy = try TextDocument(contentsOf: out, ofType: TextDocument.plainTextType)
                documents.append(copy)
                XCTAssertEqual(copy.textStorage.string, document.textStorage.string, "file \(index): the copy reads differently")
            }
        }
    }

    /// The Save panel's encoding pop-up is off: Save As keeps the encoding.
    func testSavePanelEncodingIsFixed() throws {
        let (document, _, _) = try readOnlyDocument(lines)
        let panel = NSSavePanel()
        XCTAssertTrue(document.prepareSavePanel(panel))
        let popUp = try XCTUnwrap(panel.accessoryView?.subviews.compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertFalse(popUp.isEnabled)
    }

    /// Save, Revert to Saved and Browse All Versions are off; Save As,
    /// Duplicate and Export as PDF stay on.
    func testFileMenuWritesOnlyToNewFiles() throws {
        let (document, _, _) = try readOnlyDocument(lines)
        func enabled(_ action: Selector) -> Bool {
            document.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }
        XCTAssertFalse(enabled(#selector(NSDocument.save(_:))))
        XCTAssertFalse(enabled(#selector(NSDocument.revertToSaved(_:))))
        XCTAssertFalse(enabled(#selector(NSDocument.browseVersions(_:))))
        XCTAssertTrue(enabled(#selector(NSDocument.saveAs(_:))))
        XCTAssertTrue(enabled(#selector(NSDocument.saveToPDF(_:))))
        XCTAssertTrue(enabled(#selector(TextDocument.printToPDF(_:))))
    }

    /// Autosave and a save onto the file itself write nothing, even when
    /// something marked the document edited.
    func testAutosaveAndSaveDoNotWriteTheFile() async throws {
        let (document, _, url) = try readOnlyDocument(lines)
        let before = try stamp(url)
        document.updateChangeCount(.changeDone)
        for operation in [NSDocument.SaveOperationType.autosaveInPlaceOperation, .saveOperation] {
            let error = await save(document, to: url, operation)
            XCTAssertNil(error, "operation \(operation.rawValue)")
        }
        let autosaved: Error? = await withCheckedContinuation { continuation in
            document.autosave(withImplicitCancellability: false) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(autosaved)
        XCTAssertEqual(try stamp(url), before, "the file was written")
        XCTAssertEqual(Array(try Data(contentsOf: url)), lines)
    }

    /// Revert reads the file again and writes nothing.
    func testRevertDoesNotWriteTheFile() throws {
        let (document, controller, url) = try readOnlyDocument(lines)
        let before = try stamp(url)
        try document.revert(toContentsOf: url, ofType: TextDocument.plainTextType)
        XCTAssertEqual(try stamp(url), before, "revert wrote the file")
        XCTAssertFalse(controller.textView.isEditable)
        XCTAssertEqual(document.textStorage.string, String(decoding: lines, as: UTF8.self))
    }

    /// A revert to a file that is no longer above the limit makes it
    /// editable again (with Prevent Editing on before: LargeFileReviewTests,
    /// row 24).
    func testRevertToASmallFileMakesItEditable() throws {
        let (document, controller, url) = try readOnlyDocument(lines)
        try Data("short\n".utf8).write(to: url)
        try document.revert(toContentsOf: url, ofType: TextDocument.plainTextType)
        XCTAssertFalse(document.isTooLargeToEdit)
        XCTAssertTrue(controller.textView.isEditable)
        XCTAssertEqual(controller.window?.title, "big.txt")
    }

    func testExportAsPDFStillWorks() throws {
        let (document, _, _) = try readOnlyDocument(lines)
        let pdf = folder.appendingPathComponent("big.pdf")
        try document.writePDF(to: pdf, options: .init(headerAndFooter: true, wrappingToFit: true))
        let drawn = try XCTUnwrap(CGPDFDocument(pdf as CFURL))
        XCTAssertEqual(drawn.numberOfPages, 1)
    }
}

/// Short ASCII lines like bench/make-fixtures.sh's, written in pieces so a
/// big file never sits in memory.
enum LargeFileFixtures {
    static func write(to url: URL, bytes: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var block = Data()
        var n = 0
        while n < 100_000 {
            block.append(contentsOf: String(format: "line %08d the quick brown fox jumps over the lazy dog 0123456789\n", n).utf8)
            n += 1
        }
        var written = 0
        while written < bytes {
            let part = block.prefix(bytes - written)
            try handle.write(contentsOf: part)
            written += part.count
        }
    }
}

/// A small fixed-seed generator, so the random test is the same every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
