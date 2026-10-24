import AppKit
import XCTest
@testable import QuickEdit

/// M6 review rows 2-5 (docs/reviews/M6-code.md): malformed BOM files, ASCII
/// over high bytes, and UTF-16/32 xattrs without a BOM read as AppKit reads
/// them: the same encoding AND the same text, or the same refusal. Any file
/// whose bytes would not be written back the same is lossy, so the overwrite
/// alert guards the save. AppKit's plain-text reader is the oracle.
@MainActor
final class M6EncodingTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickEditM6EncodingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        TextDocument.testHooks.withLock { $0 = .init() }
    }

    override func tearDown() async throws {
        TextDocument.testHooks.withLock { $0 = .init() }
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    /// AppKit's answer: encoding and text, or the refusal.
    private struct AppKitRead {
        var encoding: UInt?
        var text: String?
        var error: NSError?
    }

    private func appKit(_ url: URL, explicit: String.Encoding? = nil) -> AppKitRead {
        var attributes: NSDictionary?
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.plain]
        if let explicit { options[.characterEncoding] = explicit.rawValue }
        do {
            let string = try NSAttributedString(url: url, options: options, documentAttributes: &attributes)
            let encoding = (attributes?[NSAttributedString.DocumentAttributeKey.characterEncoding] as? NSNumber)?.uintValue
            return AppKitRead(encoding: encoding, text: string.string, error: nil)
        } catch {
            return AppKitRead(encoding: nil, text: nil, error: error as NSError)
        }
    }

    /// AppKit names a file with a big-endian BOM plain UTF-16 or UTF-32;
    /// QuickEdit keeps the byte order so it writes it back.
    private func comparable(_ format: DecodedText.Format) -> UInt {
        switch format.encoding {
        case .utf16BigEndian where format.hasBOM: String.Encoding.utf16.rawValue
        case .utf32BigEndian where format.hasBOM: String.Encoding.utf32.rawValue
        default: format.encoding.rawValue
        }
    }

    private func scalars(_ text: String?) -> String {
        text.map { $0.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ") } ?? "nil"
    }

    private func write(_ name: String, _ bytes: [UInt8], attribute: String? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        if let attribute {
            let status = attribute.withCString { setxattr(url.path, PlainTextIO.encodingAttribute, $0, strlen($0), 0, 0) }
            XCTAssertEqual(status, 0, "setxattr \(name)")
        }
        return url
    }

    /// One case: QuickEdit's decode (Automatic, or `explicit`) against
    /// AppKit's, and, when the file opens, the lossy flag against a real
    /// byte round trip. Returns a report row.
    @discardableResult
    private func check(_ name: String, _ bytes: [UInt8], attribute: String? = nil,
                       explicit: String.Encoding? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let url = try write(name, bytes, attribute: attribute)
        let expected = appKit(url, explicit: explicit)
        let ours: DecodedText?
        var ourError: Error?
        do { ours = try PlainTextIO.decode(Data(bytes), url: url, preferred: explicit) } catch { ours = nil; ourError = error }

        if let error = expected.error {
            let number = (error.userInfo[NSStringEncodingErrorKey] as? NSNumber)?.uintValue
            XCTAssertNil(ours, "\(name): AppKit refuses (\(error.code)), QuickEdit read \(scalars(ours?.text))", file: file, line: line)
            if let number {
                XCTAssertEqual(ourError as? PlainTextIO.Error, .inapplicableEncoding(String.Encoding(rawValue: number)),
                               "\(name): the refusal names AppKit's encoding", file: file, line: line)
            }
            return "\(name) | AppKit refuses \(error.code) | QuickEdit \(ours == nil ? "refuses" : "reads")"
        }
        guard let ours else {
            XCTFail("\(name): AppKit reads \(expected.encoding.map(String.init) ?? "?") \(scalars(expected.text)); "
                    + "QuickEdit refuses: \(String(describing: ourError))", file: file, line: line)
            return "\(name) | QuickEdit refuses"
        }
        XCTAssertEqual(comparable(ours.format), expected.encoding, "\(name): encoding", file: file, line: line)
        XCTAssertEqual(scalars(ours.text), scalars(expected.text), "\(name): text", file: file, line: line)
        let roundTrips = (try? PlainTextIO.encode(ours.text, as: ours.format)) == Data(bytes)
        XCTAssertEqual(ours.lossy, !roundTrips, "\(name): lossy must be set exactly when the bytes do not round-trip",
                       file: file, line: line)
        return "\(name) | \(expected.encoding.map(String.init) ?? "?") | \(scalars(ours.text)) | lossy \(ours.lossy)"
    }

    // MARK: Row 2: malformed BOM files (8 shapes and three more)

    static let malformedBOM: [(String, [UInt8])] = [
        ("utf16le-odd-length", [0xFF, 0xFE, 0x61, 0x00, 0x62]),
        ("utf16be-odd-length", [0xFE, 0xFF, 0x00, 0x61, 0x00]),
        ("utf16le-lone-high-surrogate", [0xFF, 0xFE, 0x3D, 0xD8, 0x61, 0x00]),
        ("utf16le-lone-low-surrogate", [0xFF, 0xFE, 0x00, 0xDC, 0x61, 0x00]),
        ("utf16be-half-surrogate", [0xFE, 0xFF, 0xD8, 0x3D, 0x00, 0x61]),
        ("utf32le-bad-body", [0xFF, 0xFE, 0x00, 0x00, 0x00, 0x00, 0x11, 0x00, 0x61, 0x00, 0x00, 0x00]),
        ("utf16le-nul-looks-like-utf32-bom", [0xFF, 0xFE, 0x00, 0x00, 0x61, 0x00]),
        ("utf32le-short-tail", [0xFF, 0xFE, 0x00, 0x00, 0x61, 0x00, 0x00, 0x00, 0x62, 0x00]),
        ("utf32be-bad-body", [0x00, 0x00, 0xFE, 0xFF, 0x00, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x61]),
        ("utf32le-surrogate", [0xFF, 0xFE, 0x00, 0x00, 0x00, 0xD8, 0x00, 0x00]),
        ("utf32be-short-tail", [0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x61, 0x00]),
    ]

    func testRow2MalformedBOMFilesReadAsAppKitReadsThem() throws {
        var rows: [String] = []
        for (name, bytes) in Self.malformedBOM { rows.append(try check(name, bytes)) }
        let report = XCTAttachment(string: rows.joined(separator: "\n"))
        report.name = "malformed-bom"
        report.lifetime = .keepAlways
        add(report)
    }

    /// A malformed file that opens is lossy, so the document asks before a
    /// save writes over it; Cancel keeps the bytes.
    func testRow2RepairedFileIsGuardedBeforeASave() async throws {
        let bytes: [UInt8] = [0xFF, 0xFE, 0x61, 0x00, 0x62]
        let url = try write("guarded.txt", bytes)
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        XCTAssertTrue(document.loadedLossily)
        let presenter = EncodingDocumentTests.FakePresenter()
        document.alertPresenter = presenter
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: url, ofType: TextDocument.plainTextType, for: .saveOperation) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual((error as? CocoaError)?.code, .userCancelled)
        XCTAssertEqual(presenter.lossyQuestions, 1)
        XCTAssertEqual(Array(try Data(contentsOf: url)), bytes)
        document.close()
    }

    // MARK: Row 3: ASCII over high bytes, explicit UTF-16 with bad bytes

    func testRow3AsciiAndExplicitUTF16ReadAsAppKitReadsThem() throws {
        try check("ascii-xattr-high", [0x63, 0x61, 0x66, 0xE9, 0x0A], attribute: "us-ascii;1536")
        try check("ascii-explicit-high", [0x80, 0x81, 0x8D, 0x9F, 0xA0, 0xE9, 0xFF], explicit: .ascii)
        try check("ascii-explicit-clean", Array("plain\r\n".utf8), explicit: .ascii)
        try check("utf16-explicit-odd", [0xFF, 0xFE, 0x61, 0x00, 0x62], explicit: .utf16)
        try check("utf16-explicit-half-surrogate", [0xFF, 0xFE, 0x3D, 0xD8, 0x61, 0x00], explicit: .utf16)
        try check("utf16-explicit-no-bom-odd", [0x00, 0x61, 0x00], explicit: .utf16)
    }

    // MARK: Row 4: UTF-16 / UTF-32 xattr with no BOM

    func testRow4UnicodeAttributeWithoutBOMNamesPlainUTF16AndUTF32() throws {
        try check("utf16-xattr-no-bom", [0x00, 0x61, 0x00, 0x62, 0x00, 0x0A], attribute: "utf-16;256")
        try check("utf32-xattr-no-bom", [0x00, 0x00, 0x00, 0x61, 0x00, 0x00, 0x00, 0x0A], attribute: "utf-32;201326848")
        try check("utf16le-xattr-no-bom", [0x61, 0x00, 0x62, 0x00], attribute: "utf-16le;335544576")
        try check("utf16-xattr-with-bom", [0xFF, 0xFE, 0x61, 0x00], attribute: "utf-16;256")
        // And they write back byte for byte.
        let decoded = try PlainTextIO.decode(Data([0x00, 0x61, 0x00, 0x62]), preferred: .utf16)
        XCTAssertEqual(decoded.format.encoding, .utf16)
        XCTAssertFalse(decoded.lossy)
        XCTAssertEqual(Array(try PlainTextIO.encode(decoded.text, as: decoded.format)), [0x00, 0x61, 0x00, 0x62])
    }

    // MARK: Row 5: the oracle compares the text too, for every fixture

    func testRow5EveryFixtureHasAppKitsText() throws {
        let fixtures = try EncodingFixtures.write(to: folder.appendingPathComponent("fixtures"))
        var compared = 0
        for (fixture, url) in fixtures {
            let expected = appKit(url)
            guard expected.error == nil else { continue }
            let ours = try PlainTextIO.decode(try Data(contentsOf: url), url: url)
            XCTAssertEqual(scalars(ours.text), scalars(expected.text), "\(fixture.name): text differs from AppKit's")
            compared += 1
        }
        XCTAssertGreaterThan(compared, 25)
    }
}
