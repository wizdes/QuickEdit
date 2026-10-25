import AppKit
import Synchronization

/// One PDF write that runs off the main thread (M8 n6): its progress, and
/// a Cancel flag the drawing checks between slices and pages.
final class PDFJob: Sendable {
    private struct State {
        var cancelled = false
        var fraction = 0.0
    }
    private let state = Mutex(State())

    /// Stop at the next check; the write then throws `CocoaError(.userCancelled)`.
    func cancel() { state.withLock { $0.cancelled = true } }
    var isCancelled: Bool { state.withLock { $0.cancelled } }
    /// 0 to 1: laying out is the first half, drawing the pages the second.
    var fraction: Double { state.withLock { $0.fraction } }

    func report(_ fraction: Double) {
        state.withLock { $0.fraction = min(1, max($0.fraction, fraction)) }
    }

    func checkCancelled() throws {
        if isCancelled { throw CocoaError(.userCancelled) }
    }
}

/// QuickEdit's own PDF writer (M7 review item 2, user decision U1).
/// NSPrintOperation opens a connection to macOS's print system
/// (com.apple.printtool.agent) even when it only saves a PDF, so QuickEdit
/// lays out the pages itself and draws each one into a Core Graphics PDF
/// context. Measured 2026-10-24 with a probe in a fresh process, checking the
/// system log: NSPrintOperation to a PDF 1 connection, this path 0. Both
/// view modes use the same pages: a copy of the text, laid out at the
/// width the mode prints at.
///
/// Not tied to the main thread (M8 n6): a large document is drawn on a
/// background thread from a copy of its text, with its own layout manager,
/// as TextKit 1 allows when one thread owns those objects.
enum PDFRenderer {
    /// One page: bands of the laid-out text (`segments`, top to bottom),
    /// drawn with their top-left at `origin` (points from the paper's
    /// top-left) and scaled by `scale`. The bands together are never taller
    /// than the page's text area, and drawing is clipped to each band, so a
    /// line taller than the page is cut off there and never reaches the
    /// footer or the paper's edge (M7 re-review item 2).
    struct Page {
        var segments: [Segment]
        let origin: NSPoint
        let scale: CGFloat
    }

    /// One band of one piece of the text: its glyphs, from `top` down
    /// `height` points in that piece's text container.
    struct Segment {
        let piece: Int
        let glyphs: NSRange
        let top: CGFloat
        let height: CGFloat
    }

    /// TextEdit's header and footer: the name and the date at the top,
    /// "Page N of M" at the bottom.
    struct Header {
        var title: String
        var date: String

        /// The date as the header shows it: short date and time.
        static func dateText(for date: Date) -> String {
            DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
        }
    }

    /// The pages of the text laid out at `width`. A width wider than the
    /// page's text area is scaled down to fit, as AppKit's fit-to-width
    /// pagination did (Document.m:683). Pages break between lines: a page
    /// takes every whole line that fits, as TextKit fills one page-high
    /// container (Wrap to Page) and NSTextView breaks printed pages. One
    /// tall container per piece is about 6 times faster for 1 MB than one
    /// container per page (probe 2026-10-24: 460 ms against 2.7 s). Each
    /// piece has its own layout manager, so the document's text never gets
    /// a second one.
    ///
    /// Pieces (M8 n6): the text is laid out in pieces of about
    /// `pieceLength` characters that end at paragraph ends, so memory does
    /// not grow with the whole text. Each paragraph is laid out the same
    /// alone as after the paragraphs before it, and pages are packed from
    /// the lines of each piece in turn, so the pages are the same as with
    /// one container; a page can hold the end of one piece and the start of
    /// the next. Text up to `keepsAllUpTo` characters keeps every piece's
    /// layout for drawing; longer text drops each piece once paged and lays
    /// it out again to draw it, keeping about two pieces at a time.
    final class Pagination {
        static let pieceLength = 1 << 20
        static let keepsAllUpTo = 16 << 20

