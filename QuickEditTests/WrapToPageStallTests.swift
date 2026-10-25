import AppKit
import XCTest
@testable import QuickEdit

/// M8 n3: after a switch to Wrap to Page, the pages are laid out in slices
/// between run-loop turns, so the main thread never blocks for long, and
/// every page still arrives.
@MainActor
final class WrapToPageStallTests: XCTestCase {
    private var folder: URL!
    private var documents: [NSDocument] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-stall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        ScalingScrollView.animatesZoom = false
    }

    override func tearDown() async throws {
        ScalingScrollView.animatesZoom = true
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    private func open(_ text: String, name: String) throws -> (TextDocument, DocumentWindowController) {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        document.makeWindowControllers()
        documents.append(document)
        return (document, try XCTUnwrap(document.windowControllers.first as? DocumentWindowController))
    }

    private func lines(_ count: Int) -> String {
        (0..<count).map { String(format: "line %05d of the stall test", $0) }.joined(separator: "\n") + "\n"
    }

    /// Runs the main run loop until `done` or `seconds` pass.
    private func runLoop(upTo seconds: Double, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func allLaidOut(_ controller: DocumentWindowController) -> Bool {
        controller.layoutManager.firstUnlaidCharacterIndex() >= (controller.layoutManager.textStorage?.length ?? 0)
    }

    /// The pages a full, synchronous layout makes: the reference count.
    private func pagesAfterFullLayout(_ text: String) throws -> Int {
        let (document, controller) = try open(text, name: "reference-\(UUID().uuidString).txt")
        document.togglePageBreaks(nil)
        controller.layOutWholeText()
        return controller.numberOfPages
    }

    func testIdleLayoutFinishesEveryPage() throws {
        let text = lines(2_000)
        let expected = try pagesAfterFullLayout(text)
        XCTAssertGreaterThan(expected, 20)
        let (document, controller) = try open(text, name: "idle.txt")
        document.togglePageBreaks(nil)
        XCTAssertLessThan(controller.numberOfPages, 5, "the switch laid out far past the first page")
        runLoop(upTo: 10) { allLaidOut(controller) }
        XCTAssertTrue(allLaidOut(controller), "idle layout did not finish in 10 s")
        XCTAssertEqual(controller.numberOfPages, expected)
        XCTAssertEqual(controller.textViews.count, expected)
    }

    func testIdleLayoutResumesAfterAnEdit() throws {
        let text = lines(1_000)
        let (document, controller) = try open(text, name: "edit.txt")
        document.togglePageBreaks(nil)
        runLoop(upTo: 10) { allLaidOut(controller) }
        let before = controller.numberOfPages
        // Paste as many lines again at the start, through the text view.
        let view = controller.textView
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText(text, replacementRange: view.selectedRange())
        runLoop(upTo: 10) { allLaidOut(controller) }
        XCTAssertTrue(allLaidOut(controller), "idle layout did not finish after the edit")
        let expected = try pagesAfterFullLayout(text + text)
        XCTAssertEqual(controller.numberOfPages, expected)
        XCTAssertGreaterThan(controller.numberOfPages, before)
    }

    /// Back to Wrap to Window: AppKit's own background layout is on again
    /// (non-contiguous layout lays out only what is shown there).
    func testWrapToWindowKeepsAppKitBackgroundLayout() throws {
        let (document, controller) = try open(lines(100), name: "modes.txt")
        XCTAssertTrue(controller.layoutManager.backgroundLayoutEnabled)
        document.togglePageBreaks(nil)
        document.togglePageBreaks(nil)
        XCTAssertTrue(controller.layoutManager.backgroundLayoutEnabled)
    }

    /// The 10 MB fixture of bench/make-fixtures.sh, made the same way.
    private func tenMegabyteText() -> String {
        let size = 10 * 1024 * 1024
        var out = ""
        out.reserveCapacity(size)
        var n = 0
        while out.utf8.count < size {
            var line = String(format: "line %08d the quick brown fox jumps over the lazy dog 0123456789\n", n)
            n += 1
            if out.utf8.count + line.utf8.count > size {
                line = String(line.prefix(size - out.utf8.count - 1)) + "\n"
            }
            out += line
        }
        return out
    }

    /// The done-test: 3 s after switching 10 MB to Wrap to Page, the
    /// longest main-thread gap between 10 ms timer ticks stays under
    /// 100 ms in an optimized build (M5 measured 340 ms; 358.5 ms on
    /// 2026-10-24 before M8). Pages must keep coming meanwhile.
    /// Measuring starts before the switch (M8 review row 8): the switch
    /// call itself is timed and held to its own limit (300 ms, as
    /// PageModeTests.testTenMegabyteSwitchTime); the first draw after it
    /// is the first gap, and the interval after the last tick is the last.
    func testTenMegabyteNoStallAfterSwitch() throws {
        let (document, controller) = try open(tenMegabyteText(), name: "10mb.txt")
        let content = try XCTUnwrap(controller.window?.contentView)
        func draw() throws {
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
        }
        try draw()
        var gaps: [Double] = []
        let switchStart = DispatchTime.now().uptimeNanoseconds
        document.togglePageBreaks(nil)
        var last = DispatchTime.now().uptimeNanoseconds
        let switchMs = Double(last - switchStart) / 1e6
        try draw()
        func tick() {
            let now = DispatchTime.now().uptimeNanoseconds
            gaps.append(Double(now - last) / 1e6)
            last = now
        }
        tick() // the first draw
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            let now = DispatchTime.now().uptimeNanoseconds
            gaps.append(Double(now - last) / 1e6)
            last = now
        }
        RunLoop.current.add(timer, forMode: .default)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        timer.invalidate()
        tick() // the interval after the last tick
        let longest = gaps.max() ?? 0
        let sorted = gaps.sorted()
        let p99 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 99 / 100)]
        let report = String(format: "M8-N3 10MB after switch to page, 3 s: longest main-thread gap %.1f ms; p99 %.1f ms; "
                            + "first draw %.1f ms; switch %.1f ms; "
                            + "gaps over 50 ms: %d; ticks %d; pages after 3 s: %d; optimized: %@",
                            longest, p99, gaps.first ?? 0, switchMs, gaps.filter { $0 > 50 }.count, gaps.count,
                            controller.numberOfPages, _isDebugAssertConfiguration() ? "false" : "true")
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "10mb-stall"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(controller.numberOfPages, 20, "idle layout added too few pages in 3 s")
        if !_isDebugAssertConfiguration() {
            XCTAssertLessThan(switchMs, 300, "the switch itself took \(switchMs) ms")
            XCTAssertLessThan(longest, 100, "the main thread blocked \(longest) ms after the switch")
        }
    }
}
