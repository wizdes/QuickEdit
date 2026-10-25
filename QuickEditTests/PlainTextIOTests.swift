import XCTest
@testable import QuickEdit

/// Byte-for-byte round trips through PlainTextIO (contract `io-plain`).
final class PlainTextIOTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickEditTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    /// Writes `bytes` to a real file, reads it back, decodes, encodes, and
    /// checks the encoded bytes equal the file's bytes.
    @discardableResult
    private func roundTrip(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws -> DecodedText {
        let url = folder.appendingPathComponent("\(UUID().uuidString).txt")
        try Data(bytes).write(to: url)
        let onDisk = try Data(contentsOf: url)
        let decoded = try PlainTextIO.decode(onDisk)
        let encoded = try PlainTextIO.encode(decoded.text, as: decoded.format)
        let out = folder.appendingPathComponent("\(UUID().uuidString)-out.txt")
        try encoded.write(to: out)
        XCTAssertEqual(try Data(contentsOf: out), onDisk, "bytes changed in a round trip", file: file, line: line)
        return decoded
    }

    func testLF() throws {
        let decoded = try roundTrip(Array("one\ntwo\nthree\n".utf8))
        XCTAssertEqual(decoded.format, .init(encoding: .utf8, hasBOM: false, lineEnding: .lf))
        XCTAssertEqual(decoded.text, "one\ntwo\nthree\n")
    }

    func testCRLF() throws {
        let decoded = try roundTrip(Array("one\r\ntwo\r\nthree".utf8))
        XCTAssertEqual(decoded.format.lineEnding, .crlf)
        XCTAssertEqual(decoded.text.utf8.count, 15)
    }

    func testCR() throws {
        let decoded = try roundTrip(Array("one\rtwo\rthree\r".utf8))
        XCTAssertEqual(decoded.format.lineEnding, .cr)
    }

    func testMixedEndingsKeptAsFound() throws {
        let bytes = Array("a\r\nb\nc\rd\r\ne\r\n".utf8)
        let decoded = try roundTrip(bytes)
        XCTAssertEqual(Array(decoded.text.utf8), bytes, "decoded text must keep every line ending")
        XCTAssertEqual(decoded.format.lineEnding, .crlf, "CRLF is the most common ending here")
    }

    func testUTF8WithBOMKeepsBOM() throws {
        let bytes = PlainTextIO.utf8BOM + Array("bom\n".utf8)
        let decoded = try roundTrip(bytes)
        XCTAssertTrue(decoded.format.hasBOM)
        XCTAssertEqual(decoded.text, "bom\n", "the BOM is not part of the text")
        XCTAssertEqual(Array(try PlainTextIO.encode(decoded.text, as: decoded.format).prefix(3)), PlainTextIO.utf8BOM)
    }

    func testUTF8WithoutBOMGetsNoBOM() throws {
        let decoded = try roundTrip(Array("plain\n".utf8))
        XCTAssertFalse(decoded.format.hasBOM)
    }

    func testEmptyFile() throws {
        let decoded = try roundTrip([])
        XCTAssertEqual(decoded.text, "")
        XCTAssertEqual(decoded.format, .newDocument)
    }

    func testBOMOnlyFile() throws {
        let decoded = try roundTrip(PlainTextIO.utf8BOM)
        XCTAssertEqual(decoded.text, "")
        XCTAssertTrue(decoded.format.hasBOM)
    }

    func testOneMegabyteFile() throws {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(1_048_576)
        var n = 0
        while bytes.count < 1_048_576 {
            bytes += Array("line \(n) of the one megabyte fixture\n".utf8)
            n += 1
        }
        let decoded = try roundTrip(bytes)
        XCTAssertEqual(decoded.text.utf8.count, bytes.count)
    }

    func testEmojiAndCombiningMarks() throws {
        // Family emoji (ZWJ sequence), flag, skin tone, e + combining acute, Hangul jamo.
        let text = "👨‍👩‍👧‍👦 🇯🇵 👍🏽 e\u{301} \u{1100}\u{1161}\u{11A8}\n"
        let decoded = try roundTrip(Array(text.utf8))
        XCTAssertEqual(Array(decoded.text.utf8), Array(text.utf8), "no normalization")
    }

    /// M8 n2: the count over `Data` (one pass over raw bytes) gives the
    /// byte-by-byte answer for every mix, at any start index (slices
    /// after a BOM) and with CR LF split across the middle of the data.
    func testLineEndingCountOverDataMatchesTheByteByByteCount() {
        let pieces: [[UInt8]] = [[0x0A], [0x0D], [0x0D, 0x0A], [0x61], [0x0D, 0x0D], [0x0A, 0x0D]]
        var generator = SystemRandomNumberGenerator()
        for round in 0..<500 {
            var bytes: [UInt8] = []
            for _ in 0..<Int.random(in: 0...40, using: &generator) {
                bytes += pieces.randomElement(using: &generator)!
            }
            let data = Data(bytes)
            XCTAssertEqual(PlainTextIO.mostCommonLineEnding(in: data), PlainTextIO.mostCommonLineEnding(in: bytes),
                           "round \(round): \(bytes)")
            let prefix = Int.random(in: 0...min(3, bytes.count), using: &generator)
            let slice = data.dropFirst(prefix)
            XCTAssertEqual(PlainTextIO.mostCommonLineEnding(in: slice), PlainTextIO.mostCommonLineEnding(in: Array(bytes.dropFirst(prefix))),
                           "round \(round), slice from \(prefix): \(bytes)")
        }
        // Ties and the plain cases.
        XCTAssertEqual(PlainTextIO.mostCommonLineEnding(in: Data("a\r\nb\nc\r".utf8)), .lf)
        XCTAssertEqual(PlainTextIO.mostCommonLineEnding(in: Data("a\r\nb\r\nc\n".utf8)), .crlf)
        XCTAssertEqual(PlainTextIO.mostCommonLineEnding(in: Data("a\rb\rc\r\n".utf8)), .cr)
        XCTAssertEqual(PlainTextIO.mostCommonLineEnding(in: Data()), .lf)
    }

    /// M8 n2: counting the line endings of 100 MB took about 480 ms one
    /// byte at a time (4.8 s for 1 GB, 2026-10-24); it must stay under
    /// 100 ms in an optimized build, both with no CR at all and with CR LF.
    func testLineEndingCountOf100MBIsFast() {
        let line = Data("line 00000000 the quick brown fox jumps over the lazy dog 0123456789\n".utf8)
        let crlfLine = Data("line 00000000 the quick brown fox jumps over the lazy dog 012345678\r\n".utf8)
        for (name, unit, expected) in [("LF", line, LineEnding.lf), ("CRLF", crlfLine, LineEnding.crlf)] {
            var data = Data(capacity: 100 * 1024 * 1024 + unit.count)
            while data.count < 100 * 1024 * 1024 { data.append(unit) }
            let start = DispatchTime.now().uptimeNanoseconds
            let ending = PlainTextIO.mostCommonLineEnding(in: data)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            print(String(format: "M8-N2 line-ending count, 100 MB of %@ lines: %.1f ms; optimized: %@", name, ms,
                         _isDebugAssertConfiguration() ? "false" : "true"))
            XCTAssertEqual(ending, expected)
            if !_isDebugAssertConfiguration() {
                XCTAssertLessThan(ms, 100, "\(name): \(ms) ms")
            }
        }
    }

    func testNoLineEndingReportsLF() {
        XCTAssertEqual(PlainTextIO.mostCommonLineEnding(in: Array("abc".utf8)), .lf)
    }
}