        let text: NSAttributedString
        let width: CGFloat
        /// Character ranges of the pieces, in order.
        let pieces: [NSRange]
        private(set) var pages: [Page] = []
        private var laidOut: [Int: Piece] = [:]

        /// One piece's own storage, layout manager and container.
        final class Piece {
            let storage: NSTextStorage
            let layoutManager = NSLayoutManager()

            init(_ text: NSAttributedString, range: NSRange, width: CGFloat) {
                // Laid out off the main thread: AppKit's background layout
                // would run on the main run loop, so it is off (Apple's
                // rule for a layout manager used on another thread; M8
                // review row 5). `layOut` lays out the piece itself.
                layoutManager.backgroundLayoutEnabled = false
                storage = NSTextStorage(attributedString: text.attributedSubstring(from: range))
                storage.addLayoutManager(layoutManager)
                let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
                layoutManager.addTextContainer(container)
            }
        }

        /// `origin`: where the text container's top-left goes on the paper.
        /// `scalesToFit` false prints at full size, for Wrap to Page, whose
        /// text view reaches one padding into each side margin.
        /// With a `job`, Cancel is checked between slices of layout and the
        /// first half of the progress is reported; a cancelled job throws
        /// `CocoaError(.userCancelled)`.
        /// `pieceLength` and `keepsAllUpTo` are for tests.
        init(text: NSAttributedString, width: CGFloat, layout: PageLayout, origin: NSPoint, scalesToFit: Bool,
             job: PDFJob? = nil, pieceLength: Int = Pagination.pieceLength,
             keepsAllUpTo: Int = Pagination.keepsAllUpTo) throws {
            self.text = text
            self.width = width
            let textWidth = layout.paperSize.width - layout.leftMargin - layout.rightMargin
            let textHeight = layout.paperSize.height - layout.topMargin - layout.bottomMargin
            let scale = scalesToFit && width > textWidth ? textWidth / width : 1
            let pageHeight = textHeight / scale
            pieces = Self.pieces(of: text.string as NSString, length: pieceLength)
            let keepsAll = text.length <= keepsAllUpTo
            let length = max(1, text.length)

            // The page being filled: its closed bands, and the open band in
            // the current piece.
            var segments: [Segment] = []
            var closedHeight: CGFloat = 0
            var open: (piece: Int, top: CGFloat, bottom: CGFloat, glyphs: NSRange)?
            var pages: [Page] = []
            func used() -> CGFloat { closedHeight + (open.map { $0.bottom - $0.top } ?? 0) }
            func closeBand() {
                guard let band = open else { return }
                let height = min(band.bottom - band.top, max(0, pageHeight - closedHeight))
                segments.append(Segment(piece: band.piece, glyphs: band.glyphs, top: band.top, height: max(0, height)))
                closedHeight += band.bottom - band.top
                open = nil
            }
            func closePage() {
                closeBand()
                pages.append(Page(segments: segments, origin: origin, scale: scale))
                segments = []
                closedHeight = 0
            }
            /// One line, as the M7 loop took them: it joins the page when it
            /// fits, or when the page is still empty (a line taller than a
            /// page goes alone on its own page).
            func add(_ rect: NSRect, _ glyphs: NSRange, piece: Int) {
                // The page's height with this line: from the page's first
                // line to this one, as in one tall container.
                let height: CGFloat
                if let band = open, band.piece == piece {
                    height = closedHeight + (rect.maxY - band.top)
                } else {
                    height = used() + (rect.maxY - rect.minY)
                }
                let fits = height <= pageHeight + 0.001
                if !(fits || used() == 0) { closePage() }
                if let band = open, band.piece == piece {
                    open = (piece, band.top, rect.maxY, NSUnionRange(band.glyphs, glyphs))
                } else {
                    closeBand()
                    open = (piece, rect.minY, rect.maxY, glyphs)
                }
            }

            for (index, range) in pieces.enumerated() {
                // Each piece's temporary objects go when it is done: on a
                // background thread the job is one block, whose own pool
                // drains only at its end (all pieces at once otherwise).
                try autoreleasepool {
                    let piece = Piece(text, range: range, width: width)
                    let manager = piece.layoutManager
                    try Self.layOut(piece, job: job) { done in
                        job?.report(0.5 * Double(range.location + done) / Double(length))
                    }
                    let all = NSRange(location: 0, length: manager.numberOfGlyphs)
                    manager.enumerateLineFragments(forGlyphRange: all) { rect, _, _, glyphs, _ in
                        add(rect, glyphs, piece: index)
                    }
                    // The empty line after a final line end is a line too, as
                    // on screen, and can start a page of its own (last piece only).
                    let extra = manager.extraLineFragmentRect
                    if index == pieces.count - 1, manager.extraLineFragmentTextContainer != nil, extra.height > 0 {
                        add(extra, NSRange(location: all.length, length: 0), piece: index)
                    }
                    if keepsAll { laidOut[index] = piece }
                }
            }
            if !segments.isEmpty || open != nil || pages.isEmpty { closePage() }
            self.pages = pages
        }

