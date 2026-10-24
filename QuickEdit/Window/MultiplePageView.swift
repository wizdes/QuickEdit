import AppKit

/// The scroll view's document view in Wrap to Page mode: white pages with a
/// light gray frame around each text area and 5 pt gaps between pages. Each
/// page's text view is a subview. Port of reference/apple/MultiplePageView.m
/// without the vertical-layout branches.
final class MultiplePageView: NSView {
    /// A copy of the document's print info; it sets the page size and margins.
    var printInfo: NSPrintInfo {
        didSet {
            updateFrame()
            needsDisplay = true
        }
    }

    private(set) var numberOfPages = 0

    var lineColor = NSColor.lightGray { didSet { needsDisplay = true } }
    var marginColor = NSColor.white { didSet { needsDisplay = true } }

    /// Gap between pages (MultiplePageView.m:121-123).
    let pageSeparatorHeight: CGFloat = 5.0

    init(printInfo: NSPrintInfo) {
        self.printInfo = printInfo.copy() as! NSPrintInfo
        super.init(frame: .zero)
        // Pages are paper: they stay white with dark text in dark mode, as
        // TextEdit's do. The text views are subviews, so they inherit this
        // and NSColor.textColor resolves to black on them.
        appearance = NSAppearance(named: .aqua)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MultiplePageView is built in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateFrame()
    }

    /// Height = pages x paper height + the gaps between them (MultiplePageView.m:75-89).
    func updateFrame() {
        guard let superview else { return }
        var size = printInfo.paperSize
        size.height *= CGFloat(numberOfPages)
        if numberOfPages > 1 { size.height += pageSeparatorHeight * CGFloat(numberOfPages - 1) }
        setFrameSize(convert(size, to: superview))
    }

    func setNumberOfPages(_ count: Int) {
        guard count != numberOfPages else { return }
        let oldFrame = frame
        numberOfPages = count
        updateFrame()
        if frame.height > oldFrame.height {
            setNeedsDisplay(NSRect(x: oldFrame.minX, y: oldFrame.maxY,
                                   width: oldFrame.width, height: frame.maxY - oldFrame.maxY))
        }
    }

    /// Paper minus margins, plus the line padding on both sides (MultiplePageView.m:297-302).
    static func documentSize(for printInfo: NSPrintInfo) -> NSSize {
        var size = printInfo.paperSize
        size.width -= (printInfo.leftMargin + printInfo.rightMargin) - textPadding * 2
        size.height -= printInfo.topMargin + printInfo.bottomMargin
        return size
    }

    /// TextEdit's defaultTextPadding(): a new container's line fragment padding.
    static let textPadding: CGFloat = NSTextContainer().lineFragmentPadding

    var documentSizeInPage: NSSize { Self.documentSize(for: printInfo) }

    /// The text view's frame on page `page` (0-based): inside the margins,
    /// moved left by the padding (MultiplePageView.m:134-140).
    func documentRect(forPage page: Int) -> NSRect {
        var rect = pageRect(forPage: page)
        rect.origin.x += printInfo.leftMargin - Self.textPadding
        rect.origin.y += printInfo.topMargin
        rect.size = documentSizeInPage
        return rect
    }

    func pageRect(forPage page: Int) -> NSRect {
        let paper = printInfo.paperSize
        return NSRect(x: 0, y: (paper.height + pageSeparatorHeight) * CGFloat(page),
                      width: paper.width, height: paper.height)
    }

    /// The page at `point`; points on a gap belong to the page above it, and
    /// points past either end give the first or last page (MultiplePageView.m:157-169).
    func pageNumber(for point: NSPoint) -> Int {
        if point.y < 0 { return 0 }
        if point.y >= bounds.height { return max(0, numberOfPages - 1) }
        return min(Int(point.y / (printInfo.paperSize.height + pageSeparatorHeight)), max(0, numberOfPages - 1))
    }

    /// On screen only: margin color everywhere, a 1 pt frame around each
    /// page's text area, and the gaps in the clip view's color
    /// (MultiplePageView.m:207-247).
    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.current?.isDrawingToScreen ?? false, numberOfPages > 0 else { return }
        let step = printInfo.paperSize.height + pageSeparatorHeight
        let firstPage = max(0, Int(dirtyRect.minY / step))
        let lastPage = min(numberOfPages - 1, Int(dirtyRect.maxY / step))

        marginColor.setFill()
        dirtyRect.fill()

        lineColor.set()
        if firstPage <= lastPage {
            for page in firstPage...lastPage {
                let frameRect = centerScanRect(documentRect(forPage: page)).insetBy(dx: -1, dy: -1)
                frameRect.frame(withWidth: 1.0)
            }
        }

        if let clipView = superview as? NSClipView, firstPage <= lastPage {
            // The clip view draws in the window's appearance, not this view's
            // paper appearance, so its color is resolved there.
            var gapColor = clipView.backgroundColor
            clipView.effectiveAppearance.performAsCurrentDrawingAppearance {
                gapColor = clipView.backgroundColor.usingColorSpace(.deviceRGB) ?? clipView.backgroundColor
            }
            gapColor.setFill()
            for page in firstPage...lastPage {
                let pageRect = pageRect(forPage: page)
                NSRect(x: pageRect.minX, y: pageRect.maxY, width: pageRect.width, height: pageSeparatorHeight).fill()
            }
        }
    }

    // MARK: Smart magnification (MultiplePageView.m:251-274)

    override func rectForSmartMagnification(at location: NSPoint, in visibleRect: NSRect) -> NSRect {
        let page = pageNumber(for: location)
        let documentRect = documentRect(forPage: page).insetBy(dx: -3, dy: -3) // a bit of the margins
        let pageRect = pageRect(forPage: page)
        if documentRect.contains(location) { return documentRect }
        if pageRect.contains(location) { return pageRect }
        // Between pages or beside a page: the page plus the area around it.
        var result = pageRect
        if visibleRect.maxX > pageRect.maxX { result.size.width = visibleRect.maxX }
        if page + 1 < numberOfPages { result.size.height += pageSeparatorHeight }
        if location.y > result.maxY { result.size.height = (location.y - result.origin.y).rounded(.up) }
        return result
    }

    // MARK: Printing (M7 prints this view directly; MultiplePageView.m:278-292)

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: numberOfPages)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        documentRect(forPage: page - 1) // AppKit's pages start at 1
    }

    override func locationOfPrintRect(_ rect: NSRect) -> NSPoint {
        let paper = printInfo.paperSize
        return NSPoint(x: (paper.width - rect.width) / 2, y: (paper.height - rect.height) / 2)
    }
}
