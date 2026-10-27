import AppKit
import QuartzCore
import XCTest
@testable import QuickEdit

/// M8 n7: typing at the end of a 100 MB file in QuickEdit's own window.
/// Each key is timed as tk2bench times it (bench/tk2bench.swift): the edit
/// (`insertText`), then layout of the visible rect, then a display pass.
/// The window is put on screen (not key, so no keys go anywhere) because a
/// hidden window does not draw. Root's typing harness gives the real
/// numbers; this finds where the time goes.
@MainActor
final class TypingSpeedTests: XCTestCase {
    private var folder: URL!
    private var documents: [NSDocument] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-typing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    /// Short lines like bench/make-fixtures.sh's, `bytes` long.
    private func fixtureData(bytes: Int) -> Data {
        var out = Data()
        out.reserveCapacity(bytes + 80)
        var n = 0
        while out.count < bytes {
            out.append(contentsOf: String(format: "line %08d the quick brown fox jumps over the lazy dog 0123456789\n", n).utf8)
            n += 1
        }
        return out.prefix(bytes)
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
    }

    struct Run {
        var total: [Double] = []
        var edit: [Double] = []
        var layout: [Double] = []
        var display: [Double] = []
    }

    /// Types `keys` characters at the end (or, with `atStart`, the start)
    /// of a `megabytes` file, timing each as tk2bench does. Returns the samples.
    private func typeAtEnd(megabytes: Int, keys: Int, atStart: Bool = false, data: Data? = nil, at place: Int? = nil,
                           key fixedKey: String? = nil,
                           configure: ((DocumentWindowController) -> Void)? = nil) throws -> Run {
        let url = folder.appendingPathComponent("\(megabytes)mb.txt")
        try (data ?? fixtureData(bytes: megabytes * 1024 * 1024)).write(to: url)
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        document.makeWindowControllers()
        documents.append(document)
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        let window = try XCTUnwrap(controller.window)
        configure?(controller)
        window.orderFront(nil)
        let textView = controller.textView
        let length = document.textStorage.length
        textView.setSelectedRange(NSRange(location: place ?? (atStart ? 0 : length), length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        func layoutVisible() {
            guard let container = textView.textContainer else { return }
            var rect = textView.visibleRect
            rect.origin.x -= textView.textContainerOrigin.x
            rect.origin.y -= textView.textContainerOrigin.y
            controller.layoutManager.ensureLayout(forBoundingRect: rect, in: container)
        }
        func display() {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        layoutVisible()
        display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        var run = Run()
        for i in 0..<keys {
            let key = fixedKey ?? (i % 40 == 39 ? " " : String(UnicodeScalar(UInt8(97 + i % 26))))
            let t0 = DispatchTime.now().uptimeNanoseconds
            textView.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0))
            let t1 = DispatchTime.now().uptimeNanoseconds
            layoutVisible()
            let t2 = DispatchTime.now().uptimeNanoseconds
            display()
            let t3 = DispatchTime.now().uptimeNanoseconds
            run.edit.append(Double(t1 - t0) / 1e6)
            run.layout.append(Double(t2 - t1) / 1e6)
            run.display.append(Double(t3 - t2) / 1e6)
            run.total.append(Double(t3 - t0) / 1e6)
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        XCTAssertEqual(document.textStorage.length, length + keys)
        window.orderOut(nil)
        return run
    }

    private func report(_ label: String, _ run: Run) -> String {
        let slow = run.total.enumerated().filter { $0.element > 5 }
            .map { String(format: "#%d %.1f (edit %.1f display %.1f)", $0.offset, $0.element, run.edit[$0.offset], run.display[$0.offset]) }
        return "slow keys over 5 ms: \(slow); " + String(format: "%@: n=%d total p50 %.2f p95 %.2f max %.2f ms; edit p50 %.2f p95 %.2f; layout p50 %.2f p95 %.2f; "
               + "display p50 %.2f p95 %.2f; optimized: %@",
               label, run.total.count, percentile(run.total, 0.5), percentile(run.total, 0.95), run.total.max() ?? 0,
               percentile(run.edit, 0.5), percentile(run.edit, 0.95), percentile(run.layout, 0.5), percentile(run.layout, 0.95),
               percentile(run.display, 0.5), percentile(run.display, 0.95), _isDebugAssertConfiguration() ? "false" : "true")
    }

    /// Prints the 100 MB numbers (M8-N7 lines). Asserts only that every
    /// key arrived; the limit is root's (p95 at most 8 ms in its harness).
    func testTypingAtTheEndOf100MB() throws {
        let run = try typeAtEnd(megabytes: 100, keys: 200)
        print(report("M8-N7 100 MB typing at the end (large-file mode)", run))
    }

    /// 1.2.0: typing at the end of a 10 MB file, under the large-file
    /// limit, in the default view (line numbers and the document map are
    /// on there since 1.2.0). Prints an M12-TYPING line; the same file with
    /// the gutter and the map off follows, so the two can be compared.
    func testTypingAtTheEndOf10MBDefaultView() throws {
        // Line numbers are off by default since 1.2.1; this measures the
        // 1.2.0 view with them on, the slower case.
        let saved = SavedSettings()
        defer { saved.restore() }
        Defaults.store.set(true, forKey: Defaults.showLineNumbersKey)
        var gutter = false, map = false
        let run = try typeAtEnd(megabytes: 10, keys: 200) { controller in
            gutter = controller.scrollView.rulersVisible
            map = !controller.documentMap.isHidden
        }
        print(report("M12-TYPING 10 MB typing at the end, default view (gutter \(gutter), map \(map))", run))
        XCTAssertTrue(gutter, "the default view has line numbers")
        XCTAssertTrue(map, "the default view has the document map")
        if !_isDebugAssertConfiguration() {
            XCTAssertLessThanOrEqual(percentile(run.total, 0.95), 8, "10 MB typing p95 with the gutter and the map")
        }
    }

    /// Short lines just under the 50 MB large-file limit: the most line
    /// starts a window ever indexes (about 3.2 million).
    private func shortLines(bytes: Int) -> Data {
        var out = Data()
        out.reserveCapacity(bytes + 16)
        var n = 0
        while out.count + 16 <= bytes {
            out.append(contentsOf: String(format: "short %09d\n", n).utf8)
            n += 1
        }
        return out
    }

    /// 1.2.0 review item 3: Return typed near the start of a fully indexed
    /// file just under 50 MB of short lines, gutter and map on. Each key
    /// inserts a line start before about 3.2 million others. Limit in an
    /// optimized build: p95 at most 8 ms, as the other typing tests.
    func testReturnNearTheStartOf49MBIndexed() throws {
        let saved = SavedSettings()
        defer { saved.restore() }
        Defaults.store.set(true, forKey: Defaults.showLineNumbersKey)  // off by default since 1.2.1
        var starts = 0, gutter = false
        let data = shortLines(bytes: 49 * 1024 * 1024)
        let run = try typeAtEnd(megabytes: 49, keys: 200, data: data, at: 100, key: "\n") { controller in
            controller.lineIndex.scanAll()
            starts = controller.lineIndex.knownLineCount
            gutter = controller.scrollView.rulersVisible && !controller.documentMap.isHidden
        }
        print(report("M12-RETURN 49 MB of short lines, Return near the start, fully indexed (\(starts) line starts, gutter and map \(gutter))", run))
        XCTAssertTrue(gutter, "the gutter and the map must be on")
        XCTAssertGreaterThan(starts, 3_000_000)
        if !_isDebugAssertConfiguration() {
            XCTAssertLessThanOrEqual(percentile(run.total, 0.95), 8, "Return near the start of 49 MB p95")
        }
    }

    /// 1.2.0 review item 3: pasting 10 MB of lines into an empty document,
    /// gutter and map on: the edit, layout of the visible part and one
    /// display, three times in fresh windows. Limit in an optimized build:
    /// at most 200 ms, the main-thread limit of the large-file tests.
    func testPasting10MBIntoAnEmptyDocument() throws {
        let saved = SavedSettings()
        defer { saved.restore() }
        Defaults.store.set(true, forKey: Defaults.showLineNumbersKey)  // off by default since 1.2.1
        let text = String(decoding: fixtureData(bytes: 10 * 1024 * 1024), as: UTF8.self)
        var totals: [Double] = [], edits: [Double] = []
        for _ in 0..<3 {
            let document = TextDocument()
            document.makeWindowControllers()
            documents.append(document)
            let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
            let window = try XCTUnwrap(controller.window)
            window.orderFront(nil)
            window.displayIfNeeded()
            XCTAssertTrue(controller.scrollView.rulersVisible && !controller.documentMap.isHidden)
            let t0 = DispatchTime.now().uptimeNanoseconds
            controller.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            let t1 = DispatchTime.now().uptimeNanoseconds
            window.layoutIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            let t2 = DispatchTime.now().uptimeNanoseconds
            edits.append(Double(t1 - t0) / 1e6)
            totals.append(Double(t2 - t0) / 1e6)
            window.orderOut(nil)
        }
        print(String(format: "M12-PASTE 10 MB into an empty document: total %.1f / %.1f / %.1f ms; edit %.1f / %.1f / %.1f ms; optimized: %@",
                     totals[0], totals[1], totals[2], edits[0], edits[1], edits[2],
                     _isDebugAssertConfiguration() ? "false" : "true"))
        if !_isDebugAssertConfiguration() {
            XCTAssertLessThanOrEqual(totals.max() ?? 0, 200, "10 MB paste with the gutter and the map")
        }
    }

    /// The same with the gutter and the map off, to compare.
    func testTypingAtTheEndOf10MBGutterAndMapOff() throws {
        let saved = SavedSettings()
        defer { saved.restore() }
        Defaults.store.set(false, forKey: Defaults.showLineNumbersKey)
        Defaults.store.set(false, forKey: Defaults.showDocumentMapKey)
        let run = try typeAtEnd(megabytes: 10, keys: 200)
        print(report("M12-TYPING 10 MB typing at the end, gutter and map off", run))
    }

    /// M8 review row 3: in Wrap to Page each key starts the idle layout
    /// again from the edit point. Typing at the start of 100 MB, with that
    /// idle work running between keys, holds the n7 limit: p95 at most
    /// 8 ms in an optimized build.
    func testWrapToPageTypingAtTheStartOf100MB() throws {
        var pages = 0
        let run = try typeAtEnd(megabytes: 100, keys: 200, atStart: true) { controller in
            (controller.document as? TextDocument)?.hasMultiplePages = true
            pages = controller.numberOfPages
        }
        let p95 = percentile(run.total, 0.95)
        print(report("M8-N7 100 MB Wrap to Page typing at the start (\(pages) pages at the switch)", run))
        XCTAssertGreaterThan(pages, 0)
        if !_isDebugAssertConfiguration() {
            XCTAssertLessThanOrEqual(p95, 8, "Wrap to Page typing p95 \(p95) ms at the start of 100 MB")
        }
    }

    /// The same with large-file mode off and spelling on (the registered
    /// default), to show what the mode changes. Only when
    /// TEST_RUNNER_QE_M8_TYPING_MATRIX is set.
    func testTypingMatrix() throws {
        guard ProcessInfo.processInfo.environment["QE_M8_TYPING_MATRIX"] != nil else { return }
        let saved = SavedSettings()
        defer { saved.restore() }
        let threshold = TextDocument.largeFileThreshold
        defer { TextDocument.largeFileThreshold = threshold }
        TextDocument.largeFileThreshold = Int.max
        Defaults.store.set(true, forKey: DefaultsKey.checkSpellingWhileTyping.rawValue)
        print(report("M8-N7 100 MB typing at the end, checks on (spelling on)", try typeAtEnd(megabytes: 100, keys: 200)))
        print(report("M8-N7 1 MB typing at the end, checks on (spelling on)", try typeAtEnd(megabytes: 1, keys: 200)))
        Defaults.store.set(false, forKey: DefaultsKey.checkSpellingWhileTyping.rawValue)
        print(report("M8-N7 100 MB typing at the end, spelling off", try typeAtEnd(megabytes: 100, keys: 200)))
    }
}
