import Foundation

/// Fills a text storage from checked UTF-8 bytes (M8, vote V3), so a file
/// is in memory once, as the storage's own text. The old path made a whole
/// String first and then the storage copied it: two copies of a 1 GB file
/// at the peak. Here only one piece at a time is a String.
enum LargeFileText {
    /// Bytes per piece: big enough that the piece count does not matter
    /// (128 for 1 GB), small next to the text.
    static let pieceBytes = 8 * 1024 * 1024

    /// Replaces all of `storage` with the text of `bytes`, which must be
    /// valid UTF-8 (`PlainTextIO.isValidUTF8`), and gives it `attributes`.
    /// Same text and attributes as one `NSAttributedString(string:attributes:)`
    /// replacement: a piece never ends inside a character, and a piece is
    /// decoded by Swift, which (unlike CFString) never drops a U+FEFF at
    /// its start. One editing session, so AppKit fixes the attributes once.
    /// Any thread, while the storage has no layout manager.
    static func fill(_ storage: NSMutableAttributedString, withUTF8 bytes: Data,
                     attributes: [NSAttributedString.Key: Any], pieceBytes: Int = pieceBytes) {
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
        bytes.withUnsafeBytes { raw in
            let all = raw.bindMemory(to: UInt8.self)
            let size = max(1, pieceBytes)
            var start = 0
            while start < all.count {
                var end = min(all.count, start + size)
                // Back up to the start of a character (a byte that is not
                // 10xxxxxx); a piece smaller than one character grows instead.
                while end < all.count, end > start, all[end] & 0xC0 == 0x80 { end -= 1 }
                if end == start {
                    end = min(all.count, start + size)
                    while end < all.count, all[end] & 0xC0 == 0x80 { end += 1 }
                }
                let piece = String(decoding: UnsafeBufferPointer(rebasing: all[start..<end]), as: UTF8.self)
                storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: piece)
                start = end
            }
        }
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }
}
