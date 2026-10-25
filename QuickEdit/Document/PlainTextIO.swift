import Foundation

/// Bytes on disk <-> text, with the details needed to write the same bytes back.
/// Pure functions, no AppKit (contract `io-plain`, Doc B section 3).
///
/// Line endings: the text keeps every line ending exactly as found (CR, LF,
/// CRLF, mixed). `Format.lineEnding` records the most common one, which
/// Return types; `encode` never converts line endings.
struct DecodedText: Equatable, Sendable {
    var text: String
    var format: Format
    /// Saving the text would not write back the bytes that were read: they
    /// did not fit any encoding and some were replaced, or (M3+M5 review
    /// row 1) the encoding maps them to text that encodes to other bytes or
    /// cannot be encoded at all. Saving over such a file changes it, so the
    /// document warns first.
    var lossy = false

    struct Format: Equatable, Sendable {
        /// For UTF-16 and UTF-32, `.utf16` / `.utf32` mean "little-endian
        /// with a BOM" (what AppKit writes for them); a file with a
        /// big-endian BOM keeps `.utf16BigEndian` / `.utf32BigEndian` so it
        /// is written back as found.
        var encoding: String.Encoding
        var hasBOM: Bool
        var lineEnding: LineEnding
        /// A `.utf16` / `.utf32` file read with no BOM (an xattr or an
        /// explicit choice): AppKit reads it big-endian and names it plain
        /// UTF-16/32 (M6 review row 4). It is written back as found:
        /// big-endian, no BOM.
        var readWithoutBOM = false

        /// What a new, untitled document writes: UTF-8, no BOM, LF.
        static let newDocument = Format(encoding: .utf8, hasBOM: false, lineEnding: .lf)
    }
}

enum LineEnding: String, Equatable, Sendable {
    case lf, crlf, cr

    var string: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        }
    }
}

enum PlainTextIO {
    enum Error: Swift.Error, Equatable {
        /// Not thrown since M3 (other encodings are tried); kept so the M1
        /// test that names it still compiles until root rules on that test.
        case notUTF8
        /// The bytes do not fit the encoding the user chose.
        case inapplicableEncoding(String.Encoding)
        /// `encode`: the text has characters the encoding cannot hold.
        case unencodable(String.Encoding)
    }

    static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    static let utf16LEBOM: [UInt8] = [0xFF, 0xFE]
    static let utf16BEBOM: [UInt8] = [0xFE, 0xFF]
    static let utf32LEBOM: [UInt8] = [0xFF, 0xFE, 0x00, 0x00]
    static let utf32BEBOM: [UInt8] = [0x00, 0x00, 0xFE, 0xFF]

    /// The extended attribute TextEdit (through AppKit) writes on save and
    /// AppKit's plain-text reader reads first.
    static let encodingAttribute = "com.apple.TextEncoding"

    /// Encodings that can hold any text (TextEdit never disables these in the
    /// Save panel and never warns about them, Document.m:1311).
    static func holdsAnyText(_ encoding: String.Encoding) -> Bool {
        switch encoding {
        case .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian,
             .utf32, .utf32LittleEndian, .utf32BigEndian, .nonLossyASCII: true
        default: false
        }
    }

    // MARK: Decoding

