import AppKit

/// QuickEdit's own PDF writer (M7 review item 2, user decision U1).
/// NSPrintOperation opens a connection to macOS's print system
/// (com.apple.printtool.agent) even when it only saves a PDF, so QuickEdit
/// lays out the pages itself and draws each one into a Core Graphics PDF
/// context. Measured 2026-10-24 with a probe in a fresh process, checking the
/// system log: NSPrintOperation to a PDF 1 connection, this path 0. Both
/// view modes use the same pages: a copy of the text, laid out at the
/// width the mode prints at.
@MainActor
enum PDFRenderer {
    /// One page: a band of the laid-out text, from `top` down `height`
    /// points (in the text container's space), drawn with its top-left at
    /// `origin` (points from the paper's top-left) and scaled by `scale`.
    /// `height` is never more than the page's text area, and drawing is
    /// clipped to it, so a line taller than the page is cut off there and
    /// never reaches the footer or the paper's edge (M7 re-review item 2).
    struct Page {
        let glyphs: NSRange
        let top: CGFloat
        let height: CGFloat
        let origin: NSPoint
        let scale: CGFloat
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

    /// The pages of a copy of the text laid out at `width`. A width wider
    /// than the page's text area is scaled down to fit, as AppKit's
    /// fit-to-width pagination did (Document.m:683). The copy is laid out
    /// in one tall container and pages break between lines: a page takes
    /// every whole line that fits, as TextKit fills one page-high container
    /// (Wrap to Page) and NSTextView breaks printed pages. One container is
    /// about 6 times faster for 1 MB than one container per page (probe
    /// 2026-10-24: 460 ms against 2.7 s). The copy has its own layout
    /// manager, so the document's text never gets a second one.
    final class Pagination {
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let pages: [Page]

        /// `origin`: where the text container's top-left goes on the paper.
        /// `scalesToFit` false prints at full size, for Wrap to Page, whose
        /// text view reaches one padding into each side margin.
        init(text: NSAttributedString, width: CGFloat, layout: PageLayout, origin: NSPoint, scalesToFit: Bool) {
            storage = NSTextStorage(attributedString: text)
            layoutManager = NSLayoutManager()
            storage.addLayoutManager(layoutManager)
            let textWidth = layout.paperSize.width - layout.leftMargin - layout.rightMargin
            let textHeight = layout.paperSize.height - layout.topMargin - layout.bottomMargin
            let scale = scalesToFit && width > textWidth ? textWidth / width : 1
            let pageHeight = textHeight / scale
            let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)

            // Every line, plus the empty line after a final line end, which
            // is a line too, as on screen, and can start a page of its own.
            var lines: [(rect: NSRect, glyphs: NSRange)] = []
            let all = NSRange(location: 0, length: layoutManager.numberOfGlyphs)
            layoutManager.enumerateLineFragments(forGlyphRange: all) { rect, _, _, glyphs, _ in
                lines.append((rect, glyphs))
            }
            let extra = layoutManager.extraLineFragmentRect
            if layoutManager.extraLineFragmentTextContainer != nil, extra.height > 0 {
                lines.append((extra, NSRange(location: all.length, length: 0)))
            }

            var pages: [Page] = []
            var index = 0
            repeat {
                let top = index < lines.count ? lines[index].rect.minY : 0
                var bottom = top
                var glyphs = NSRange(location: index < lines.count ? lines[index].glyphs.location : 0, length: 0)
                // Whole lines that fit; a line taller than a page goes alone
                // on its own page, cut off at the bottom of the text area.
                while index < lines.count,
                      lines[index].rect.maxY - top <= pageHeight + 0.001 || bottom == top {
                    bottom = lines[index].rect.maxY
                    glyphs = NSUnionRange(glyphs, lines[index].glyphs)
                    index += 1
                }
                pages.append(Page(glyphs: glyphs, top: top, height: min(max(bottom - top, 0), pageHeight),
                                  origin: origin, scale: scale))
            } while index < lines.count
            self.pages = pages
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
    @discardableResult
    static func write(_ pagination: Pagination, layout: PageLayout, header: Header?, to url: URL) throws -> Int {
        let pages = pagination.pages
        let layoutManager = pagination.layoutManager
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
        light.performAsCurrentDrawingAppearance {
            for (index, page) in pages.enumerated() {
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
                context.translateBy(x: 0, y: -page.top)
                // Only this page's lines, inside the text area: the next
                // page's first line must not show at the bottom, and a line
                // taller or wider than the area is cut off at its edges.
                let width = pagination.layoutManager.textContainers.first?.size.width ?? layout.paperSize.width
                context.clip(to: CGRect(x: 0, y: page.top, width: width, height: page.height))
                if page.glyphs.length > 0 {
                    layoutManager.drawGlyphs(forGlyphRange: page.glyphs, at: .zero)
                }
                context.restoreGState()
                if header != nil {
                    drawFooter("Page \(index + 1) of \(pages.count)", layout: layout)
                }
                context.restoreGState()
                context.endPDFPage()
            }
        }
        context.closePDF()
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