        /// Pieces of about `pieceLength` characters, each ending at a
        /// paragraph end (or the text's end); a longer paragraph is one
        /// piece. Empty text is one empty piece, so it still makes a page.
        static func pieces(of string: NSString, length pieceLength: Int = pieceLength) -> [NSRange] {
            let length = string.length
            guard length > 0 else { return [NSRange(location: 0, length: 0)] }
            var pieces: [NSRange] = []
            var start = 0
            while start < length {
                var end = min(length, start + pieceLength)
                if end < length {
                    let paragraph = string.paragraphRange(for: NSRange(location: end, length: 0))
                    end = paragraph.location > start ? paragraph.location : NSMaxRange(paragraph)
                }
                pieces.append(NSRange(location: start, length: end - start))
                start = end
            }
            return pieces
        }

        /// Lays out a whole piece: glyphs first, then layout, in slices of
        /// 256K characters (the first layout call would otherwise make all
        /// the glyphs in one piece), checking Cancel between slices.
        private static func layOut(_ piece: Piece, job: PDFJob?, progress: (Int) -> Void) throws {
            let manager = piece.layoutManager
            let length = piece.storage.length
            let slice = 262_144
            var done = 0
            while done < length {
                try job?.checkCancelled()
                let range = NSRange(location: done, length: min(slice, length - done))
                manager.ensureGlyphs(forCharacterRange: range)
                done = NSMaxRange(range)
            }
            done = 0
            while done < length {
                try job?.checkCancelled()
                done = min(length, done + slice)
                manager.ensureLayout(forCharacterRange: NSRange(location: done - 1, length: 1))
                progress(done)
            }
            if let container = manager.textContainers.first { manager.ensureLayout(for: container) }
            try job?.checkCancelled()
        }

        /// The layout of piece `index` for drawing: kept from paging, or
        /// laid out again (then the pieces before it are dropped; pages are
        /// drawn in order).
        func piece(_ index: Int, job: PDFJob?) throws -> Piece {
            if let piece = laidOut[index] { return piece }
            for key in laidOut.keys where key < index { laidOut[key] = nil }
            return try autoreleasepool {
                let piece = Piece(text, range: pieces[index], width: width)
                try Self.layOut(piece, job: job) { _ in }
                laidOut[index] = piece
                return piece
            }
        }
    }

