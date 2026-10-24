import Foundation

/// The M3 encoding fixtures (docs/plans/M3.md n1 step 3). Generated, never
/// committed: `EncodingFixtures.write(to:)` writes every file into a folder,
/// so each test run starts from the same bytes. Foundation only, so this file
/// also compiles on its own with `swiftc` for quick oracle checks.
enum EncodingFixtures {
    struct Fixture: Sendable {
        /// File name without extension; the file is `<name>.txt`.
        let name: String
        let bytes: [UInt8]
        /// The `com.apple.TextEncoding` extended attribute, if any.
        let xattr: String?
    }

    static func cf(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    // Sample texts: several lines each, so the encoding guesser sees realistic input.
    static let western = """
        Le café « déjà vu » coûte 5 € ce matin.
        Naïve façade, Größe über Straße, señor año.
        “Quoted” text – with a dash… and more.
        The end of the Western sample.

        """
    static let latin1Text = """
        Le café déjà vu, naïve façade.
        Größe über Straße. ¿Qué tal? ¡Olé!
        Ångström, Øresund, Æsir, ß and ÿ.

        """
    static let japanese = """
        日本語のテキストです。こんにちは世界。
        今日はいい天気ですね。カタカナとひらがなと漢字。
        東京都千代田区の住所を書きます。

        """
    static let simplifiedChinese = """
        中文文本，你好世界。这是一个测试。
        我们今天去公园散步，天气很好。
        北京是中国的首都。

        """
    static let traditionalChinese = """
        繁體中文文本，你好世界。這是一個測試。
        我們今天去公園散步，天氣很好。
        臺北是一個美麗的城市。

        """
    static let russian = """
        Привет, мир! Это проверка текста.
        Съешь же ещё этих мягких французских булок, да выпей чаю.
        Москва - столица России.

        """
    static let greek = """
        Γειά σου Κόσμε! Αυτό είναι ένα δοκιμαστικό κείμενο.
        Ξεσκεπάζω την ψυχοφθόρα βδελυγμία.
        Η Αθήνα είναι η πρωτεύουσα της Ελλάδας.

        """
    static let unicode = "Héllo wörld € 日本 Привет 👍🏽\nSecond line.\n"

    static func bytes(_ text: String, _ encoding: String.Encoding) -> [UInt8] {
        guard let data = text.data(using: encoding, allowLossyConversion: false) else {
            preconditionFailure("fixture text does not fit \(encoding)")
        }
        return Array(data)
    }

    static func withEndings(_ text: String, _ ending: String) -> String {
        text.replacingOccurrences(of: "\n", with: ending)
    }

    /// Bytes that are not UTF-8 and that NSString's guesser, given TextEdit's
    /// default encodings list, cannot place (it returns no string).
    static let invalidEverywhere: [UInt8] = [0x61, 0x62, 0x0A, 0x81, 0x8D, 0x8F, 0x90, 0x9D, 0x0A]

    static let all: [Fixture] = {
        let utf16LE = Array(unicode.data(using: .utf16LittleEndian)!)
        let utf16BE = Array(unicode.data(using: .utf16BigEndian)!)
        let utf32LE = Array(unicode.data(using: .utf32LittleEndian)!)
        let utf32BE = Array(unicode.data(using: .utf32BigEndian)!)
        let bom8: [UInt8] = [0xEF, 0xBB, 0xBF]
        return [
            Fixture(name: "ascii", bytes: Array("plain ASCII text\nsecond line\n".utf8), xattr: nil),
            Fixture(name: "empty", bytes: [], xattr: nil),
            Fixture(name: "utf8", bytes: Array(unicode.utf8), xattr: nil),
            Fixture(name: "utf8-bom", bytes: bom8 + Array(unicode.utf8), xattr: nil),
            Fixture(name: "utf16le-bom", bytes: [0xFF, 0xFE] + utf16LE, xattr: nil),
            Fixture(name: "utf16be-bom", bytes: [0xFE, 0xFF] + utf16BE, xattr: nil),
            Fixture(name: "utf32le-bom", bytes: [0xFF, 0xFE, 0x00, 0x00] + utf32LE, xattr: nil),
            Fixture(name: "utf32be-bom", bytes: [0x00, 0x00, 0xFE, 0xFF] + utf32BE, xattr: nil),
            Fixture(name: "macroman", bytes: bytes(western, .macOSRoman), xattr: nil),
            Fixture(name: "windows-1252", bytes: bytes(western, .windowsCP1252), xattr: nil),
            Fixture(name: "iso-latin-1", bytes: bytes(latin1Text, .isoLatin1), xattr: nil),
            Fixture(name: "shift-jis", bytes: bytes(japanese, .shiftJIS), xattr: nil),
            Fixture(name: "euc-jp", bytes: bytes(japanese, .japaneseEUC), xattr: nil),
            Fixture(name: "gb18030", bytes: bytes(simplifiedChinese, cf(.GB_18030_2000)), xattr: nil),
            Fixture(name: "big5", bytes: bytes(traditionalChinese, cf(.big5)), xattr: nil),
            Fixture(name: "koi8-r", bytes: bytes(russian, cf(.KOI8_R)), xattr: nil),
            Fixture(name: "windows-1251", bytes: bytes(russian, .windowsCP1251), xattr: nil),
            Fixture(name: "iso-8859-7", bytes: bytes(greek, cf(.isoLatinGreek)), xattr: nil),
            // Valid UTF-8 bytes, but the xattr says Windows-1252: the xattr wins.
            // (The Latin-1 sample: every byte of its UTF-8 form exists in Windows-1252.)
            Fixture(name: "xattr-1252-over-utf8", bytes: Array(latin1Text.utf8), xattr: "windows-1252;1280"),
            // UTF-8 bytes holding an emoji, whose bytes include 0x8D (not in
            // Windows-1252), under a Windows-1252 xattr.
            Fixture(name: "xattr-1252-over-emoji", bytes: Array(unicode.utf8), xattr: "windows-1252;1280"),
            Fixture(name: "xattr-1252-name-only", bytes: bytes(western, .windowsCP1252), xattr: "windows-1252"),
            Fixture(name: "xattr-macroman", bytes: bytes(western, .macOSRoman), xattr: "macintosh;0"),
            Fixture(name: "xattr-shift-jis", bytes: bytes(japanese, .shiftJIS), xattr: "shift_jis;2561"),
            Fixture(name: "xattr-utf8-over-bom", bytes: bom8 + Array(unicode.utf8), xattr: "utf-8;134217984"),
            Fixture(name: "xattr-1252-over-bom", bytes: bom8 + Array(latin1Text.utf8), xattr: "windows-1252;1280"),
            // A stale xattr: it names UTF-8 but the bytes are Windows-1252.
            Fixture(name: "xattr-stale-utf8", bytes: bytes(western, .windowsCP1252), xattr: "utf-8;134217984"),
            Fixture(name: "invalid-everywhere", bytes: invalidEverywhere, xattr: nil),
            Fixture(name: "utf8-bom-invalid-body", bytes: bom8 + [0x61, 0xFF, 0x0A], xattr: nil),
            Fixture(name: "endings-lf", bytes: Array("one\ntwo\nthree\n".utf8), xattr: nil),
            Fixture(name: "endings-cr", bytes: Array("one\rtwo\rthree\r".utf8), xattr: nil),
            Fixture(name: "endings-crlf", bytes: Array("one\r\ntwo\r\nthree\r\n".utf8), xattr: nil),
            Fixture(name: "endings-mixed", bytes: Array("a\r\nb\nc\rd\r\ne\r\n".utf8), xattr: nil),
            Fixture(name: "windows-1252-crlf", bytes: bytes(withEndings(western, "\r\n"), .windowsCP1252), xattr: nil),
            Fixture(name: "utf16le-bom-crlf", bytes: [0xFF, 0xFE] + Array(withEndings(unicode, "\r\n").data(using: .utf16LittleEndian)!), xattr: nil),
        ]
    }()

    /// Writes every fixture into `folder` (created if missing) and returns
    /// each fixture with its file URL.
    static func write(to folder: URL) throws -> [(fixture: Fixture, url: URL)] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try all.map { fixture in
            let url = folder.appendingPathComponent(fixture.name + ".txt")
            try Data(fixture.bytes).write(to: url)
            if let xattr = fixture.xattr {
                let status = xattr.withCString { value in
                    setxattr(url.path, "com.apple.TextEncoding", value, strlen(value), 0, 0)
                }
                guard status == 0 else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [
                        NSFilePathErrorKey: url.path,
                        NSLocalizedFailureReasonErrorKey: "setxattr failed: errno \(errno)",
                    ])
                }
            }
            return (fixture, url)
        }
    }
}
