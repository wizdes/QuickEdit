import AppKit
import XCTest
@testable import QuickEdit

/// M8 "measurement first": the os_signpost hooks fire in order, and cost
/// under 0.1 ms in total for one launch.
@MainActor
final class SignpostTests: XCTestCase {
    private var folder: URL!
    private var documents: [NSDocument] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-signposts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Signposts.recorded.withLock { $0 = [] }
        Signposts.resetOnce()
    }

    override func tearDown() async throws {
        Signposts.recorded.withLock { $0 = nil }
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    private func recorded() -> [Signposts.Event] {
        Signposts.recorded.withLock { $0 ?? [] }
    }

    func testOpeningAFileMarksReadDecodeAndInstall() throws {
        let url = folder.appendingPathComponent("a.txt")
        try Data("hello\n".utf8).write(to: url)
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        documents.append(document)
        XCTAssertEqual(recorded(), [.readStart, .decodeEnd, .readEnd])
        document.makeWindowControllers()
        let events = recorded()
        XCTAssertEqual(Array(events.prefix(3)), [.readStart, .decodeEnd, .readEnd])
        XCTAssertTrue(events.contains(.firstWindowCreated), "\(events)")
        XCTAssertTrue(events.contains(.storageInstalled), "\(events)")
        let created = try XCTUnwrap(events.firstIndex(of: .firstWindowCreated))
        let installed = try XCTUnwrap(events.firstIndex(of: .storageInstalled))
        XCTAssertLessThan(created, installed)
    }

    func testFirstLayoutAndFirstKeyAreMarkedOnce() throws {
        let url = folder.appendingPathComponent("b.txt")
        try Data("hello\n".utf8).write(to: url)
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        documents.append(document)
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        controller.layoutManager.ensureLayout(for: controller.layoutManager.textContainers[0])
        let textView = controller.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("a", replacementRange: textView.selectedRange())
        textView.insertText("b", replacementRange: textView.selectedRange())
        let events = recorded()
        XCTAssertEqual(events.filter { $0 == .firstLayout }.count, 1, "\(events)")
        XCTAssertEqual(events.filter { $0 == .firstKeyAccepted }.count, 1, "\(events)")
    }

    /// One launch marks five events once each; their cost must stay under
    /// 0.1 ms in total. Measured over 2,000 launches' worth of calls.
    func testLaunchSignpostsCostUnderATenthOfAMillisecond() {
        Signposts.recorded.withLock { $0 = nil }
        let launch: [Signposts.Event] = [.mainStart, .menuBuilt, .firstWindowCreated, .firstLayout, .firstKeyAccepted]
        let rounds = 2_000
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<rounds {
            Signposts.resetOnce()
            for event in launch { Signposts.markOnce(event) }
        }
        let perLaunchMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(rounds)
        print(String(format: "M8-SIGNPOSTS cost per launch: %.4f ms (5 events, mean of %d)", perLaunchMs, rounds))
        XCTAssertLessThan(perLaunchMs, 0.1)
    }
}
