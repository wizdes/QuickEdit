import AppKit
import XCTest
@testable import QuickEdit

/// 1.2.0: the line index behind the gutter and the document map. Its line
/// starts must match `NSString.getLineStart` (and so Select Line) for every
/// line end kind, stay right across edits that split and join CRLF pairs,
/// and scan a long gap on idle turns instead of at once.
@MainActor
final class LineIndexTests: XCTestCase {
    /// Line starts as NSString counts them, plus the empty last line after
    /// a final line end.
    private func reference(_ string: NSString) -> [Int] {
        var starts = [0]
        var location = 0
        while location < string.length {
            var end = 0, contentsEnd = 0
            string.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            if end > contentsEnd { starts.append(end) }
            if end <= location { break }
            location = end
        }
        return starts
    }

    private func allStarts(_ index: LineIndex, length: Int) -> [Int] {
        XCTAssertTrue(index.reach(length) || index.isComplete)
        var starts: [Int] = []
        var line = 0
        while let start = index.lineStart(line) { starts.append(start); line += 1 }
        return starts
    }

    func testStartsMatchNSStringForEveryLineEnd() {
        let texts = ["", "a", "a\n", "\n", "\n\n", "a\r\nb", "a\rb\r", "a\r\n\r\nb\n", "x\u{2028}y\u{2029}z\u{85}w",
                     "\r", "\r\n", "one\ntwo\r\nthree\rfour\u{2028}five\n"]
        for text in texts {
            let storage = NSTextStorage(string: text)
            let index = LineIndex(storage: storage)
            XCTAssertEqual(allStarts(index, length: storage.length), reference(storage.string as NSString), text.debugDescription)
            XCTAssertEqual(index.knownLineCount, reference(storage.string as NSString).count)
        }
    }

    func testLineContainingAnIndex() throws {
        let storage = NSTextStorage(string: "ab\ncd\r\nef\n")
        let index = LineIndex(storage: storage)
        let expected = [0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 3]
        for location in 0...storage.length {
            XCTAssertEqual(index.line(containing: location), expected[location], "at \(location)")
        }
        XCTAssertEqual(index.estimatedLineCount, 4)
    }

