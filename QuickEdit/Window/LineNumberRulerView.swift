import AppKit

/// The line-number gutter on the left of a document window (1.2.0): the
/// scroll view's vertical ruler. It numbers logical lines (a wrapped line
/// gets one number, on its first row) and draws only the lines on screen,
/// asking the layout manager about those glyphs only, so non-contiguous
/// layout stays fast. Line numbers come from the window's LineIndex; a
/// line the index has not reached yet gets no number until it has.
final class LineNumberRulerView: NSRulerView {
    /// The text view whose lines are numbered (the window's first view).
    weak var textView: NSTextView?
    let lineIndex: LineIndex
    /// Digits the thickness is sized for; at least 3.
    private(set) var digits = 0

    /// Space left and right of the numbers.
    static let leftPadding: CGFloat = 6
    static let rightPadding: CGFloat = 8
    static let minimumDigits = 3

    /// Dimmer than the text, and still 4.5:1 on the text background in
    /// light and dark mode (62% black or white, as the Keyboard tab's dim
    /// text).
    static let numberColor = NSColor(name: "QuickEditLineNumber") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.62)
            : NSColor(white: 0, alpha: 0.62)
    }

    init(scrollView: NSScrollView, lineIndex: LineIndex) {
        self.lineIndex = lineIndex
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        // Since macOS 14 a view may draw outside its bounds and its dirty
        // rect can reach past them; the gutter's background then covered
        // the text (measured 2026-10-26). It draws only inside itself.
        clipsToBounds = true
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        // Left out of the scroll view's accessibility children
        // (ScalingScrollView.accessibilityChildren): the numbers only help
        // the eye, and a ruler with no action fails the accessibility audit.
        setAccessibilityLabel("Line numbers")
        updateThickness()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("LineNumberRulerView is built in code") }

    /// Typing inside a line moves no number unless the line's wrapping
    /// changes, so the gutter is then redrawn at most this often instead
    /// of with each key.
    static let typingRedrawDelay: TimeInterval = 0.1
    private var redrawPending = false

    /// Redraws soon (typing inside a line); several calls make one redraw.
    func scheduleRedraw() {
        guard !redrawPending else { return }
        redrawPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.typingRedrawDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.redrawPending = false
                self.redraw()
            }
        }
    }

    /// The text view's visible rect at the last draw, and whether the
    /// next request must draw whatever it is.
    private var drawnVisibleRect: NSRect?
    private var mustRedraw = true

    /// Redraws the numbers (lines came or went, the text scrolled, the
    /// index found more lines, or the mode changed).
    func redraw() {
        mustRedraw = true
        needsDisplay = true
    }

    /// NSScrollView's reflectScrolledClipView: marks every ruler for
    /// display each time the text view's frame is set, which NSTextView
    /// does with every edit, even to the same size (measured 2026-10-26:
    /// 30 full redraws for 30 keys, about 0.7 ms each in a Debug build).
    /// Such a request is dropped while the visible text has not moved;
    /// `redraw()` always goes through.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        if !mustRedraw, let drawnVisibleRect, let textView, textView.visibleRect == drawnVisibleRect { return }
        super.setNeedsDisplay(invalidRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var requiredThickness: CGFloat { ruleThickness }

    /// The numbers' font: the system's digit-aligned font, a little
    /// smaller than the text.
    var numberFont: NSFont {
        let textSize = (textView?.typingAttributes[.font] as? NSFont)?.pointSize ?? TextViewFactory.defaultPlainFontSize
        return .monospacedDigitSystemFont(ofSize: max(9, (textSize * 0.85).rounded()), weight: .regular)
    }

    /// The gutter width for `digits` digits.
    func thickness(forDigits digits: Int) -> CGFloat {
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: numberFont]).width
        return (CGFloat(digits) * digitWidth + Self.leftPadding + Self.rightPadding).rounded(.up)
    }

    /// The text size the thickness was measured for.
    private var measuredTextSize: CGFloat = 0

    /// Widens (or narrows) the gutter to fit the line count. Cheap when
    /// the digit count and the text size have not changed.
    func updateThickness() {
        let needed = max(Self.minimumDigits, String(lineIndex.estimatedLineCount).count)
        let textSize = (textView?.typingAttributes[.font] as? NSFont)?.pointSize ?? TextViewFactory.defaultPlainFontSize
        guard needed != digits || textSize != measuredTextSize else { return }
        digits = needed
        measuredTextSize = textSize
        ruleThickness = thickness(forDigits: needed)
    }

    /// Times `draw` ran (tests).
    private(set) var drawCount = 0

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        mustRedraw = false
        drawnVisibleRect = textView?.visibleRect
        let dirty = dirtyRect.intersection(bounds)
        NSColor.textBackgroundColor.setFill()
        dirty.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: dirty.minY, width: 1, height: dirty.height).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    /// One number per logical line start on screen, right-aligned,
    /// centered on the first row of its line.
    override func drawHashMarksAndLabels(in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: Self.numberColor]
        for label in visibleLabels() {
            let text = String(label.number) as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.maxX - Self.rightPadding - size.width, y: label.y), withAttributes: attributes)
        }
    }

    /// The numbers on screen and the top of each, in this view's
    /// coordinates. Only the visible glyphs are asked about.
    func visibleLabels() -> [(number: Int, y: CGFloat)] {
        guard !lineIndex.isPaused, let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage else { return [] }
        var visible = textView.visibleRect
        visible.origin.x -= textView.textContainerOrigin.x
        visible.origin.y -= textView.textContainerOrigin.y
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let length = storage.length
        // The first line on screen may start above it: number from there.
        guard let firstLine = lineIndex.line(containing: characters.location),
              let firstStart = lineIndex.lineStart(firstLine) else { return [] }
        let end = NSMaxRange(characters) >= length ? length : NSMaxRange(characters)
        let found = lineIndex.lineStarts(in: NSRange(location: firstStart, length: end - firstStart))
        let font = numberFont
        let numberHeight = font.ascender - font.descender
        var labels: [(number: Int, y: CGFloat)] = []
        var lastBottom = -CGFloat.greatestFiniteMagnitude
        for (offset, start) in found.starts.enumerated() {
            let lineRect: NSRect
            if start >= length {
                // The empty last line after a final line end.
                lineRect = layoutManager.extraLineFragmentRect
                if lineRect.isEmpty { continue }
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            let middle = NSPoint(x: 0, y: lineRect.midY + textView.textContainerOrigin.y)
            let y = convert(middle, from: textView).y - numberHeight / 2
            // Zoomed far out, rows are shorter than a number: skip overlaps.
            if y < lastBottom { continue }
            labels.append((firstLine + offset + 1, y))
            lastBottom = y + numberHeight
        }
        return labels
    }
}
