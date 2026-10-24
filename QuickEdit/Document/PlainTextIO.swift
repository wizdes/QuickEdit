import Foundation

/// Bytes on disk <-> text, with the details needed to write the same bytes back.
/// Pure functions, no AppKit (contract `io-plain`, Doc B section 3).
///
/// Line endings: the text keeps every line ending exactly as found (CR, LF,
/// CRLF, mixed). `Format.lineEnding` records the most common one so later
/// milestones can type it; `encode` never converts line endings.
struct DecodedText: Equatable, Sendable {
    var text: String
    var format: Format

    struct Format: Equatable, Sendable {
        var encoding: String.Encoding
        var hasBOM: Bool
        var lineEnding: LineEnding

        /// What a new, untitled document writes: UTF-8, no BOM, LF.
        static let newDocument = Format(encoding: .utf8, hasBOM: false, lineEnding: .lf)
    }
}

enum LineEnding: String, Equatable, Sendable {
    case lf, crlf, cr
}

enum PlainTextIO {
    enum Error: Swift.Error, Equatable {
        /// The bytes are not valid UTF-8. M3 adds other encodings.
        case notUTF8
        /// `encode` was asked for an encoding this milestone cannot write.
        case unsupportedEncoding(String.Encoding)
    }

    static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    static func decode(_ data: Data) throws -> DecodedText {
        let hasBOM = data.starts(with: utf8BOM)
        let body = hasBOM ? data.dropFirst(utf8BOM.count) : data[...]
        // String(validating:) checks every byte and, unlike String(data:encoding:),
        // never strips a BOM or repairs bad bytes.
        guard let text = String(validating: body, as: UTF8.self) else {
            throw Error.notUTF8
        }
        return DecodedText(text: text,
                           format: .init(encoding: .utf8, hasBOM: hasBOM, lineEnding: mostCommonLineEnding(in: body)))
    }

    static func encode(_ text: String, as format: DecodedText.Format) throws -> Data {
        guard format.encoding == .utf8 else { throw Error.unsupportedEncoding(format.encoding) }
        var data = Data()
        let utf8 = text.utf8
        data.reserveCapacity(utf8.count + (format.hasBOM ? utf8BOM.count : 0))
        if format.hasBOM { data.append(contentsOf: utf8BOM) }
        data.append(contentsOf: utf8)
        return data
    }

    /// Counts LF, CRLF and lone CR in one pass over the bytes. Ties go to LF,
    /// then CRLF, then CR; a file with no line ending reports LF.
    static func mostCommonLineEnding<Bytes: Collection>(in bytes: Bytes) -> LineEnding where Bytes.Element == UInt8 {
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
