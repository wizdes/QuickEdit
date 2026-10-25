import AppKit
import XCTest
@testable import QuickEdit

/// M8 n2: the open path. Large files open with the checks that slow typing
/// turned off, and say so in the window title; the read maps the file
/// instead of copying it. Measurements for the M8 report print as
/// M8-N2 lines.
@MainActor
final class OpenPathTests: XCTestCase {
    private var folder: URL!
    private var documents: [NSDocument] = []
    private var saved: SavedSettings!
    private var savedThreshold = 0

    override func setUp() async throws {
        saved = SavedSettings()
        savedThreshold = TextDocument.largeFileThreshold
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        TextDocument.largeFileThreshold = savedThreshold
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        saved.restore()
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    private func open(_ data: Data, name: String) throws -> (TextDocument, DocumentWindowController) {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        document.makeWindowControllers()
        documents.append(document)
        return (document, try XCTUnwrap(document.windowControllers.first as? DocumentWindowController))
    }

    /// Every check this mode turns off, on.
    private func turnEveryCheckOn() {
        for key: DefaultsKey in [.checkSpellingWhileTyping, .checkGrammarWithSpelling, .correctSpellingAutomatically,
                                 .smartQuotes, .smartDashes, .dataDetectors, .textReplacement] {
            Defaults.store.set(true, forKey: key.rawValue)
        }
    }

    private func checks(_ view: NSTextView) -> [Bool] {
        [view.isContinuousSpellCheckingEnabled, view.isGrammarCheckingEnabled, view.isAutomaticSpellingCorrectionEnabled,
         view.isAutomaticQuoteSubstitutionEnabled, view.isAutomaticDashSubstitutionEnabled,
         view.isAutomaticDataDetectionEnabled, view.isAutomaticTextReplacementEnabled]
    }

    func testLargeFileTurnsTheChecksOffAndSaysSo() throws {
        turnEveryCheckOn()
        TextDocument.largeFileThreshold = 1_000
        let (document, controller) = try open(Data(String(repeating: "large file line\n", count: 100).utf8), name: "big.txt")
        XCTAssertTrue(document.isLargeFile)
        XCTAssertEqual(checks(controller.textView), [false, false, false, false, false, false, false])
        let title = try XCTUnwrap(controller.window?.title)
        XCTAssertEqual(title, "big.txt \u{2014} " + DocumentWindowController.largeFileTitleNote)
        // Settings are not changed by it.
        XCTAssertTrue(Defaults.bool(.checkSpellingWhileTyping))
        // Wrap to Page and back keeps them off (the first view is made again).
        document.togglePageBreaks(nil)
        XCTAssertEqual(checks(controller.textView), [false, false, false, false, false, false, false])
        document.togglePageBreaks(nil)
        XCTAssertEqual(checks(controller.textView), [false, false, false, false, false, false, false])
        // The user can still turn spelling on for this window.
        controller.textView.toggleContinuousSpellChecking(nil)
        XCTAssertTrue(controller.textView.isContinuousSpellCheckingEnabled)
    }

    func testFileAtTheLimitKeepsTheSettings() throws {
        turnEveryCheckOn()
        let text = Data(String(repeating: "small file line\n", count: 100).utf8)
        TextDocument.largeFileThreshold = text.count
        let (document, controller) = try open(text, name: "small.txt")
        XCTAssertFalse(document.isLargeFile)
        XCTAssertEqual(checks(controller.textView), [true, true, true, true, true, true, true])
        XCTAssertEqual(controller.window?.title, "small.txt")
    }

    /// The default limit is 50 MB of file bytes (the M8 brief's start).
    func testDefaultLimitIsFiftyMegabytes() {
        XCTAssertEqual(savedThreshold, 50 * 1024 * 1024)
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

    nonisolated private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// The open path for one file, as AppKit runs it: the read on a
    /// background thread (`canConcurrentlyReadDocuments`), then on the main
    /// thread the window, its first display and a first keystroke. Peak
    /// footprint is sampled every millisecond on another thread.
    /// Returns a report line.
    private func measureOpen(_ url: URL, label: String) throws -> String {
        nonisolated(unsafe) var peak = Self.footprintMB()
        let base = peak
        let sampling = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        sampling.schedule(deadline: .now(), repeating: .milliseconds(1))
        sampling.setEventHandler { @Sendable in peak = max(peak, Self.footprintMB()) }
        sampling.resume()
        let start = DispatchTime.now().uptimeNanoseconds
        nonisolated(unsafe) var opened: TextDocument?
        nonisolated(unsafe) var failure: Error?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                opened = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
            } catch {
                failure = error
            }
            done.signal()
        }
        done.wait()
        let read = DispatchTime.now().uptimeNanoseconds
        if let failure { throw failure }
        let document = try XCTUnwrap(opened)
        documents.append(document)
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        let content = try XCTUnwrap(controller.window?.contentView)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let shown = DispatchTime.now().uptimeNanoseconds
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.textView.insertText("x", replacementRange: controller.textView.selectedRange())
        content.cacheDisplay(in: content.bounds, to: rep)
        let typed = DispatchTime.now().uptimeNanoseconds
        let afterOpen = Self.footprintMB()
        // Then 3 s of idle: the longest main-thread gap between 10 ms ticks.
        var gaps: [Double] = []
        var last = DispatchTime.now().uptimeNanoseconds
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            let now = DispatchTime.now().uptimeNanoseconds
            gaps.append(Double(now - last) / 1e6)
            last = now
        }
        RunLoop.current.add(timer, forMode: .default)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        timer.invalidate()
        // Then jump to the end and type a key there.
        let textView = controller.textView
        let jumpStart = DispatchTime.now().uptimeNanoseconds
        let end = NSRange(location: document.textStorage.length, length: 0)
        textView.setSelectedRange(end)
        textView.scrollRangeToVisible(end)
        content.cacheDisplay(in: content.bounds, to: rep)
        let jumped = DispatchTime.now().uptimeNanoseconds
        textView.insertText("y", replacementRange: textView.selectedRange())
        content.cacheDisplay(in: content.bounds, to: rep)
        let typedAtEnd = DispatchTime.now().uptimeNanoseconds
        sampling.cancel()
        let after = Self.footprintMB()
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return String(format: "M8-N2 open %@ (%.1f MB file): usable %.0f ms (read+decode %.0f ms off the main thread; "
                      + "main thread: window and first display %.0f ms, first key %.0f ms); "
                      + "longest main-thread gap in 3 s idle after %.1f ms; jump to end %.0f ms, key at end %.0f ms; "
                      + "peak footprint +%.0f MB, after open +%.0f MB, at the end +%.0f MB; %@; large-file mode %@; optimized: %@",
                      label, Double(bytes) / 1_048_576, Double(typed - start) / 1e6, Double(read - start) / 1e6,
                      Double(shown - read) / 1e6, Double(typed - shown) / 1e6, gaps.max() ?? 0,
                      Double(jumped - jumpStart) / 1e6, Double(typedAtEnd - jumped) / 1e6,
                      peak - base, afterOpen - base, after - base, Self.systemMemory(),
                      document.isLargeFile ? "on" : "off", _isDebugAssertConfiguration() ? "false" : "true")
    }

    /// The system's memory pressure level (1 normal, 2 warning, 4 critical)
    /// and swap in use.
    private static func systemMemory() -> String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        return String(format: "memory pressure level %d, swap used %.0f MB", level, Double(swap.xsu_used) / 1_048_576)
    }

    /// Where the read goes, step by step, for the file named by
    /// TEST_RUNNER_QE_M8_READ_BREAKDOWN (M8 n4): the mapped read, UTF-8
    /// checking into a String, the line-ending count, and filling a text
    /// storage the way `TextDocument.load` does.
    func testReadBreakdown() throws {
        guard let path = ProcessInfo.processInfo.environment["QE_M8_READ_BREAKDOWN"] else { return }
        func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }
        let base = Self.footprintMB()
        var t = DispatchTime.now().uptimeNanoseconds
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let readMs = ms(t)
        t = DispatchTime.now().uptimeNanoseconds
        let text = try XCTUnwrap(String(validating: data, as: UTF8.self))
        let validateMs = ms(t)
        let afterString = Self.footprintMB() - base
        t = DispatchTime.now().uptimeNanoseconds
        let ending = PlainTextIO.mostCommonLineEnding(in: data)
        let endingMs = ms(t)
        t = DispatchTime.now().uptimeNanoseconds
        let storage = NSTextStorage()
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0),
                                  with: NSAttributedString(string: text, attributes: TextViewFactory.plainTextAttributes()))
        storage.endEditing()
        let fillMs = ms(t)
        let afterFill = Self.footprintMB() - base
        print(String(format: "M8-N4 read breakdown %@: mapped read %.0f ms; UTF-8 check into a String %.0f ms (+%.0f MB); "
                     + "line-ending count %.0f ms (%@); storage fill %.0f ms (+%.0f MB total); %@; optimized: %@",
                     (path as NSString).lastPathComponent, readMs, validateMs, afterString, endingMs, ending.rawValue,
                     fillMs, afterFill, Self.systemMemory(), _isDebugAssertConfiguration() ? "false" : "true"))
        XCTAssertEqual(storage.length, (text as NSString).length)
    }

    /// Measurements for the report: 1, 10 and 100 MB short lines and the
    /// 10 MB long line, or the file named by TEST_RUNNER_QE_M8_OPEN_FILE.
    func testOpenMeasurements() throws {
        if let path = ProcessInfo.processInfo.environment["QE_M8_OPEN_FILE"] {
            print("M8-N2 before: " + Self.systemMemory())
            print(try measureOpen(URL(fileURLWithPath: path), label: (path as NSString).lastPathComponent))
            return
        }
        for megabytes in [1, 10, 100] {
            let url = folder.appendingPathComponent("\(megabytes)mb.txt")
            try fixtureData(bytes: megabytes * 1024 * 1024).write(to: url)
            print(try measureOpen(url, label: "\(megabytes)mb.txt"))
        }
        let long = folder.appendingPathComponent("long-line-10mb.txt")
        let unit = Data("abcdefghijklmnopqrstuvwxyz0123456789 ".utf8)
        var data = Data()
        while data.count < 10 * 1024 * 1024 { data.append(unit) }
        try data.prefix(10 * 1024 * 1024).write(to: long)
        print(try measureOpen(long, label: "long-line-10mb.txt"))
    }
}