    /// Turns file bytes into text the way AppKit's plain-text reader does
    /// (vote V2 in docs/decisions.md: "Automatic" matches system TextEdit).
    /// - `preferred`: an explicit choice (Open panel, `PlainTextEncoding`
    ///   default). It wins; bytes that do not fit throw `inapplicableEncoding`.
    /// - Else, in order:
    ///   1. the `com.apple.TextEncoding` xattr of `url`. Bytes that do not fit
    ///      it throw `inapplicableEncoding`, as AppKit refuses such a file;
    ///      there is no next step.
    ///   2. a BOM (UTF-32, UTF-16, UTF-8), read as AppKit reads it (M6
    ///      review row 2): a UTF-16 body drops an odd last byte and shows a
    ///      lone surrogate as U+FFFD; a UTF-32 body drops an incomplete last
    ///      unit and is refused (`inapplicableEncoding(.utf32)`) when a unit
    ///      is not a Unicode scalar; `FF FE 00 00` is a UTF-32 BOM. A UTF-8
    ///      BOM whose body does not decode is skipped (AppKit then reads the
    ///      file as Mac Roman, BOM and all).
    ///   3. strict UTF-8.
    ///   4. `fallback`: AppKit's last step, the system's default C-string
    ///      encoding (`String.defaultCStringEncoding`, Mac Roman on this Mac).
    ///   There is no guess: AppKit never guesses.
    /// - Every decode by a non-Unicode encoding (explicit, xattr or fallback)
    ///   is encoded once and compared; if the bytes differ, or the text
    ///   cannot be encoded, the result is marked `lossy` (M3+M5 review row 1).
    /// - Only if `fallback` cannot hold the bytes (never for Mac Roman, which
    ///   maps all 256 byte values) is the text decoded lossily (UTF-8 with
    ///   replacement characters) and marked `lossy`.
    static func decode(_ data: Data, url: URL? = nil, preferred: String.Encoding? = nil,
                       fallback: String.Encoding = String.defaultCStringEncoding) throws -> DecodedText {
        if let preferred {
            guard let decoded = decode(data, as: preferred) else { throw Error.inapplicableEncoding(preferred) }
            return decoded
        }
        if let url, let named = encodingNamedByAttribute(of: url) {
            guard let decoded = decode(data, as: named) else { throw Error.inapplicableEncoding(named) }
            return decoded
        }
        if let decoded = try decodeByBOM(data) { return decoded }
        if let text = String(validating: data, as: UTF8.self) {
            return DecodedText(text: text, format: .init(encoding: .utf8, hasBOM: false,
                                                         lineEnding: mostCommonLineEnding(in: data)))
        }
        if let decoded = decode(data, as: fallback) { return decoded }
        let text = String(decoding: data, as: UTF8.self)
        return DecodedText(text: text, format: .init(encoding: .utf8, hasBOM: false,
                                                     lineEnding: mostCommonLineEnding(in: data)),
                           lossy: true)
    }

    /// Decodes with one known encoding, or nil when the bytes do not fit.
    /// A BOM that matches the encoding is taken off and recorded; for plain
    /// `.utf16` / `.utf32` the BOM picks the byte order, and no BOM means
    /// big-endian (as AppKit reads them).
    static func decode(_ data: Data, as encoding: String.Encoding) -> DecodedText? {
        switch encoding {
        case .utf8:
            let hasBOM = data.starts(with: utf8BOM)
            let body = hasBOM ? data.dropFirst(utf8BOM.count) : data[...]
            // String(validating:) checks every byte and, unlike
            // String(data:encoding:), never strips a BOM or repairs bad bytes.
            guard let text = String(validating: body, as: UTF8.self) else { return nil }
            return DecodedText(text: text, format: .init(encoding: .utf8, hasBOM: hasBOM,
                                                         lineEnding: mostCommonLineEnding(in: body)))
        case .utf16:
            if data.starts(with: utf16LEBOM) { return decodeUnicode(data, bom: utf16LEBOM, body: .utf16LittleEndian, as: .utf16) }
            if data.starts(with: utf16BEBOM) { return decodeUnicode(data, bom: utf16BEBOM, body: .utf16BigEndian, as: .utf16BigEndian) }
            return decodeUnicode(data, bom: nil, body: .utf16BigEndian, as: .utf16)
        case .utf16LittleEndian:
            return decodeUnicode(data, bom: data.starts(with: utf16LEBOM) ? utf16LEBOM : nil, body: encoding, as: encoding)
        case .utf16BigEndian:
            return decodeUnicode(data, bom: data.starts(with: utf16BEBOM) ? utf16BEBOM : nil, body: encoding, as: encoding)
        case .utf32:
            if data.starts(with: utf32LEBOM) { return decodeUnicode(data, bom: utf32LEBOM, body: .utf32LittleEndian, as: .utf32) }
            if data.starts(with: utf32BEBOM) { return decodeUnicode(data, bom: utf32BEBOM, body: .utf32BigEndian, as: .utf32BigEndian) }
            return decodeUnicode(data, bom: nil, body: .utf32BigEndian, as: .utf32)
        case .utf32LittleEndian:
            return decodeUnicode(data, bom: data.starts(with: utf32LEBOM) ? utf32LEBOM : nil, body: encoding, as: encoding)
        case .utf32BigEndian:
            return decodeUnicode(data, bom: data.starts(with: utf32BEBOM) ? utf32BEBOM : nil, body: encoding, as: encoding)
        case .ascii:
            // AppKit reads bytes 0x80-0xFF in an ASCII file as the ISO
            // Latin 1 characters (M6 review row 3); such text cannot be
            // written as ASCII again, so the round-trip check marks it lossy.
            guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
            let format = DecodedText.Format(encoding: .ascii, hasBOM: false, lineEnding: mostCommonLineEnding(in: data))
            return DecodedText(text: text, format: format, lossy: (try? encode(text, as: format)) != data)
        default:
            guard let text = String(data: data, encoding: encoding) else { return nil }
            let format = DecodedText.Format(encoding: encoding, hasBOM: false, lineEnding: mostCommonLineEnding(in: data))
            // Legacy encodings can map several byte sequences to one character
            // (cp932 FA 40 and EE EF both read as U+2170), or read bytes as
            // text they cannot write (EUC-JP 8E E0 as U+FFA0): such a file
            // would change on save.
            let roundTrips = (try? encode(text, as: format)) == data
            return DecodedText(text: text, format: format, lossy: !roundTrips)
        }
    }

