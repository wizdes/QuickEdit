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
    /// The bytes did not fit any encoding and some were replaced to show the
    /// text. Saving over such a file loses data, so the document warns first.
    var lossy = false

    struct Format: Equatable, Sendable {
        /// For UTF-16 and UTF-32, `.utf16` / `.utf32` mean "little-endian
        /// with a BOM" (what AppKit writes for them); a big-endian file keeps
        /// `.utf16BigEndian` / `.utf32BigEndian` so it is written back as found.
        var encoding: String.Encoding
        var hasBOM: Bool
        var lineEnding: LineEnding

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

    /// Turns file bytes into text (docs/plans/M3.md n1 step 1).
    /// - `preferred`: an explicit choice (Open panel, `PlainTextEncoding`
    ///   default). It wins; bytes that do not fit throw `inapplicableEncoding`.
    /// - Else, in order: the `com.apple.TextEncoding` xattr of `url`, a BOM,
    ///   strict UTF-8, NSString's guess with `suggested` encodings, then
    ///   `fallback` (AppKit's own last step: the system's default C-string
    ///   encoding, Mac Roman on an English Mac). A step whose encoding does
    ///   not fit the bytes is skipped.
    /// - Only if even `fallback` fails is the text decoded lossily (UTF-8
    ///   with replacement characters) and marked `lossy`.
    static func decode(_ data: Data, url: URL? = nil, preferred: String.Encoding? = nil,
                       suggested: [String.Encoding] = [],
                       fallback: String.Encoding = String.defaultCStringEncoding) throws -> DecodedText {
        if let preferred {
            guard let decoded = decode(data, as: preferred) else { throw Error.inapplicableEncoding(preferred) }
            return decoded
        }
        if let url, let named = encodingNamedByAttribute(of: url), let decoded = decode(data, as: named) {
            return decoded
        }
        if let decoded = decodeByBOM(data) { return decoded }
        if let text = String(validating: data, as: UTF8.self) {
            return DecodedText(text: text, format: .init(encoding: .utf8, hasBOM: false,
                                                         lineEnding: mostCommonLineEnding(in: data)))
        }
        if let decoded = guess(data, suggested: suggested) { return decoded }
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
            return decodeUnicode(data, bom: nil, body: .utf16BigEndian, as: .utf16BigEndian)
        case .utf16LittleEndian:
            return decodeUnicode(data, bom: data.starts(with: utf16LEBOM) ? utf16LEBOM : nil, body: encoding, as: encoding)
        case .utf16BigEndian:
            return decodeUnicode(data, bom: data.starts(with: utf16BEBOM) ? utf16BEBOM : nil, body: encoding, as: encoding)
        case .utf32:
            if data.starts(with: utf32LEBOM) { return decodeUnicode(data, bom: utf32LEBOM, body: .utf32LittleEndian, as: .utf32) }
            if data.starts(with: utf32BEBOM) { return decodeUnicode(data, bom: utf32BEBOM, body: .utf32BigEndian, as: .utf32BigEndian) }
            return decodeUnicode(data, bom: nil, body: .utf32BigEndian, as: .utf32BigEndian)
        case .utf32LittleEndian:
            return decodeUnicode(data, bom: data.starts(with: utf32LEBOM) ? utf32LEBOM : nil, body: encoding, as: encoding)
        case .utf32BigEndian:
            return decodeUnicode(data, bom: data.starts(with: utf32BEBOM) ? utf32BEBOM : nil, body: encoding, as: encoding)
        default:
            guard let text = String(data: data, encoding: encoding) else { return nil }
            return DecodedText(text: text, format: .init(encoding: encoding, hasBOM: false,
                                                         lineEnding: mostCommonLineEnding(in: data)))
        }
    }

    /// UTF-16 or UTF-32 body after an optional BOM. Line endings are counted
    /// on the decoded text, since CR and LF are not single bytes here.
    private static func decodeUnicode(_ data: Data, bom: [UInt8]?, body bodyEncoding: String.Encoding,
                                      as recorded: String.Encoding) -> DecodedText? {
        let body = data.dropFirst(bom?.count ?? 0)
        let unit = (bodyEncoding == .utf32LittleEndian || bodyEncoding == .utf32BigEndian) ? 4 : 2
        guard body.count % unit == 0, let text = String(data: Data(body), encoding: bodyEncoding) else { return nil }
        return DecodedText(text: text, format: .init(encoding: recorded, hasBOM: bom != nil,
                                                     lineEnding: mostCommonLineEnding(in: text.utf8)))
    }

    /// UTF-32 BOMs first: the UTF-32 LE BOM starts with the UTF-16 LE one.
    private static func decodeByBOM(_ data: Data) -> DecodedText? {
        if data.starts(with: utf32LEBOM) || data.starts(with: utf32BEBOM) { return decode(data, as: .utf32) }
        if data.starts(with: utf16LEBOM) || data.starts(with: utf16BEBOM) { return decode(data, as: .utf16) }
        if data.starts(with: utf8BOM) { return decode(data, as: .utf8) }
        return nil
    }

    /// NSString's encoding guess. Taken only when it returns a string and that
    /// string encodes back to the very same bytes, so saving an unchanged file
    /// never changes it.
    private static func guess(_ data: Data, suggested: [String.Encoding]) -> DecodedText? {
        var converted: NSString?
        var usedLossy: ObjCBool = false
        var options: [StringEncodingDetectionOptionsKey: Any] = [.allowLossyKey: false]
        if !suggested.isEmpty { options[.suggestedEncodingsKey] = suggested.map { NSNumber(value: $0.rawValue) } }
        let raw = NSString.stringEncoding(for: data, encodingOptions: options,
                                          convertedString: &converted, usedLossyConversion: &usedLossy)
        // It can return an encoding with no string (seen: 4 for EUC-JP bytes);
        // no string means no guess.
        guard raw != 0, let converted, !usedLossy.boolValue else { return nil }
        let encoding = String.Encoding(rawValue: raw)
        let decoded = DecodedText(text: converted as String,
                                  format: .init(encoding: encoding, hasBOM: false,
                                                lineEnding: mostCommonLineEnding(in: data)))
        guard let back = try? encode(decoded.text, as: decoded.format), back == data else { return nil }
        return decoded
    }

    // MARK: Encoding

    /// Writes `text` in `format`: a BOM exactly when `hasBOM` (UTF-8,
    /// UTF-16 LE/BE, UTF-32 LE/BE), always a BOM and little-endian for plain
    /// `.utf16` and `.utf32` (as AppKit writes them). Never converts line endings.
    static func encode(_ text: String, as format: DecodedText.Format) throws -> Data {
        switch format.encoding {
        case .utf8:
            var data = Data()
            let utf8 = text.utf8
            data.reserveCapacity(utf8.count + (format.hasBOM ? utf8BOM.count : 0))
            if format.hasBOM { data.append(contentsOf: utf8BOM) }
            data.append(contentsOf: utf8)
            return data
        case .utf16: return try unicode(text, bom: utf16LEBOM, body: .utf16LittleEndian)
        case .utf32: return try unicode(text, bom: utf32LEBOM, body: .utf32LittleEndian)
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
    /// `windows-1252;1280`, `utf-8;134217984`). Nil for an encoding with no
    /// IANA name.
    static func attributeValue(for encoding: String.Encoding) -> String? {
        let cf = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        guard cf != kCFStringEncodingInvalidId,
              let name = CFStringConvertEncodingToIANACharSetName(cf) as String? else { return nil }
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
