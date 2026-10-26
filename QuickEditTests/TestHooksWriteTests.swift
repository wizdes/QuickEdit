import AppKit
import XCTest
@testable import QuickEdit

/// The -QETestExternalWrite hook with -QETestExternalWriteAfterCaretAtEnd
/// YES: the delay counts from the moment the file's window is open with
/// its caret at the end, so the sandbox UI test needs no guessed 40 s wait.
@MainActor
final class TestHooksWriteTests: XCTestCase {
    private var folder: URL!
    private var documents: [NSDocument] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        try FileManager.default.removeItem(at: folder)
    }

    private func contents(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    func testWriteWaitsForTheCaretAtTheEndThenComesAfterTheDelay() throws {
        let url = folder.appendingPathComponent("hook.txt")
        try Data("before\n".utf8).write(to: url)
        TestHooks.startExternalWrite(arguments: ["QuickEdit", "-QETestExternalWrite", url.path,
                                                 "-QETestExternalWriteText", "after\\n",
                                                 "-QETestExternalWriteDelay", "0.2",
                                                 "-QETestExternalWriteAfterCaretAtEnd", "YES"])
        // No window yet: no write, long past the delay.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(contents(url), "before\n", "the hook wrote before the file was open")
        XCTAssertFalse(TestHooks.hasCaretAtEnd(for: url.path))

        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        documents.append(document)
        // As the Open panel's open does: the controller knows the document.
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        // Open, caret at the start: still no write.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(contents(url), "before\n", "the hook wrote before the caret reached the end")
        XCTAssertFalse(TestHooks.hasCaretAtEnd(for: url.path))
        let textView = try XCTUnwrap((document.windowControllers.first as? DocumentWindowController)?.textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        XCTAssertTrue(TestHooks.hasCaretAtEnd(for: url.path))
        let deadline = Date().addingTimeInterval(10)
        while contents(url) != "after\n", Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(contents(url), "after\n", "the hook did not write once the window was open")
    }

    /// -QETestReadOnlyLimitBytes lowers the read-only limit for one UI
    /// test run; a bad value changes nothing.
    func testReadOnlyLimitArgumentSetsTheLimit() {
        let saved = TextDocument.readOnlyThreshold
        defer { TextDocument.readOnlyThreshold = saved }
        TextDocument.readOnlyThreshold = TextDocument.defaultReadOnlyThreshold
        TestHooks.applyReadOnlyLimit(arguments: ["QuickEdit", "-QETestReadOnlyLimitBytes", "52428800"])
        XCTAssertEqual(TextDocument.readOnlyThreshold, 52_428_800)
        for bad in ["0", "-5", "lots", String(TextDocument.defaultReadOnlyThreshold + 1)] {
            TestHooks.applyReadOnlyLimit(arguments: ["QuickEdit", "-QETestReadOnlyLimitBytes", bad])
            XCTAssertEqual(TextDocument.readOnlyThreshold, 52_428_800, bad)
        }
        TestHooks.applyReadOnlyLimit(arguments: ["QuickEdit", "-QETestReadOnlyLimitBytes"])
        XCTAssertEqual(TextDocument.readOnlyThreshold, 52_428_800)
    }
}