    /// UTF-16 or UTF-32 body after an optional BOM, read as AppKit reads it
    /// (M6 review rows 2 and 3): an incomplete last unit is dropped; in
    /// UTF-16 a lone surrogate becomes U+FFFD; in UTF-32 a unit that is not
    /// a Unicode scalar makes the whole body unreadable (nil). The result is
    /// lossy when it would not write back the same bytes. Line endings are
    /// counted on the decoded text, since CR and LF are not single bytes here.
    private static func decodeUnicode(_ data: Data, bom: [UInt8]?, body bodyEncoding: String.Encoding,
                                      as recorded: String.Encoding) -> DecodedText? {
        let body = Array(data.dropFirst(bom?.count ?? 0))
        let text: String
        switch bodyEncoding {
        case .utf16LittleEndian, .utf16BigEndian:
            let little = bodyEncoding == .utf16LittleEndian
            var units: [UInt16] = []
            units.reserveCapacity(body.count / 2)
            var index = 0
            while index + 1 < body.count {
                let (a, b) = (UInt16(body[index]), UInt16(body[index + 1]))
                units.append(little ? a | b << 8 : a << 8 | b)
                index += 2
            }
            text = String(decoding: units, as: UTF16.self) // lone surrogates -> U+FFFD
        default:
            let little = bodyEncoding == .utf32LittleEndian
            var scalars = String.UnicodeScalarView()
            var index = 0
            while index + 3 < body.count {
                let bytes = (UInt32(body[index]), UInt32(body[index + 1]), UInt32(body[index + 2]), UInt32(body[index + 3]))
                let value = little ? bytes.0 | bytes.1 << 8 | bytes.2 << 16 | bytes.3 << 24
                                   : bytes.0 << 24 | bytes.1 << 16 | bytes.2 << 8 | bytes.3
                guard let scalar = Unicode.Scalar(value) else { return nil }
                scalars.append(scalar)
                index += 4
            }
            text = String(scalars)
        }
        let format = DecodedText.Format(encoding: recorded, hasBOM: bom != nil,
                                        lineEnding: mostCommonLineEnding(in: text.utf8),
                                        readWithoutBOM: bom == nil && (recorded == .utf16 || recorded == .utf32))
        return DecodedText(text: text, format: format, lossy: (try? encode(text, as: format)) != data)
    }

