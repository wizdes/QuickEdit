import AppKit
import XCTest
@testable import QuickEdit

/// TextDocument against real files: read, edit, write and save, byte for byte.
@MainActor
final class DocumentFileTests: XCTestCase {
    private var folder: URL!
    private let type = TextDocument.plainTextType

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickEditDocTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let folder {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try FileManager.default.removeItem(at: folder)
        }
    }

    private func file(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func append(_ text: String, to document: TextDocument) {
        let storage = document.textStorage
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: text)
        document.updateChangeCount(.changeDone)
    }

    /// The real NSDocument save operation, not a direct write.
    private func save(_ document: TextDocument, to url: URL, _ op: NSDocument.SaveOperationType) async -> Error? {
        await withCheckedContinuation { continuation in
            document.save(to: url, ofType: type, for: op) { error in
                continuation.resume(returning: error)
            }
        }
    }

    // MARK: Plan n3 step 2

    func testReadChangeWriteBytes() throws {
        let url = try file("doc.txt", Array("first\n".utf8))
        let document = try TextDocument(contentsOf: url, ofType: type)
        XCTAssertEqual(document.textStorage.string, "first\n")
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "1st")
        let out = folder.appendingPathComponent("out.txt")
        try document.write(to: out, ofType: type)
        XCTAssertEqual(try Data(contentsOf: out), Data("1st\n".utf8))
    }

    // MARK: Root item 2: document-level round trips through the real save

    private func roundTripThroughSave(name: String, bytes: [UInt8], appended: String, expected: [UInt8],
                                      format: DecodedText.Format,
                                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let url = try self.file(name, bytes)
        let document = try TextDocument(contentsOf: url, ofType: type)
        XCTAssertEqual(document.format, format, "decoded Format kept on the document", file: file, line: line)
        append(appended, to: document)
        XCTAssertTrue(document.isDocumentEdited, file: file, line: line)
        let error = await save(document, to: url, .saveOperation)
        XCTAssertNil(error, file: file, line: line)
        XCTAssertFalse(document.isDocumentEdited, file: file, line: line)
        XCTAssertEqual(Array(try Data(contentsOf: url)), expected, "bytes on disk", file: file, line: line)
        let reopened = try TextDocument(contentsOf: url, ofType: type)
        XCTAssertEqual(reopened.format, format, file: file, line: line)
        XCTAssertEqual(Array(try PlainTextIO.encode(reopened.textStorage.string, as: reopened.format)), expected,
                       file: file, line: line)
    }

    func testCRLFFileSaveKeepsCRLF() async throws {
        try await roundTripThroughSave(name: "crlf.txt", bytes: Array("a\r\nb\r\n".utf8), appended: "c\r\n",
                                       expected: Array("a\r\nb\r\nc\r\n".utf8),
                                       format: .init(encoding: .utf8, hasBOM: false, lineEnding: .crlf))
    }

    func testBOMFileSaveKeepsBOM() async throws {
        try await roundTripThroughSave(name: "bom.txt", bytes: PlainTextIO.utf8BOM + Array("x\n".utf8),
                                       appended: "y",
                                       expected: PlainTextIO.utf8BOM + Array("x\ny".utf8),
                                       format: .init(encoding: .utf8, hasBOM: true, lineEnding: .lf))
    }

    func testMixedEndingsFileSaveKeepsThem() async throws {
        try await roundTripThroughSave(name: "mixed.txt", bytes: Array("a\rb\nc\r\nd\n".utf8), appended: "e",
                                       expected: Array("a\rb\nc\r\nd\ne".utf8),
                                       format: .init(encoding: .utf8, hasBOM: false, lineEnding: .lf))
    }

    func testEmojiFileSave() async throws {
        let text = "👨‍👩‍👧‍👦 e\u{301}\n"
        try await roundTripThroughSave(name: "emoji.txt", bytes: Array(text.utf8), appended: "🇯🇵",
                                       expected: Array((text + "🇯🇵").utf8),
                                       format: .init(encoding: .utf8, hasBOM: false, lineEnding: .lf))
    }

    func testSaveIntoReadOnlyFolderFailsAndKeepsBytes() async throws {
        let original = Array("keep me\n".utf8)
        let url = try file("locked.txt", original)
        let document = try TextDocument(contentsOf: url, ofType: type)
        append("lost", to: document)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let error = await save(document, to: url, .saveOperation)
        XCTAssertNotNil(error, "a save into a read-only folder must fail")
        XCTAssertEqual(Array(try Data(contentsOf: url)), original, "original bytes untouched")
        XCTAssertTrue(document.isDocumentEdited, "document stays edited after a failed save")
        // Otherwise its autosave fires 30 s later into the deleted folder and
        // the modal error alert stops whichever test is running then.
        document.updateChangeCount(.changeCleared)
    }

    // MARK: Root item 3: async writing

    func testAsyncWritingIsOnAndBytesExact() async throws {
        let url = try file("async.txt", Array("one\n".utf8))
        let document = try TextDocument(contentsOf: url, ofType: type)
        XCTAssertTrue(document.canAsynchronouslyWrite(to: url, ofType: type, for: .saveOperation))
        XCTAssertTrue(document.canAsynchronouslyWrite(to: url, ofType: type, for: .autosaveInPlaceOperation))
        append("two\n", to: document)
        let error = await save(document, to: url, .autosaveInPlaceOperation)
        XCTAssertNil(error)
        XCTAssertEqual(try Data(contentsOf: url), Data("one\ntwo\n".utf8))
    }

    func testNewDocumentSavesUTF8WithoutBOM() async throws {
        let document = TextDocument()
        append("hi", to: document)
        let url = folder.appendingPathComponent("new.txt")
        let error = await save(document, to: url, .saveAsOperation)
        XCTAssertNil(error)
        XCTAssertEqual(try Data(contentsOf: url), Data("hi".utf8))
    }

    // MARK: Root item 6: engine check

    func testFactoryMakesTextKit1View() throws {
        let storage = NSTextStorage(string: "abc")
        let textView = TextViewFactory.makeTextView(storage: storage, size: NSSize(width: 400, height: 300))
        // Checked first: asking for layoutManager on a TextKit 2 view would switch it to TextKit 1.
        XCTAssertNil(textView.textLayoutManager, "must be a TextKit 1 view")
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        XCTAssertTrue(layoutManager.allowsNonContiguousLayout)
        XCTAssertEqual(storage.layoutManagers.count, 1)
        XCTAssertTrue(storage.layoutManagers.first === layoutManager)
        XCTAssertTrue(layoutManager.textStorage === storage)
        XCTAssertEqual(layoutManager.textContainers.count, 1)
        let container = try XCTUnwrap(layoutManager.textContainers.first)
        XCTAssertTrue(textView.textContainer === container)
        XCTAssertTrue(container.textView === textView)
        XCTAssertFalse(textView.isRichText)
        XCTAssertFalse(textView.importsGraphics)
        XCTAssertTrue(textView.allowsUndo)
        XCTAssertTrue(textView.usesFindBar)
    }

    func testWindowControllerUsesDocumentStorageAndPlainFont() throws {
        let url = try file("w.txt", Array("w\n".utf8))
        let document = try TextDocument(contentsOf: url, ofType: type)
        let controller = DocumentWindowController(document: document)
        XCTAssertNil(controller.textView.textLayoutManager)
        XCTAssertTrue(controller.textView.textStorage === document.textStorage)
        let font = try XCTUnwrap(document.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font, TextViewFactory.plainFont())
        let style = try XCTUnwrap(document.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle)
        XCTAssertEqual(style.defaultTabInterval, 8 * TextViewFactory.xAdvance(of: font), accuracy: 0.001)
        controller.close()
    }
}
