import AppKit
import XCTest
@testable import QuickEdit

/// M8 done-test 4 on real sizes: opening 1 GB (read-only) and 512 MB
/// (editable, at the limit) with no main-thread block over 200 ms and a
/// peak footprint under 1.5 GB. Each makes its file in a temp folder and
/// deletes it at once. They need about 1 GB of free disk and run only when
/// QE_BIG_FILE_TESTS is set (`./build.sh speed` sets it), so
/// `./build.sh unit` stays fast; without it they return at once.
/// QE_M8_SIZES ("256,512,1024", in MiB) runs `testOpenSizes` for the
/// limit report instead. Lines start with M8-V3.
@MainActor
final class LargeFileSpeedTests: XCTestCase {
    private var folder: URL!
    /// The document of the last run, to wait until AppKit frees it
    /// (0.5 to 3 s after close), so a run never starts with the last
    /// run's text still in memory.
    private weak var lastDocument: TextDocument?
    private weak var lastStorage: NSTextStorage?

    /// Done-test 4.
    static let blockLimitMs = 200.0
    static let peakLimitMB = 1536.0

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-bigfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    private static var enabled: Bool { ProcessInfo.processInfo.environment["QE_BIG_FILE_TESTS"] != nil }
    private static var optimized: String { _isDebugAssertConfiguration() ? "false" : "true" }

    struct Run {
        var usable, read, block, idleGap, scroll, end, key, peak, peakGrowth: Double
        /// Footprint when the run started.
        var base = 0.0
        /// Peak footprint during a Save To after the key (0: not measured).
        var savePeak = 0.0
        var readOnly: Bool
    }

    /// One open the way AppKit runs it (read on a background thread, then
    /// the window and its first display on the main thread), then 2 s of
    /// idle, a page scroll, a jump to the end, and (when editable) a key.
    private func measure(_ url: URL, measuresSave: Bool = false) throws -> Run {
        let sampler = PeakSampler()
        defer { sampler.stop() }
        let base = sampler.start
        func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
        func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(to - from) / 1e6 }