    /// Random edits, including ones that split or join a CR and an LF,
    /// with the index fully scanned and only partly scanned.
    func testEditsKeepTheIndexRight() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["a", "bc", "\n", "\r", "\r\n", "\u{2028}", " ", "xyz\n", ""]
        for round in 0..<40 {
            var text = (0..<60).map { _ in pieces.randomElement(using: &generator)! }.joined()
            let storage = NSTextStorage(string: text)
            let index = LineIndex(storage: storage)
            // Half the rounds scan everything first, half only a part.
            index.reach(round.isMultiple(of: 2) ? storage.length : storage.length / 3)
            for step in 0..<40 {
                let length = storage.length
                let location = Int.random(in: 0...length, using: &generator)
                let removed = Int.random(in: 0...min(3, length - location), using: &generator)
                let inserted = (0..<Int.random(in: 0...2, using: &generator))
                    .map { _ in pieces.randomElement(using: &generator)! }.joined()
                storage.replaceCharacters(in: NSRange(location: location, length: removed), with: inserted)
                let newLength = (inserted as NSString).length
                index.edit(editedRange: NSRange(location: location, length: newLength), changeInLength: newLength - removed)
                text = storage.string
                if step % 5 == 4 || step == 39 {
                    XCTAssertEqual(allStarts(index, length: storage.length), reference(storage.string as NSString),
                                   "round \(round) step \(step): \(text.debugDescription)")
                }
            }
        }
    }

    /// Typing inside one line keeps the later starts right through the
    /// pending shift, then a line end in another place applies it.
    func testTypingInsideALineThenElsewhere() {
        let storage = NSTextStorage(string: "one\ntwo\nthree\n")
        let index = LineIndex(storage: storage)
        index.reach(storage.length)
        for (offset, character) in "abc".enumerated() {
            storage.replaceCharacters(in: NSRange(location: 1 + offset, length: 0), with: String(character))
            index.edit(editedRange: NSRange(location: 1 + offset, length: 1), changeInLength: 1)
        }
        XCTAssertEqual(storage.string, "oabcne\ntwo\nthree\n")
        XCTAssertEqual(allStarts(index, length: storage.length), [0, 7, 11, 17])
        storage.replaceCharacters(in: NSRange(location: 9, length: 0), with: "\n")
        index.edit(editedRange: NSRange(location: 9, length: 1), changeInLength: 1)
        XCTAssertEqual(allStarts(index, length: storage.length), reference(storage.string as NSString))
    }

    /// A gap longer than `syncGap` is not scanned at once: the answer
    /// comes on idle turns, with `onProgress` each time.
    func testALongGapIsScannedOnIdleTurns() {
        let line = "a line of the long text\n"
        let storage = NSTextStorage(string: String(repeating: line, count: (LineIndex.syncGap * 3) / line.count))
        let index = LineIndex(storage: storage)
        var progress = 0
        index.onProgress = { progress += 1 }
        XCTAssertNil(index.line(containing: storage.length - 1), "a long gap is not scanned at once")
        XCTAssertLessThan(index.scannedTo, storage.length)
        let deadline = Date().addingTimeInterval(20)
        while !index.isComplete, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(index.isComplete)
        XCTAssertGreaterThan(progress, 0)
        XCTAssertEqual(index.line(containing: storage.length - 1), storage.length / line.count - 1)
        index.stop()
    }

    /// `edit` says whether a line start came or went, so the gutter
    /// redraws at once only then.
    func testEditReportsWhetherTheLinesChanged() {
        let storage = NSTextStorage(string: "one\ntwo\n")
        let index = LineIndex(storage: storage)
        index.reach(storage.length)
        func apply(_ range: NSRange, _ text: String) -> Bool {
            storage.replaceCharacters(in: range, with: text)
            let length = (text as NSString).length
            return index.edit(editedRange: NSRange(location: range.location, length: length),
                              changeInLength: length - range.length)
        }
        XCTAssertFalse(apply(NSRange(location: 1, length: 0), "x"), "typing inside a line")
        XCTAssertFalse(apply(NSRange(location: storage.length, length: 0), "y"), "typing at the end")
        XCTAssertTrue(apply(NSRange(location: 2, length: 0), "\n"), "a new line")
        XCTAssertTrue(apply(NSRange(location: 2, length: 1), ""), "a line end deleted")
        XCTAssertFalse(apply(NSRange(location: 0, length: 1), "Z"), "a character replaced")
        XCTAssertEqual(allStarts(index, length: storage.length), reference(storage.string as NSString))
    }

    /// While paused for a reload (the text is replaced on another
    /// thread), nothing the gutter or the map can call reads the text:
    /// not the answers, not the line count or its estimate, and not an
    /// `onProgress` that was queued just before the pause.
    func testPausedIndexReadsNoText() {
        let line = "a line of the pause test\n"
        let storage = CountingTextStorage(counting: String(repeating: line, count: 20_000))
        let index = LineIndex(storage: storage)
        var progress = 0
        index.onProgress = { progress += 1 }
        // A short scan queues onProgress for the new digit count.
        XCTAssertNotNil(index.line(containing: 10_000))
        let estimate = index.estimatedLineCount
        index.pause()
        storage.reads = 0
        storage.counting = true
        XCTAssertNil(index.line(containing: 0))
        XCTAssertNil(index.lineStart(5))
        XCTAssertTrue(index.lineStarts(in: NSRange(location: 0, length: 100)).starts.isEmpty)
        XCTAssertFalse(index.reach(50))
        XCTAssertEqual(index.estimatedLineCount, estimate, "the estimate while paused is the one from before")
        XCTAssertFalse(index.isComplete)
        _ = index.knownLineCount
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        storage.counting = false
        XCTAssertEqual(storage.reads, 0, "the paused index read the text \(storage.reads) times")
        XCTAssertEqual(progress, 0, "a queued onProgress ran while paused")
        index.resume()
        XCTAssertEqual(index.line(containing: 0), 0)
    }

    func testResetStartsAgain() {
        let storage = NSTextStorage(string: "a\nb\n")
        let index = LineIndex(storage: storage)
        index.reach(storage.length)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "x\ny\nz\nw")
        index.reset()
        XCTAssertEqual(allStarts(index, length: storage.length), [0, 2, 4, 6])
    }
}

/// A text storage that counts reads of its text while `counting` is on
/// (LineIndexTests, GutterAndMapTests).
final class CountingTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString()
    var counting = false
    var reads = 0

    override init() { super.init() }
    convenience init(counting text: String) {
        self.init()
        backing.append(NSAttributedString(string: text))
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        fatalError("not used")
    }

    override var string: String {
        if counting { reads += 1 }
        return backing.string
    }
    override var length: Int {
        if counting { reads += 1 }
        return backing.length
    }
    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        if counting { reads += 1 }
        return backing.attributes(at: location, effectiveRange: range)
    }
    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }
    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }
}
