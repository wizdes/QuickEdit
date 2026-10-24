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

    func testInvalidUTF8Throws() {
        for bad: [UInt8] in [[0xFF], [0x61, 0xC3], [0xED, 0xA0, 0x80], [0xC0, 0xAF], [0xEF, 0xBB, 0xBF, 0xFE]] {
            XCTAssertThrowsError(try PlainTextIO.decode(Data(bad)), "\(bad)") { error in
                XCTAssertEqual(error as? PlainTextIO.Error, .notUTF8)
            }
        }
    }

    func testEncodeRejectsOtherEncodings() {
        let format = DecodedText.Format(encoding: .utf16, hasBOM: false, lineEnding: .lf)
        XCTAssertThrowsError(try PlainTextIO.encode("x", as: format))
    }

    func testNoLineEndingReportsLF() {
        XCTAssertEqual(PlainTextIO.mostCommonLineEnding(in: Array("abc".utf8)), .lf)
    }
}