        let start = now()
        nonisolated(unsafe) var opened: TextDocument?
        nonisolated(unsafe) var failure: Error?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do { opened = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType) } catch { failure = error }
            done.signal()
        }
        done.wait()
        if let failure { throw failure }
        let document = try XCTUnwrap(opened)
        opened = nil
        lastDocument = document
        lastStorage = document.textStorage
        defer {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        let read = now()
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        let content = try XCTUnwrap(controller.window?.contentView)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let shown = now()

        var gaps: [Double] = []
        var last = now()
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            let tick = DispatchTime.now().uptimeNanoseconds
            gaps.append(Double(tick - last) / 1e6)
            last = tick
        }
        RunLoop.current.add(timer, forMode: .default)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        timer.invalidate()

        let textView = controller.textView
        let scrollStart = now()
        textView.scrollPageDown(nil)
        content.cacheDisplay(in: content.bounds, to: rep)
        let scrolled = now()
        let endRange = NSRange(location: document.textStorage.length, length: 0)
        textView.setSelectedRange(endRange)
        textView.scrollRangeToVisible(endRange)
        content.cacheDisplay(in: content.bounds, to: rep)
        let atEnd = now()
        var key = 0.0
        if textView.isEditable {
            let keyStart = now()
            textView.insertText("x", replacementRange: textView.selectedRange())
            content.cacheDisplay(in: content.bounds, to: rep)
            key = ms(keyStart, now())
        }
        var run = Run(usable: ms(start, shown), read: ms(start, read), block: ms(read, shown), idleGap: gaps.max() ?? 0,
                      scroll: ms(scrollStart, scrolled), end: ms(scrolled, atEnd), key: key,
                      peak: sampler.highest, peakGrowth: sampler.highest - base, base: base, readOnly: document.isTooLargeToEdit)
        if measuresSave {
            // What a save costs on top (the reason for read-only mode).
            let out = folder.appendingPathComponent("saved-" + url.lastPathComponent)
            var saved = false
            var saveError: Error?
            document.save(to: out, ofType: TextDocument.plainTextType, for: .saveToOperation) { error in
                saveError = error
                saved = true
            }
            while !saved { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            try? FileManager.default.removeItem(at: out)
            if let saveError { throw saveError }
            run.savePeak = sampler.highest
        }
        return run
    }

    /// The system's memory pressure level (1 normal, 2 warning, 4 critical) and swap in use.
    private static func systemMemory() -> String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        return String(format: "memory pressure level %d, swap used %.0f MB", level, Double(swap.xsu_used) / 1_048_576)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Makes the file, opens it `runs` times, deletes it, prints one line.
    private func measureSize(megabytes: Int, extraBytes: Int = 0, runs: Int = 3, measuresSave: Bool = false) throws -> [Run] {
        let url = folder.appendingPathComponent("\(megabytes)mb.txt")
        try LargeFileFixtures.write(to: url, bytes: megabytes * 1024 * 1024 + extraBytes)
        defer { try? FileManager.default.removeItem(at: url) }
        var results: [Run] = []
        for _ in 0..<runs {
            results.append(try autoreleasepool { try measure(url, measuresSave: measuresSave) })
            // Let the closed document's memory go before the next run.
            let deadline = Date().addingTimeInterval(15)
            while lastDocument != nil || lastStorage != nil, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertNil(lastDocument, "\(megabytes) MB: the closed document was not freed in 15 s")
            XCTAssertNil(lastStorage, "\(megabytes) MB: the closed document's text was not freed in 15 s")
            // Freed text stays in the footprint until malloc gives it back;
            // give it back now, so each run starts from the same base.
            malloc_zone_pressure_relief(nil, 0)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        func m(_ key: KeyPath<Run, Double>) -> Double { Self.median(results.map { $0[keyPath: key] }) }
        func all(_ key: KeyPath<Run, Double>) -> String { results.map { String(format: "%.0f", $0[keyPath: key]) }.joined(separator: "/") }
        print(String(format: "M8-V3 %d MB open, n=%d medians: usable %.0f ms (read off the main thread %.0f ms); longest main-thread block (window and first display) "
                     + "%.1f ms [%@]; longest gap in 2 s idle after %.1f ms; first scroll %.1f ms; jump to end %.1f ms; first key %.1f ms; "
                     + "peak footprint %.0f MB [%@] (+%.0f MB from [%@]); %@read-only %@ (limit %d MB); %@; optimized: %@",
                     megabytes, runs, m(\.usable), m(\.read), m(\.block), all(\.block), m(\.idleGap), m(\.scroll), m(\.end), m(\.key),
                     m(\.peak), all(\.peak), m(\.peakGrowth), all(\.base),
                     measuresSave ? String(format: "peak with a Save To %.0f MB [%@]; ", m(\.savePeak), all(\.savePeak)) : "",
                     results[0].readOnly ? "on" : "off", TextDocument.readOnlyThreshold / 1_048_576, Self.systemMemory(), Self.optimized))
        return results
    }

    private func assertWithinDoneTest4(_ results: [Run], _ label: String) {
        func m(_ key: KeyPath<Run, Double>) -> Double { Self.median(results.map { $0[keyPath: key] }) }
        for (name, key) in [("window and first display", \Run.block), ("idle", \Run.idleGap), ("first scroll", \Run.scroll),
                            ("jump to end", \Run.end), ("first key", \Run.key)] {
            XCTAssertLessThan(m(key), Self.blockLimitMs, "\(label): \(name) blocked the main thread \(Int(m(key))) ms")
        }
        XCTAssertLessThan(m(\.peak), Self.peakLimitMB, "\(label): peak footprint \(Int(m(\.peak))) MB")
    }

    func testOneGigabyteOpensReadOnlyWithinTheLimits() throws {
        guard Self.enabled else { return }
        let results = try measureSize(megabytes: 1024)
        XCTAssertTrue(results.allSatisfy(\.readOnly), "1 GB did not open read-only")
        assertWithinDoneTest4(results, "1 GB")
    }

    /// 512 MiB is at the limit, not above it: editable.
    func testHalfGigabyteOpensEditableWithinTheLimits() throws {
        guard Self.enabled else { return }
        let results = try measureSize(megabytes: 512)
        XCTAssertTrue(results.allSatisfy { !$0.readOnly }, "512 MB opened read-only")
        assertWithinDoneTest4(results, "512 MB")
    }

    /// Review rows 14, 19 and 25 at 1 GB: the clone at open, the Save
    /// panel setup, and a reload after another app changed the file, n=3.
    /// The reload must keep done-test 4: no main-thread block over 200 ms,
    /// peak footprint under 1.5 GB.
    func testOneGigabyteReloadStaysWithinTheLimits() throws {
        guard Self.enabled else { return }
        try measureReload(megabytes: 1024, rounds: 3)
    }

    /// For the limit report: QE_M8_RELOAD_SIZES="512,1024" (MiB), with
    /// QE_M8_RUNS reloads per size (default 3). Same line as the 1 GB test.
    func testReloadSizes() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sizes = environment["QE_M8_RELOAD_SIZES"] else { return }
        let runs = environment["QE_M8_RUNS"].flatMap { Int($0) } ?? 3
        for size in sizes.split(separator: ",").compactMap({ Int($0) }) {
            try measureReload(megabytes: size, rounds: runs)
        }
    }

    /// Makes the file, opens it, times the clone and the Save panel, then
    /// reloads it `rounds` times after a one-byte change; prints one line
    /// and checks done-test 4.
    private func measureReload(megabytes: Int, rounds: Int) throws {
        func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
        func ms(_ from: UInt64) -> Double { Double(now() - from) / 1e6 }
        let url = folder.appendingPathComponent("reload-\(megabytes)mb.txt")
        try LargeFileFixtures.write(to: url, bytes: megabytes * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: url) }

        var clones: [Double] = []
        for _ in 0..<3 {
            let start = now()
            let clone = LargeFileOriginal.clone(url)
            clones.append(ms(start))
            guard let kept = clone else { return XCTFail("the 1 GB file could not be cloned") }
            kept.removeFolder()
        }

        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        defer { document.close() }
        XCTAssertEqual(document.isTooLargeToEdit, megabytes * 1024 * 1024 > TextDocument.readOnlyThreshold)
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        let content = try XCTUnwrap(controller.window?.contentView)
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)

        // The Save panel setup now, and the whole-text check it skips.
        var panelSetup: [Double] = []
        for _ in 0..<3 {
            let panel = NSSavePanel() // AppKit's own cost, not timed
            let start = now()
            _ = document.prepareSavePanel(panel)
            panelSetup.append(ms(start))
        }
        let popUp = EncodingPopUpButton(selected: .utf8, includeAutomatic: false)
        // Only where the panel skips it (an editable file's panel did it above).
        var skippedCheck = 0.0
        if document.isTooLargeToEdit {
            let checkStart = now()
            TextDocument.disableUnfitItems(in: popUp, text: document.textStorage.string)
            skippedCheck = ms(checkStart)
        }

        var gaps: [Double] = [], durations: [Double] = [], peaks: [Double] = []
        for round in 0..<rounds {
            // Another app changes one byte in place.
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: UInt64(round * 4096 + 100))
            try handle.write(contentsOf: Data("#".utf8))
            try handle.close()
            let sampler = PeakSampler()
            var longest = 0.0
            var last = now()
            let timer = Timer(timeInterval: 0.005, repeats: true) { _ in
                let tick = DispatchTime.now().uptimeNanoseconds
                longest = max(longest, Double(tick - last) / 1e6)
                last = tick
            }
            RunLoop.current.add(timer, forMode: .default)
            let start = now()
            let callStart = now()
            document.reloadAfterOutsideChange()
            longest = max(longest, ms(callStart))
            while document.isReloading { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
            content.cacheDisplay(in: content.bounds, to: rep)
            durations.append(ms(start))
            timer.invalidate()
            longest = max(longest, Double(now() - last) / 1e6)
            sampler.stop()
            gaps.append(longest)
            peaks.append(sampler.highest)
            XCTAssertEqual(document.textStorage.length, megabytes * 1024 * 1024)
            XCTAssertEqual((document.textStorage.string as NSString).substring(with: NSRange(location: round * 4096 + 100, length: 1)), "#")
        }
        func list(_ values: [Double]) -> String { values.map { String(format: "%.0f", $0) }.joined(separator: "/") }
        print(String(format: "M8-V3 %d MB reload, n=%d medians: longest main-thread block %.1f ms [%@]; reload %.0f ms [%@]; "
                     + "peak footprint %.0f MB [%@]; clone at open %.1f ms [%@]; Save panel setup %.1f ms [%@] "
                     + "(the whole-text check it now skips: %.0f ms); %@; optimized: %@",
                     megabytes, rounds, Self.median(gaps), list(gaps), Self.median(durations), list(durations), Self.median(peaks), list(peaks),
                     Self.median(clones), list(clones), Self.median(panelSetup), list(panelSetup), skippedCheck,
                     Self.systemMemory(), Self.optimized))
        XCTAssertLessThan(Self.median(gaps), Self.blockLimitMs, "reload blocked the main thread")
        XCTAssertLessThan(Self.median(peaks), Self.peakLimitMB, "reload peak footprint")
        XCTAssertLessThan(Self.median(panelSetup), Self.blockLimitMs, "Save panel setup blocked the main thread")
    }

    /// For the limit report: QE_M8_SIZES="256,512,1024" (MiB). With
    /// QE_M8_LIMIT_MB the read-only limit is that many MiB for the run
    /// (to measure 1 GB editable); QE_M8_MEASURE_SAVE adds a Save To;
    /// QE_M8_RUNS sets the runs per size (default 3).
    func testOpenSizes() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let sizes = environment["QE_M8_SIZES"] else { return }
        let saved = TextDocument.readOnlyThreshold
        defer { TextDocument.readOnlyThreshold = saved }
        // QE_M8_NO_CLONE: read the file itself, as on a disk that cannot
        // clone (to compare the cost of the clone).
        let savedFail = LargeFileOriginal.failCloneForTests
        defer { LargeFileOriginal.failCloneForTests = savedFail }
        if environment["QE_M8_NO_CLONE"] != nil { LargeFileOriginal.failCloneForTests = true }
        if let limit = environment["QE_M8_LIMIT_MB"].flatMap({ Int($0) }) {
            TextDocument.readOnlyThreshold = limit * 1024 * 1024
        }
        for size in sizes.split(separator: ",").compactMap({ Int($0) }) {
            // QE_M8_RUNS=1 with one process per run gives each run a clean
            // footprint base (freed text stays counted for a while).
            let runs = environment["QE_M8_RUNS"].flatMap { Int($0) } ?? 3
            _ = try measureSize(megabytes: size, runs: runs, measuresSave: environment["QE_M8_MEASURE_SAVE"] != nil)
        }
    }
}
