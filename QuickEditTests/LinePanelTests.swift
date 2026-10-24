import AppKit
import XCTest
@testable import QuickEdit

/// M4 n2: Select Line (reference/apple/LinePanelController.m).
@MainActor
final class LinePanelTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var storages: [NSTextStorage] = []

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows = []
        storages = []
    }

    // MARK: Parsing

    func testParseAcceptsTextEditForms() {
        XCTAssertEqual(LineSpec.parse("5"), LineSpec(from: 5, to: 5, relative: 0))
        XCTAssertEqual(LineSpec.parse("10-20"), LineSpec(from: 10, to: 20, relative: 0))
        XCTAssertEqual(LineSpec.parse("  10 - 20  "), LineSpec(from: 10, to: 20, relative: 0))
        XCTAssertEqual(LineSpec.parse("7-7"), LineSpec(from: 7, to: 7, relative: 0))
        XCTAssertEqual(LineSpec.parse("+3"), LineSpec(from: 3, to: 3, relative: 1))
        XCTAssertEqual(LineSpec.parse("-3"), LineSpec(from: 3, to: 3, relative: -1))
        XCTAssertEqual(LineSpec.parse("+1-2"), LineSpec(from: 1, to: 2, relative: 1))
        XCTAssertEqual(LineSpec.parse("-2-4"), LineSpec(from: 2, to: 4, relative: -1))
        // "0" parses; the range step rejects it, as TextEdit does.
        XCTAssertEqual(LineSpec.parse("0"), LineSpec(from: 0, to: 0, relative: 0))
    }

    /// TextEdit 1.9 has no "N:M" form (only "-" makes a range), so neither does QuickEdit.
    func testParseRejectsOtherInput() {
        for bad in ["", " ", "abc", "5-3", "5x", "1:3", "1-", "-", "+", "1 2", "1-2-3"] {
            XCTAssertNil(LineSpec.parse(bad), "\"\(bad)\" should not parse")
        }
    }

    // MARK: Ranges

    private func range(_ entry: String, _ text: String, selection: NSRange = NSRange(location: 0, length: 0)) -> NSRange? {
        LineSpec.parse(entry)?.range(in: text as NSString, selection: selection)
    }

    func testLineEndingsLFCRLFCRAndMixed() {
        XCTAssertEqual(range("1", "a\nb\nc"), NSRange(location: 0, length: 2))
        XCTAssertEqual(range("2", "a\nb\nc"), NSRange(location: 2, length: 2))
        XCTAssertEqual(range("3", "a\nb\nc"), NSRange(location: 4, length: 1))
        XCTAssertEqual(range("2-3", "a\nb\nc"), NSRange(location: 2, length: 3))

        XCTAssertEqual(range("2", "a\r\nb\r\nc"), NSRange(location: 3, length: 3))
        XCTAssertEqual(range("3", "a\r\nb\r\nc"), NSRange(location: 6, length: 1))
        XCTAssertEqual(range("1-2", "a\r\nb\r\nc"), NSRange(location: 0, length: 6))

        XCTAssertEqual(range("2", "a\rb\rc"), NSRange(location: 2, length: 2))
        XCTAssertEqual(range("3", "a\rb\rc"), NSRange(location: 4, length: 1))

        // LF, CRLF, CR, U+2028, U+2029 and U+0085 end lines; a form feed does
        // not (it does not for NSString.lineRange(for:) either).
        let mixed = "a\nb\r\nc\rd\u{2028}e\u{2029}f\u{85}g\u{0C}h"
        XCTAssertEqual(range("3", mixed), NSRange(location: 5, length: 2))
        XCTAssertEqual(range("7", mixed), NSRange(location: 13, length: 3))
        XCTAssertNil(range("8", mixed))
    }

    func testLastLineWithAndWithoutTrailingNewline() {
        XCTAssertEqual(range("2", "a\nb"), NSRange(location: 2, length: 1))
        XCTAssertEqual(range("2", "a\nb\n"), NSRange(location: 2, length: 2))
        // TextEdit has no line 3 in "a\nb\n": nothing follows the last line end.
        XCTAssertNil(range("3", "a\nb\n"))
        XCTAssertEqual(range("1", "only"), NSRange(location: 0, length: 4))
    }

    func testOutOfRange() {
        XCTAssertNil(range("0", "a\nb"))
        XCTAssertNil(range("3", "a\nb"))
        XCTAssertNil(range("2-9", "a\nb"))
        XCTAssertNil(range("1", ""))
        XCTAssertNil(range("9223372036854775807", "a\nb"))
        XCTAssertNil(range("-1", "a\nb"), "no line before the first")
    }

    func testRelativeForms() {
        let text = "l1\nl2\nl3\nl4\nl5\n"
        let line3 = NSRange(location: 6, length: 0)
        XCTAssertEqual(range("+0", text, selection: line3), NSRange(location: 6, length: 3))
        XCTAssertEqual(range("+1", text, selection: line3), NSRange(location: 9, length: 3))
        XCTAssertEqual(range("+1-2", text, selection: line3), NSRange(location: 9, length: 6))
        XCTAssertEqual(range("-1", text, selection: line3), NSRange(location: 3, length: 3))
        XCTAssertEqual(range("-1-2", text, selection: line3), NSRange(location: 0, length: 6))
        XCTAssertNil(range("-3", text, selection: line3))
        XCTAssertNil(range("+3", text, selection: line3))
        // "+" counts from the end of a selection that spans lines 2 to 3.
        XCTAssertEqual(range("+1", text, selection: NSRange(location: 3, length: 6)), NSRange(location: 9, length: 3))
    }

    /// The fast scan gives the same answer as TextEdit's own loop of
    /// lineRange(for:) calls, for every entry on texts with every line end.
    func testScanMatchesTextEditLoopEverywhere() {
        let texts = ["", "x", "\n", "\r\n", "\r", "a\nb", "a\nb\n", "a\r\n\r\nb", "\n\n\n", "a\r\rb\r\n",
                     "a\nb\r\nc\rd\u{2028}e\u{2029}f\u{85}g\u{0C}h", "\r\n\r", "é\n😀\r\nz"]
        for text in texts {
            let ns = text as NSString
            let lines = 6
            var selections = [NSRange(location: 0, length: 0), NSRange(location: ns.length, length: 0)]
            if ns.length > 1 { selections.append(NSRange(location: 1, length: ns.length - 1)) }
            for relative in [0, 1, -1] {
                for from in 0...lines {
                    for to in from...lines {
                        let spec = LineSpec(from: from, to: to, relative: relative)
                        for selection in selections {
                            XCTAssertEqual(spec.range(in: ns, selection: selection),
                                           Self.textEditRange(spec, in: ns, selection: selection),
                                           "\(spec) in \(text.debugDescription) from \(selection)")
                        }
                    }
                }
            }
        }
    }

    /// A CRLF split across the scan's chunk boundary is one line end.
    func testCRLFAcrossChunkBoundary() {
        let chunk = 1 << 15
        let text = String(repeating: "x", count: chunk - 1) + "\r\n" + "y\n"
        XCTAssertEqual(range("2", text), NSRange(location: chunk + 1, length: 2))
        XCTAssertEqual(range("2", text), Self.textEditRange(LineSpec(from: 2, to: 2, relative: 0),
                                                           in: text as NSString,
                                                           selection: NSRange(location: 0, length: 0)))
    }

    /// TextEdit's getRange:inTextView:fromLineSpec:toLineSpec:relative:, line
    /// for line (reference/apple/LinePanelController.m:94-137), as the oracle.
    static func textEditRange(_ spec: LineSpec, in string: NSString, selection: NSRange) -> NSRange? {
        var location = 0
        if spec.relative != 0 {
            var current = selection
            if spec.relative > 0 { current.location = NSMaxRange(current) - (current.length > 0 ? 1 : 0) }
            var start = 0
            string.getLineStart(&start, end: nil, contentsEnd: nil, for: NSRange(location: current.location, length: 0))
            location = start
        } else if spec.from == 0 {
            return nil
        }
        if spec.relative < 0 {
            var count = 1
            while count < spec.from {
                if location == 0 { return nil }
                location = string.lineRange(for: NSRange(location: location - 1, length: 0)).location
                count += 1
            }
            let end = location
            count = spec.from
            while count <= spec.to {
                if location == 0 { return nil }
                location = string.lineRange(for: NSRange(location: location - 1, length: 0)).location
                count += 1
            }
            return NSRange(location: location, length: end - location)
        }
        let length = string.length
        var count = spec.relative == 0 ? 1 : 0
        while count < spec.from {
            if location == length { return nil }
            location = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
            count += 1
        }
        var end = location
        count = spec.from
        while count <= spec.to {
            if end == length { return nil }
            end = NSMaxRange(string.lineRange(for: NSRange(location: end, length: 0)))
            count += 1
        }
        return NSRange(location: location, length: end - location)
    }

    // MARK: Selecting in a text view

    private func makeTextView(_ text: String) -> NSTextView {
        let storage = NSTextStorage(string: text, attributes: TextViewFactory.plainTextAttributes())
        storages.append(storage)
        let size = NSSize(width: 400, height: 200)
        let textView = TextViewFactory.makeTextView(storage: storage, size: size)
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.documentView = textView
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        windows.append(window)
        return textView
    }

    func testSelectLinesSelectsInTheTextView() throws {
        let textView = makeTextView("one\ntwo\nthree\n")
        try LinePanelController.selectLines("2", in: textView)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 4))
        try LinePanelController.selectLines("1-3", in: textView)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 14))
    }

    func testErrorsUseTextEditMessages() {
        let textView = makeTextView("one\ntwo")
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        for (entry, code) in [("abc", 200), ("9", 201), ("0", 201)] {
            XCTAssertThrowsError(try LinePanelController.selectLines(entry, in: textView)) { error in
                let error = error as NSError
                XCTAssertEqual(error.domain, LinePanelController.errorDomain)
                XCTAssertEqual(error.code, code, entry)
                XCTAssertEqual(error.localizedDescription, "Invalid line specification \u{201C}\(entry)\u{201D}.")
                XCTAssertEqual(error.localizedRecoverySuggestion,
                               "Enter a line number or a range of line numbers to select.")
            }
            XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 0), "a failed entry moved the selection")
        }
        let long = String(repeating: "9", count: 120)
        XCTAssertEqual(LinePanelController.truncated(long, 100), String(repeating: "9", count: 90) + "\u{2026}")
        XCTAssertEqual(LinePanelController.truncated("12", 100), "12")
    }

    // MARK: The panel

    func testPanelIsBuiltOnFirstUseWithTextEditLayout() throws {
        let controller = LinePanelController()
        XCTAssertFalse(controller.isPanelBuilt, "the panel exists before it is used")
        let panel = try XCTUnwrap(controller.loadPanelIfNeeded() as? NSPanel)
        XCTAssertTrue(controller.loadPanelIfNeeded() === panel, "a second panel was built")
        XCTAssertTrue(controller.isPanelBuilt)
        XCTAssertEqual(panel.title, "Select Line")
        XCTAssertEqual(panel.contentRect(forFrameRect: panel.frame).size, NSSize(width: 253, height: 62))
        XCTAssertEqual(panel.styleMask, [.titled, .closable])
        // Remembers its place: restoration (as TextEdit) and the nib's autosave name.
        XCTAssertEqual(panel.identifier?.rawValue, "Line")
        XCTAssertTrue(panel.restorationClass == LinePanelController.self)
        XCTAssertTrue(panel.isRestorable)
        XCTAssertEqual(panel.frameAutosaveName, "SelectLine")

        let field = try XCTUnwrap(controller.lineField)
        XCTAssertEqual(field.placeholderString, "Line number")
        XCTAssertTrue(field.target === controller)
        XCTAssertEqual(field.action, #selector(LinePanelController.lineFieldChanged(_:)))
        XCTAssertTrue(panel.initialFirstResponder === field)
        let button = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? NSButton }.first)
        XCTAssertEqual(button.title, "Select")
        XCTAssertEqual(button.keyEquivalent, "\r")
        XCTAssertEqual(button.action, #selector(LinePanelController.selectClicked(_:)))
        panel.close()
    }

    /// Draws the panel's content offscreen, for reading without screen access.
    func testRenderPanel() throws {
        let controller = LinePanelController()
        let panel = controller.loadPanelIfNeeded()
        // The frame view draws the panel's background and title bar too.
        let content = try XCTUnwrap(panel.contentView?.superview)
        content.layoutSubtreeIfNeeded()
        content.display()
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "select-line-panel-content"
        attachment.lifetime = .keepAlways
        add(attachment)
        panel.close()
    }

    func testRestorationReturnsTheSharedPanel() {
        var restored: NSWindow?
        LinePanelController.restoreWindow(withIdentifier: LinePanelController.panelIdentifier,
                                          state: NSKeyedArchiver(requiringSecureCoding: true)) { window, _ in
            restored = window
        }
        XCTAssertNotNil(restored)
        XCTAssertTrue(restored === LinePanelController.shared.window)
    }

    // MARK: Speed

    /// 1,000,000 lines of 100 bytes: 100 MB, the size of the biggest bench
    /// fixture. Line 1,000,000 is the last line, so the scan reads it all.
    /// The 200 ms bar holds for optimized builds; the normal unit run (-Onone)
    /// only checks a loose bound and reports the number. The optimized run:
    /// xcodebuild test -configuration Debug SWIFT_OPTIMIZATION_LEVEL=-O
    ///   SWIFT_COMPILATION_MODE=wholemodule -only-testing:QuickEditTests/LinePanelTests/testSelectLineOneMillionIn100MB
    func testSelectLineOneMillionIn100MB() throws {
        let line = String(repeating: "x", count: 99) + "\n"
        let storage = NSTextStorage(string: String(repeating: line, count: 1_000_000))
        let text = storage.mutableString
        XCTAssertEqual(text.length, 100_000_000)
        let spec = try XCTUnwrap(LineSpec.parse("1000000"))
        let expected = NSRange(location: 99_999_900, length: 100)

        var times: [Double] = []
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            let range = spec.range(in: text, selection: NSRange(location: 0, length: 0))
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            XCTAssertEqual(range, expected)
        }
        times.sort()
        // Decided by how this code was compiled, not by the DEBUG flag: the
        // speed run is a Debug build with SWIFT_OPTIMIZATION_LEVEL=-O.
        let optimized = !_isDebugAssertConfiguration()
        let build = optimized ? "optimized (-O)" : "unoptimized (-Onone)"
        let limit = optimized ? 200.0 : 2_000.0
        let report = String(format: "Select Line 1,000,000 in 100 MB, %@: best %.1f ms, median %.1f ms, worst %.1f ms",
                            build, times[0], times[2], times[4])
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "select-line-timing"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThan(times[2], limit, report)

        measure(metrics: [XCTClockMetric()]) {
            _ = spec.range(in: text, selection: NSRange(location: 0, length: 0))
        }
    }
}