    /// UTF-32 BOMs first: the UTF-32 LE BOM starts with the UTF-16 LE one,
    /// and AppKit takes `FF FE 00 00` as UTF-32 even when it was meant as
    /// UTF-16 starting with U+0000. A UTF-32 body AppKit cannot read is
    /// refused, as AppKit refuses it.
    private static func decodeByBOM(_ data: Data) throws -> DecodedText? {
        if data.starts(with: utf32LEBOM) || data.starts(with: utf32BEBOM) {
            guard let decoded = decode(data, as: .utf32) else { throw Error.inapplicableEncoding(.utf32) }
            return decoded
        }
        if data.starts(with: utf16LEBOM) || data.starts(with: utf16BEBOM) { return decode(data, as: .utf16) }
        if data.starts(with: utf8BOM) { return decode(data, as: .utf8) }
        return nil
    }

    // MARK: Encoding

    /// Writes `text` in `format`: a BOM exactly when `hasBOM` (UTF-8,
    /// UTF-16 LE/BE, UTF-32 LE/BE); plain `.utf16` and `.utf32` write a BOM
    /// and little-endian (as AppKit writes them), or, for a file read without
    /// a BOM (`readWithoutBOM`), big-endian with no BOM, as found. Never
    /// converts line endings.
    static func encode(_ text: String, as format: DecodedText.Format) throws -> Data {
        switch format.encoding {
        case .utf8:
            var data = Data()
            let utf8 = text.utf8
            data.reserveCapacity(utf8.count + (format.hasBOM ? utf8BOM.count : 0))
            if format.hasBOM { data.append(contentsOf: utf8BOM) }
            data.append(contentsOf: utf8)
            return data
        case .utf16:
            return format.readWithoutBOM ? try unicode(text, bom: nil, body: .utf16BigEndian)
                                         : try unicode(text, bom: utf16LEBOM, body: .utf16LittleEndian)
        case .utf32:
            return format.readWithoutBOM ? try unicode(text, bom: nil, body: .utf32BigEndian)
                                         : try unicode(text, bom: utf32LEBOM, body: .utf32LittleEndian)
        case .utf16LittleEndian: return try unicode(text, bom: format.hasBOM ? utf16LEBOM : nil, body: format.encoding)
        case .utf16BigEndian: return try unicode(text, bom: format.hasBOM ? utf16BEBOM : nil, body: format.encoding)
        case .utf32LittleEndian: return try unicode(text, bom: format.hasBOM ? utf32LEBOM : nil, body: format.encoding)
        case .utf32BigEndian: return try unicode(text, bom: format.hasBOM ? utf32BEBOM : nil, body: format.encoding)
        default:
            guard let data = text.data(using: format.encoding, allowLossyConversion: false) else {
                throw Error.unencodable(format.encoding)
            }
            return data
        }
    }

    private static func unicode(_ text: String, bom: [UInt8]?, body: String.Encoding) throws -> Data {
        guard let encoded = text.data(using: body, allowLossyConversion: false) else { throw Error.unencodable(body) }
        guard let bom else { return encoded }
        return Data(bom) + encoded
    }

    /// The format to write when the user picks `encoding` in the Save panel:
    /// the same format if the encoding did not change (a UTF-8 BOM stays),
    /// else the new encoding with its usual BOM and the same line ending.
    static func format(_ current: DecodedText.Format, changedTo encoding: String.Encoding) -> DecodedText.Format {
        if encoding == current.encoding { return current }
        return .init(encoding: encoding, hasBOM: encoding == .utf16 || encoding == .utf32,
                     lineEnding: current.lineEnding)
    }

    // MARK: The com.apple.TextEncoding extended attribute

