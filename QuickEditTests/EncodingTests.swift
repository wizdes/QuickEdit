import AppKit
import XCTest
@testable import QuickEdit

/// M3 n1: decoding and encoding against AppKit's plain-text reader and writer
/// (the oracle, docs/plans/M3.md "Key idea").
@MainActor
final class EncodingTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickEditEncodingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        TextDocument.testHooks.withLock { $0 = .init() }
    }

    override func tearDown() async throws {
        TextDocument.testHooks.withLock { $0 = .init() }
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    // MARK: The oracle

    /// The encoding AppKit's plain-text reader picks for a file (what system
    /// TextEdit shows with "Automatic"), or nil when AppKit refuses the file.
    private func oracle(_ url: URL) -> UInt? {
        var attributes: NSDictionary?
        guard (try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.plain],
                                       documentAttributes: &attributes)) != nil else { return nil }
        return (attributes?[NSAttributedString.DocumentAttributeKey.characterEncoding] as? NSNumber)?.uintValue
    }

    /// AppKit names both UTF-16 byte orders "UTF-16" (and both UTF-32 ones
    /// "UTF-32"); QuickEdit keeps big-endian apart so it writes it back.
    private func comparable(_ format: DecodedText.Format) -> UInt {
        switch format.encoding {
        case .utf16BigEndian where format.hasBOM: String.Encoding.utf16.rawValue
        case .utf32BigEndian where format.hasBOM: String.Encoding.utf32.rawValue
        default: format.encoding.rawValue
        }
    }

    private struct Exception {
        let quickEdit: UInt
        let appKit: UInt? // nil: AppKit refuses the file
        let reason: String
    }

    /// Every fixture where QuickEdit and AppKit disagree, with both answers
    /// pinned, so a change on either side fails this test.
    private static let guessed = "AppKit never guesses: after xattr, BOM and UTF-8 it reads Mac Roman. QuickEdit asks NSString's guesser first (plan n1 step 1)."
    private static let exceptions: [String: Exception] = [
        "windows-1252": .init(quickEdit: String.Encoding.windowsCP1252.rawValue, appKit: 30, reason: guessed),
        "windows-1252-crlf": .init(quickEdit: String.Encoding.windowsCP1252.rawValue, appKit: 30, reason: guessed),
        "iso-latin-1": .init(quickEdit: String.Encoding.windowsCP1252.rawValue, appKit: 30,
                             reason: guessed + " Windows-1252 is a superset of these Latin-1 bytes."),
        "shift-jis": .init(quickEdit: String.Encoding.shiftJIS.rawValue, appKit: 30,
                           reason: guessed + " The guess is Windows Japanese (cp932), a superset of Shift JIS."),
        "big5": .init(quickEdit: 0x8000_0423, appKit: 30,
                      reason: guessed + " The guess is Windows Traditional Chinese (cp950), a superset of Big5."),
        "koi8-r": .init(quickEdit: String.Encoding.windowsCP1252.rawValue, appKit: 30,
                        reason: guessed + " Both are wrong here; the guesser with TextEdit's list picks Windows Latin 1."),
        "windows-1251": .init(quickEdit: String.Encoding.windowsCP1252.rawValue, appKit: 30,
                              reason: guessed + " Both are wrong here; the guesser with TextEdit's list picks Windows Latin 1."),
        "iso-8859-7": .init(quickEdit: String.Encoding.windowsCP1252.rawValue, appKit: 30,
                            reason: guessed + " Both are wrong here; the guesser with TextEdit's list picks Windows Latin 1."),
        "xattr-1252-over-emoji": .init(quickEdit: String.Encoding.utf8.rawValue, appKit: nil,
                                       reason: "The xattr's encoding does not fit the bytes: AppKit refuses to open; QuickEdit skips the xattr."),
        "xattr-stale-utf8": .init(quickEdit: String.Encoding.windowsCP1252.rawValue, appKit: nil,
                                  reason: "The xattr's encoding does not fit the bytes: AppKit refuses to open; QuickEdit skips the xattr."),
    ]

    private func save(_ document: TextDocument, to url: URL, _ op: NSDocument.SaveOperationType) async -> Error? {
        await withCheckedContinuation { continuation in
            document.save(to: url, ofType: TextDocument.plainTextType, for: op) { continuation.resume(returning: $0) }
        }
    }

    /// The done-test: every fixture's guess equals AppKit's (or is a listed
    /// exception), and open -> save gives the same bytes.
    func testEveryFixtureMatchesTheOracleAndRoundTrips() async throws {
        let fixtures = try EncodingFixtures.write(to: folder.appendingPathComponent("fixtures"))
        let suggested = EncodingManager.defaultEncodings()
        var rows: [String] = []
        var matches = 0, listed = 0, roundTrips = 0, documentRoundTrips = 0
        for (fixture, url) in fixtures {
            let name = fixture.name
            let bytes = try Data(contentsOf: url)
            let appKit = oracle(url)
            let decoded = try PlainTextIO.decode(bytes, url: url, suggested: suggested)
            let ours = comparable(decoded.format)
            XCTAssertFalse(decoded.lossy, "\(name) loaded lossily")
            if let exception = Self.exceptions[name] {
                XCTAssertEqual(ours, exception.quickEdit, "\(name): QuickEdit's guess changed")
                XCTAssertEqual(appKit, exception.appKit, "\(name): AppKit's answer changed")
                listed += 1
            } else {
                XCTAssertEqual(ours, appKit, "\(name): QuickEdit \(ours), AppKit \(String(describing: appKit))")
                if ours == appKit { matches += 1 }
            }

            // Byte round trip through PlainTextIO.
            let encoded = try PlainTextIO.encode(decoded.text, as: decoded.format)
            XCTAssertEqual(encoded, bytes, "\(name): PlainTextIO round trip changed the bytes")
            if encoded == bytes { roundTrips += 1 }

            // And through the document: open the file, save a copy.
            let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
            let out = folder.appendingPathComponent("saved-\(name).txt")
            let error = await save(document, to: out, .saveToOperation)
            XCTAssertNil(error, "\(name): save failed")
            let saved = try Data(contentsOf: out)
            XCTAssertEqual(saved, bytes, "\(name): open -> save changed the bytes")
            if saved == bytes { documentRoundTrips += 1 }
            XCTAssertEqual(PlainTextIO.readAttribute(of: out), PlainTextIO.attributeValue(for: document.format.encoding),
                           "\(name): the saved file's com.apple.TextEncoding")
            document.close()

            rows.append([name, appKit.map { "\($0) \(String.localizedName(of: .init(rawValue: $0)))" } ?? "refuses",
                         "\(ours) \(String.localizedName(of: decoded.format.encoding))",
                         Self.exceptions[name] == nil ? "yes" : "no (listed)",
                         saved == bytes && encoded == bytes ? "yes" : "NO"].joined(separator: " | "))
        }
        print("ENCODING ORACLE TABLE: fixture | AppKit | QuickEdit | match | round trip bytes equal")
        for row in rows { print("ENCODING ORACLE ROW: \(row)") }
        print("ENCODING FIXTURES: \(fixtures.count) fixtures, \(matches) match AppKit, \(listed) listed exceptions, "
              + "\(roundTrips) PlainTextIO round trips equal, \(documentRoundTrips) document save round trips equal")
        XCTAssertGreaterThanOrEqual(fixtures.count, 30)
        XCTAssertEqual(matches + listed, fixtures.count)
        XCTAssertEqual(roundTrips, fixtures.count)
        XCTAssertEqual(documentRoundTrips, fixtures.count)
    }

    // MARK: Encoding matches AppKit's writer

    /// AppKit's plain-text writer: what TextEdit writes for an encoding.
    private func appKitBytes(_ text: String, _ encoding: String.Encoding) throws -> Data {
        let string = NSAttributedString(string: text)
        return try string.data(from: NSRange(location: 0, length: string.length),
                               documentAttributes: [.documentType: NSAttributedString.DocumentType.plain,
                                                    .characterEncoding: encoding.rawValue])
    }

    func testEncodeWritesWhatAppKitWritesForANewEncoding() throws {
        let text = "Aé\r\nline two ü\n" // fits every encoding below, ISO Latin 1 included
        for encoding: String.Encoding in [.utf8, .utf16, .utf32, .utf16BigEndian, .utf16LittleEndian,
                                          .windowsCP1252, .macOSRoman, .isoLatin1] {
            let format = PlainTextIO.format(.newDocument, changedTo: encoding)
            XCTAssertEqual(try PlainTextIO.encode(text, as: format), try appKitBytes(text, encoding),
                           String.localizedName(of: encoding))
        }
        // UTF-16 with no BOM chosen gets one, little-endian, as AppKit writes it.
        let utf16 = try PlainTextIO.encode("A", as: .init(encoding: .utf16, hasBOM: false, lineEnding: .lf))
        XCTAssertEqual(Array(utf16), [0xFF, 0xFE, 0x41, 0x00])
    }

    func testAttributeValueMatchesAppKit() throws {
        let text = NSAttributedString(string: "x")
        for encoding: String.Encoding in [.utf8, .utf16, .windowsCP1252, .macOSRoman, .shiftJIS] {
            let wrapper = try text.fileWrapper(from: NSRange(location: 0, length: 1),
                                               documentAttributes: [.documentType: NSAttributedString.DocumentType.plain,
                                                                    .characterEncoding: encoding.rawValue])
            let url = folder.appendingPathComponent("appkit-\(encoding.rawValue).txt")
            try wrapper.write(to: url, options: [], originalContentsURL: nil)
            XCTAssertEqual(PlainTextIO.attributeValue(for: encoding), PlainTextIO.readAttribute(of: url),
                           String.localizedName(of: encoding))
        }
    }

    // MARK: Decoding rules

    func testPreferredEncodingWinsAndMismatchThrows() throws {
        let bytes = Data("caf\u{E9}\n".utf8) // valid UTF-8
        let asLatin = try PlainTextIO.decode(bytes, preferred: .windowsCP1252)
        XCTAssertEqual(asLatin.format.encoding, .windowsCP1252)
        XCTAssertEqual(asLatin.text, "caf\u{C3}\u{A9}\n")
        XCTAssertThrowsError(try PlainTextIO.decode(Data([0x61, 0xFF]), preferred: .utf8)) { error in
            XCTAssertEqual(error as? PlainTextIO.Error, .inapplicableEncoding(.utf8))
        }
    }

    func testPreferredUTF16WithoutBOMIsBigEndianAsInAppKit() throws {
        let decoded = try PlainTextIO.decode(Data([0x00, 0x61, 0x00, 0x62]), preferred: .utf16)
        XCTAssertEqual(decoded.text, "ab")
        XCTAssertEqual(decoded.format, .init(encoding: .utf16BigEndian, hasBOM: false, lineEnding: .lf))
        XCTAssertEqual(try PlainTextIO.encode(decoded.text, as: decoded.format), Data([0x00, 0x61, 0x00, 0x62]))
    }

    func testFallbackFailureDecodesLossily() throws {
        // Not UTF-8, no guess, and the fallback (ASCII here) cannot hold 0x81.
        let decoded = try PlainTextIO.decode(Data(EncodingFixtures.invalidEverywhere),
                                             suggested: EncodingManager.defaultEncodings(), fallback: .ascii)
        XCTAssertTrue(decoded.lossy)
        XCTAssertEqual(decoded.format.encoding, .utf8)
        XCTAssertTrue(decoded.text.contains("\u{FFFD}"))
    }

    func testAttributeIsReadByNumberThenByName() throws {
        let url = folder.appendingPathComponent("attr.txt")
        try Data("x".utf8).write(to: url)
        func set(_ value: String) {
            _ = value.withCString { setxattr(url.path, PlainTextIO.encodingAttribute, $0, strlen($0), 0, 0) }
        }
        set("windows-1252;1280")
        XCTAssertEqual(PlainTextIO.encodingNamedByAttribute(of: url), .windowsCP1252)
        set("macintosh;0")
        XCTAssertEqual(PlainTextIO.encodingNamedByAttribute(of: url), .macOSRoman, "number 0 is Mac Roman")
        set("windows-1252;99999")
        XCTAssertEqual(PlainTextIO.encodingNamedByAttribute(of: url), .windowsCP1252, "unknown number: use the name")
        set("windows-1252")
        XCTAssertEqual(PlainTextIO.encodingNamedByAttribute(of: url), .windowsCP1252)
        set("nonsense")
        XCTAssertNil(PlainTextIO.encodingNamedByAttribute(of: url))
    }

    func testMacRomanFallbackKeepsEveryByte() throws {
        let all = Data((0...255).map { UInt8($0) })
        let decoded = try XCTUnwrap(PlainTextIO.decode(all, as: .macOSRoman))
        XCTAssertEqual(try PlainTextIO.encode(decoded.text, as: decoded.format), all)
    }

    func testSaveEncodingChangeKeepsLineEndingAndBOMRules() {
        let crlfBOM = DecodedText.Format(encoding: .utf8, hasBOM: true, lineEnding: .crlf)
        XCTAssertEqual(PlainTextIO.format(crlfBOM, changedTo: .utf8), crlfBOM, "same encoding keeps the BOM")
        XCTAssertEqual(PlainTextIO.format(crlfBOM, changedTo: .windowsCP1252),
                       .init(encoding: .windowsCP1252, hasBOM: false, lineEnding: .crlf))
        XCTAssertEqual(PlainTextIO.format(crlfBOM, changedTo: .utf16),
                       .init(encoding: .utf16, hasBOM: true, lineEnding: .crlf))
    }

    // MARK: Through the document

    func testOpenWithAChosenEncodingThatDoesNotFitShowsAppKitsError() throws {
        let url = folder.appendingPathComponent("bad.txt")
        try Data([0x61, 0xFF, 0x0A]).write(to: url)
        DocumentController.setOpenPanelEncoding(.utf8, for: [url])
        XCTAssertThrowsError(try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)) { error in
            XCTAssertEqual((error as NSError).code, NSFileReadInapplicableStringEncodingError)
            XCTAssertTrue(error.localizedDescription.contains("couldn\u{2019}t be opened using text encoding Unicode (UTF-8)"),
                          error.localizedDescription)
        }
        XCTAssertNil(DocumentController.takeOpenPanelEncoding(for: url), "the read took the choice")
    }

    func testOpenPanelChoiceAppliesToThatFileOnly() throws {
        let chosen = folder.appendingPathComponent("chosen.txt"), other = folder.appendingPathComponent("other.txt")
        let bytes = Data("caf\u{E9}\n".utf8)
        try bytes.write(to: chosen)
        try bytes.write(to: other)
        DocumentController.setOpenPanelEncoding(.windowsCP1252, for: [chosen])
        let a = try TextDocument(contentsOf: chosen, ofType: TextDocument.plainTextType)
        let b = try TextDocument(contentsOf: other, ofType: TextDocument.plainTextType)
        XCTAssertEqual(a.format.encoding, .windowsCP1252)
        XCTAssertEqual(b.format.encoding, .utf8)
        // A revert reads the file the way it was opened.
        try a.revert(toContentsOf: chosen, ofType: TextDocument.plainTextType)
        XCTAssertEqual(a.format.encoding, .windowsCP1252)
        a.close()
        b.close()
    }

    func testDocumentRecordsALossyLoad() throws {
        TextDocument.testHooks.withLock { $0.fallbackEncoding = .ascii }
        let url = folder.appendingPathComponent("lossy.txt")
        try Data(EncodingFixtures.invalidEverywhere).write(to: url)
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        XCTAssertTrue(document.loadedLossily)
        document.close()
    }

    /// Takes over the purpose of the M1 test testInvalidUTF8OpenFailsWithNoDocument:
    /// an open that fails (since M3: a chosen encoding the bytes do not fit)
    /// leaves no document behind.
    func testFailedOpenThroughTheControllerLeavesNoDocument() async throws {
        let url = folder.appendingPathComponent("bad-open.txt")
        try Data([0x61, 0xFF, 0x62]).write(to: url)
        let controller = NSDocumentController.shared
        let before = controller.documents.count
        DocumentController.setOpenPanelEncoding(.utf8, for: [url])
        let result: (NSDocument?, Error?) = await withCheckedContinuation { continuation in
            controller.openDocument(withContentsOf: url, display: false) { document, _, error in
                continuation.resume(returning: (document, error))
            }
        }
        XCTAssertNil(result.0)
        XCTAssertNotNil(result.1)
        XCTAssertEqual(controller.documents.count, before)
        XCTAssertNil(controller.document(for: url))
        XCTAssertNil(DocumentController.takeOpenPanelEncoding(for: url), "no choice left behind")
    }
}
