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

    /// What AppKit's plain-text reader does with a file (what system TextEdit
    /// shows with "Automatic"): the encoding it picks, or the error when it
    /// refuses the file.
    private func oracle(_ url: URL) -> Result<UInt, NSError> {
        var attributes: NSDictionary?
        do {
            _ = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.plain],
                                       documentAttributes: &attributes)
        } catch {
            return .failure(error as NSError)
        }
        guard let encoding = (attributes?[NSAttributedString.DocumentAttributeKey.characterEncoding] as? NSNumber)?.uintValue else {
            return .failure(NSError(domain: "EncodingTests", code: 0,
                                    userInfo: [NSLocalizedDescriptionKey: "AppKit read the file but named no encoding"]))
        }
        return .success(encoding)
    }

    /// The text AppKit's plain-text reader shows for a file it opens (M6
    /// review row 5: compare the text, not only the encoding number).
    private func oracleText(_ url: URL) -> String? {
        try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.plain],
                                documentAttributes: nil).string
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
    /// pinned, so a change on either side fails this test. Empty since vote
    /// V2 (docs/decisions.md): "Automatic" reads exactly as AppKit does.
    private static let exceptions: [String: Exception] = [:]

    private func save(_ document: TextDocument, to url: URL, _ op: NSDocument.SaveOperationType) async -> Error? {
        await withCheckedContinuation { continuation in
            document.save(to: url, ofType: TextDocument.plainTextType, for: op) { continuation.resume(returning: $0) }
        }
    }

    /// The done-test: every fixture's result equals AppKit's (or is a listed
    /// exception): the same encoding, or, when AppKit refuses the file, the
    /// same refusal. Every file that opens gives the same bytes on open -> save.
    func testEveryFixtureMatchesTheOracleAndRoundTrips() async throws {
        let fixtures = try EncodingFixtures.write(to: folder.appendingPathComponent("fixtures"))
        var rows: [String] = []
        var matches = 0, listed = 0, refused = 0, roundTrips = 0, documentRoundTrips = 0
        for (fixture, url) in fixtures {
            let name = fixture.name
            let bytes = try Data(contentsOf: url)
            let appKit = oracle(url)
            let appKitEncoding = try? appKit.get()
            let decoded: DecodedText?
            var decodeError: Swift.Error?
            do { decoded = try PlainTextIO.decode(bytes, url: url) } catch { decoded = nil; decodeError = error }
            let ours = decoded.map { comparable($0.format) }

            if let exception = Self.exceptions[name] {
                XCTAssertEqual(ours, exception.quickEdit, "\(name): QuickEdit's answer changed")
                XCTAssertEqual(appKitEncoding, exception.appKit, "\(name): AppKit's answer changed")
                listed += 1
            } else {
                XCTAssertEqual(ours, appKitEncoding,
                               "\(name): QuickEdit \(ours.map(String.init) ?? "refuses (\(String(describing: decodeError)))"), "
                               + "AppKit \(appKitEncoding.map(String.init) ?? "refuses")")
                if ours == appKitEncoding { matches += 1 }
            }

            // AppKit refuses: QuickEdit refuses the same way, through the document too.
            if case .failure(let appKitError) = appKit {
                refused += 1
                let appKitEncodingNumber = (appKitError.userInfo[NSStringEncodingErrorKey] as? NSNumber)?.uintValue
                if let appKitEncodingNumber {
                    XCTAssertEqual(decodeError as? PlainTextIO.Error,
                                   .inapplicableEncoding(String.Encoding(rawValue: appKitEncodingNumber)),
                                   "\(name): PlainTextIO's refusal")
                }
                XCTAssertThrowsError(try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType),
                                     "\(name): the document opened a file AppKit refuses") { error in
                    let error = error as NSError
                    XCTAssertEqual(error.domain, appKitError.domain, name)
                    XCTAssertEqual(error.code, appKitError.code, name)
                    XCTAssertEqual((error.userInfo[NSStringEncodingErrorKey] as? NSNumber)?.uintValue, appKitEncodingNumber, name)
                    XCTAssertEqual(error.localizedDescription, appKitError.localizedDescription, name)
                }
                rows.append([name, "refuses (\(appKitError.code), \(appKitEncodingNumber.map(String.init) ?? "-"))",
                             decoded == nil ? "refuses" : "\(ours!)", ours == appKitEncoding ? "yes" : "NO",
                             "n/a (refused)"].joined(separator: " | "))
                continue
            }

            guard let decoded else {
                XCTFail("\(name): QuickEdit refused a file AppKit opens: \(String(describing: decodeError))")
                rows.append([name, "\(appKitEncoding!)", "refuses", "NO", "NO"].joined(separator: " | "))
                continue
            }
            XCTAssertFalse(decoded.lossy, "\(name) loaded lossily")
            XCTAssertEqual(decoded.text.unicodeScalars.map(\.value), oracleText(url)?.unicodeScalars.map(\.value),
                           "\(name): the text differs from AppKit's")

            // Byte round trip through PlainTextIO.
            let encoded = try PlainTextIO.encode(decoded.text, as: decoded.format)
            XCTAssertEqual(encoded, bytes, "\(name): PlainTextIO round trip changed the bytes")
            if encoded == bytes { roundTrips += 1 }

            // And through the document: open the file (the app's own decode
            // call), check its encoding, save a copy.
            let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
            XCTAssertEqual(comparable(document.format), appKitEncoding, "\(name): the document's encoding")
            let out = folder.appendingPathComponent("saved-\(name).txt")
            let error = await save(document, to: out, .saveToOperation)
            XCTAssertNil(error, "\(name): save failed")
            let saved = try Data(contentsOf: out)
            XCTAssertEqual(saved, bytes, "\(name): open -> save changed the bytes")
            if saved == bytes { documentRoundTrips += 1 }
            XCTAssertEqual(PlainTextIO.readAttribute(of: out), PlainTextIO.attributeValue(for: document.format.encoding),
                           "\(name): the saved file's com.apple.TextEncoding")
            document.close()

            rows.append([name, appKitEncoding.map { "\($0) \(String.localizedName(of: .init(rawValue: $0)))" } ?? "-",
                         "\(ours!) \(String.localizedName(of: decoded.format.encoding))",
                         Self.exceptions[name] == nil ? (ours == appKitEncoding ? "yes" : "NO") : "no (listed)",
                         saved == bytes && encoded == bytes ? "yes" : "NO"].joined(separator: " | "))
        }
        print("ENCODING ORACLE TABLE: fixture | AppKit | QuickEdit | match | round trip bytes equal")
        for row in rows { print("ENCODING ORACLE ROW: \(row)") }
        print("ENCODING FIXTURES: \(fixtures.count) fixtures, \(matches) match AppKit, \(listed) listed exceptions, "
              + "\(refused) refused by AppKit, \(roundTrips) PlainTextIO round trips equal, "
              + "\(documentRoundTrips) document save round trips equal")
        XCTAssertGreaterThanOrEqual(fixtures.count, 30)
        XCTAssertEqual(matches + listed, fixtures.count)
        // The two stale-xattr fixtures are the only files AppKit refuses;
        // every other fixture opens and round-trips byte for byte.
        XCTAssertEqual(refused, 2)
        XCTAssertEqual(roundTrips, fixtures.count - refused)
        XCTAssertEqual(documentRoundTrips, fixtures.count - refused)
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
        // AppKit names it plain UTF-16, not UTF-16BE (M6 review row 4); it
        // is written back big-endian with no BOM, as found.
        XCTAssertEqual(decoded.format, .init(encoding: .utf16, hasBOM: false, lineEnding: .lf, readWithoutBOM: true))
        XCTAssertEqual(try PlainTextIO.encode(decoded.text, as: decoded.format), Data([0x00, 0x61, 0x00, 0x62]))
    }

    func testFallbackFailureDecodesLossily() throws {
        // Not UTF-8, and the fallback (Windows Latin 1 here) cannot hold 0x81.
        // (ASCII was used until M6 review row 3: AppKit reads high bytes in
        // ASCII as Latin 1, so ASCII now holds every byte.)
        let decoded = try PlainTextIO.decode(Data(EncodingFixtures.invalidEverywhere), fallback: .windowsCP1252)
        XCTAssertTrue(decoded.lossy)
        XCTAssertEqual(decoded.format.encoding, .utf8)
        XCTAssertTrue(decoded.text.contains("\u{FFFD}"))
    }

    /// Vote V2: a stale xattr refuses the file (as AppKit does) instead of
    /// moving on to the BOM, UTF-8 or fallback steps.
    func testStaleAttributeRefusesTheFile() throws {
        let url = folder.appendingPathComponent("stale.txt")
        let bytes = Data([0x63, 0x61, 0x66, 0xE9, 0x0A]) // "café" in Windows-1252, not UTF-8
        try bytes.write(to: url)
        try PlainTextIO.writeAttribute(for: .utf8, to: url)
        XCTAssertThrowsError(try PlainTextIO.decode(bytes, url: url)) { error in
            XCTAssertEqual(error as? PlainTextIO.Error, .inapplicableEncoding(.utf8))
        }
        // An explicit choice still wins over the xattr.
        XCTAssertEqual(try PlainTextIO.decode(bytes, url: url, preferred: .windowsCP1252).format.encoding, .windowsCP1252)
    }

    /// Vote V2: no guess. Bytes that are not UTF-8 and have no BOM or xattr
    /// are read with the fallback, which is the system's C-string encoding.
    func testNonUTF8BytesUseTheSystemEncodingWithNoGuess() throws {
        let system = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringGetSystemEncoding()))
        XCTAssertEqual(String.defaultCStringEncoding, system)
        let shiftJIS = Data("日本語のテキストです。\n".data(using: .shiftJIS)!)
        let decoded = try PlainTextIO.decode(shiftJIS)
        XCTAssertEqual(decoded.format.encoding, system)
        XCTAssertFalse(decoded.lossy)
        XCTAssertEqual(try PlainTextIO.encode(decoded.text, as: decoded.format), shiftJIS)
        // A UTF-8 BOM over bytes that are not UTF-8 also ends at the fallback, BOM and all.
        let badBody = Data([0xEF, 0xBB, 0xBF, 0x61, 0xFF, 0x0A])
        let fallback = try PlainTextIO.decode(badBody, fallback: .macOSRoman)
        XCTAssertEqual(fallback.format.encoding, .macOSRoman)
        XCTAssertEqual(fallback.text, String(data: badBody, encoding: .macOSRoman))
        XCTAssertEqual(try PlainTextIO.encode(fallback.text, as: fallback.format), badBody)
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
        // A fallback that cannot hold 0x81 (M6 review row 3: no longer ASCII).
        TextDocument.testHooks.withLock { $0.fallbackEncoding = .windowsCP1252 }
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