    /// `<IANA name>;<CFStringEncoding>`, as AppKit writes it (for example
    /// `windows-1252;1280`, `utf-8;134217984`). An encoding with no IANA name
    /// gets `;<CFStringEncoding>` (Non-lossy ASCII: `;3071`); AppKit reads that
    /// form by its number (checked on macOS 27.0.1 with
    /// NSString(contentsOf:usedEncoding:)). Nil only for an encoding CF does not know.
    static func attributeValue(for encoding: String.Encoding) -> String? {
        let cf = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        let name = CFStringConvertEncodingToIANACharSetName(cf) as String? ?? ""
        return "\(name);\(cf)"
    }

    /// The encoding the attribute names: by its number, or by its name when
    /// the number is missing or unknown (AppKit reads both). Nil when the
    /// file has no attribute or it names nothing usable.
    static func encodingNamedByAttribute(of url: URL) -> String.Encoding? {
        guard let value = readAttribute(of: url) else { return nil }
        let parts = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, let number = UInt32(parts[1].trimmingCharacters(in: .whitespaces)),
           CFStringIsEncodingAvailable(number) {
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(number))
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(parts[0] as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    static func readAttribute(of url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, encodingAttribute, nil, 0, 0, 0)
            guard size > 0, size < 4096 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let read = getxattr(path, encodingAttribute, &buffer, size, 0, 0)
            guard read > 0 else { return nil }
            return String(decoding: buffer.prefix(read), as: UTF8.self)
        }
    }

    /// Writes the attribute for `encoding` on the file at `url`.
    static func writeAttribute(for encoding: String.Encoding, to url: URL) throws {
        guard let value = attributeValue(for: encoding) else { return }
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return value.withCString { setxattr(path, encodingAttribute, $0, strlen($0), 0, 0) }
        }
        guard status == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSURLErrorKey: url,
                NSLocalizedFailureReasonErrorKey: "Could not record the text encoding (setxattr errno \(errno)).",
            ])
        }
    }

    // MARK: Line endings

    /// The same count over file bytes, fast (M8 n2): one byte at a time
    /// through `Sequence` it took 430 ms for 100 MB and 4.8 s for 1 GB,
    /// most of the time to open a big file. A file with no CR at all (most
    /// files) is LF at once, found with `memchr`. Otherwise the three
    /// counts are sums the compiler can run on many bytes at once: every
    /// LF, every CR, and every CR followed by LF. Same answer as the
    /// byte-by-byte count, ties included.
    static func mostCommonLineEnding(in data: Data) -> LineEnding {
        data.withUnsafeBytes { raw -> LineEnding in
            guard let base = raw.baseAddress, !raw.isEmpty else { return .lf }
            if memchr(base, 0x0D, raw.count) == nil { return .lf }
            let bytes = raw.bindMemory(to: UInt8.self)
            var lfTotal = 0, crTotal = 0, crlf = 0
            var previous: UInt8 = 0
            for byte in bytes {
                lfTotal &+= byte == 0x0A ? 1 : 0
                crTotal &+= byte == 0x0D ? 1 : 0
                crlf &+= (previous == 0x0D && byte == 0x0A) ? 1 : 0
                previous = byte
            }
            let lf = lfTotal - crlf, cr = crTotal - crlf
            if lf >= crlf && lf >= cr { return .lf }
            return crlf >= cr ? .crlf : .cr
        }
    }

    /// Counts LF, CRLF and lone CR in one pass. Ties go to LF, then CRLF,
    /// then CR; text with no line ending reports LF. Works on bytes of any
    /// encoding where CR and LF are single bytes (UTF-8 and the 8-bit and
    /// multi-byte legacy encodings).
    static func mostCommonLineEnding<Bytes: Sequence>(in bytes: Bytes) -> LineEnding where Bytes.Element == UInt8 {
        var lf = 0, crlf = 0, cr = 0
        var previousWasCR = false
        for byte in bytes {
            if byte == 0x0A {
                if previousWasCR { crlf += 1; cr -= 1 } else { lf += 1 }
                previousWasCR = false
            } else if byte == 0x0D {
                cr += 1
                previousWasCR = true
            } else {
                previousWasCR = false
            }
        }
        if lf >= crlf && lf >= cr { return .lf }
        return crlf >= cr ? .crlf : .cr
    }
}