    /// Draws `pages` into a new PDF file at `url`, each on paper of
    /// `layout`'s size, with the header and footer when `header` is set.
    /// Text is drawn in the light look: paper is white in dark mode too.
    /// Returns the number of pages drawn. Core Graphics reports no result
    /// for a page or for closing the file (beginPDFPage, endPDFPage and
    /// closePDF return nothing), so this throws when the context cannot be
    /// made or no file is there after closing; the caller then checks that
    /// the file is a whole PDF with this many pages (`TextDocument.checkPDF`).
    /// With a `job`, Cancel is checked before each page and the second
    /// half of the progress is reported.
    @discardableResult
    static func write(_ pagination: Pagination, layout: PageLayout, header: Header?, to url: URL,
                      job: PDFJob? = nil) throws -> Int {
        let pages = pagination.pages
        var mediaBox = CGRect(origin: .zero, size: layout.paperSize)
        var info: [CFString: Any] = [kCGPDFContextCreator: "QuickEdit"]
        if let header { info[kCGPDFContextTitle] = header.title }
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSURLErrorKey: url,
                NSLocalizedDescriptionKey: "The PDF \u{201C}\(url.lastPathComponent)\u{201D} could not be written.",
            ])
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let paper = layout.paperSize
        let light = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        var drawn = 0
        var stopped: Error?
        light.performAsCurrentDrawingAppearance {
            for (index, page) in pages.enumerated() { autoreleasepool {
                // After Cancel or a failure, the pages left are skipped.
                if stopped != nil { return }
                if let job {
                    do {
                        try job.checkCancelled()
                    } catch {
                        stopped = error
                        return
                    }
                    job.report(0.5 + 0.5 * Double(index) / Double(pages.count))
                }
                drawn += 1
                context.beginPDFPage(nil)
                context.saveGState()
                // Top-left origin, y down, as the text views draw.
                context.translateBy(x: 0, y: paper.height)
                context.scaleBy(x: 1, y: -1)
                if let header {
                    drawHeader(header, layout: layout)
                }
                context.saveGState()
                context.translateBy(x: page.origin.x, y: page.origin.y)
                context.scaleBy(x: page.scale, y: page.scale)
                // Only this page's lines, inside the text area: the next
                // page's first line must not show at the bottom, and a line
                // taller or wider than the area is cut off at its edges.
                var y: CGFloat = 0
                for segment in page.segments {
                    let piece: Pagination.Piece
                    do {
                        piece = try pagination.piece(segment.piece, job: job)
                    } catch {
                        stopped = error
                        context.restoreGState()
                        context.restoreGState()
                        context.endPDFPage()
                        return
                    }
                    context.saveGState()
                    context.translateBy(x: 0, y: y - segment.top)
                    context.clip(to: CGRect(x: 0, y: segment.top, width: pagination.width, height: segment.height))
                    if segment.glyphs.length > 0 {
                        piece.layoutManager.drawGlyphs(forGlyphRange: segment.glyphs, at: .zero)
                    }
                    context.restoreGState()
                    y += segment.height
                }
                context.restoreGState()
                if header != nil {
                    drawFooter("Page \(index + 1) of \(pages.count)", layout: layout)
                }
                context.restoreGState()
                context.endPDFPage()
            } }
        }
        context.closePDF()
        if let stopped { throw stopped }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSURLErrorKey: url,
                NSLocalizedDescriptionKey: "The PDF \u{201C}\(url.lastPathComponent)\u{201D} could not be written.",
            ])
        }
        return drawn
    }

    private static var headerAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black, .paragraphStyle: style]
    }

    /// The name at the left and the date at the right, in the middle of
    /// the top margin, both inside the text's left and right edges.
    private static func drawHeader(_ header: Header, layout: PageLayout) {
        let attributes = headerAttributes
        let date = NSAttributedString(string: header.date, attributes: attributes)
        let dateSize = date.size()
        let lineHeight = ceil(dateSize.height)
        let y = (layout.topMargin - lineHeight) / 2
        let right = layout.paperSize.width - layout.rightMargin
        date.draw(at: NSPoint(x: right - dateSize.width, y: y))
        let titleWidth = max(0, right - dateSize.width - 18 - layout.leftMargin)
        NSAttributedString(string: header.title, attributes: attributes)
            .draw(with: NSRect(x: layout.leftMargin, y: y, width: titleWidth, height: lineHeight),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// "Page N of M" at the right, in the middle of the bottom margin.
    private static func drawFooter(_ text: String, layout: PageLayout) {
        let footer = NSAttributedString(string: text, attributes: headerAttributes)
        let size = footer.size()
        let y = layout.paperSize.height - layout.bottomMargin + (layout.bottomMargin - ceil(size.height)) / 2
        footer.draw(at: NSPoint(x: layout.paperSize.width - layout.rightMargin - size.width, y: y))
    }
}
