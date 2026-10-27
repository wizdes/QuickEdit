import AppKit

/// The document map on the right of a document window (1.2.0; Sublime
/// Text calls it the minimap). Each logical line is one row `rowHeight`
/// points tall, drawn as small blocks for its runs of non-space
/// characters, read straight from the string (never through the layout
/// manager), and only for the rows the map shows. A shaded box marks the
/// lines on screen. When the text has more rows than the map, the map
/// scrolls along with the text, in proportion. A click or drag scrolls the
/// text: a click centers the clicked line; dragging the box moves it.
final class DocumentMapView: NSView {
    static let width: CGFloat = 100
    static let rowHeight: CGFloat = 2
    static let columnWidth: CGFloat = 1
    /// Height of a row's blocks; the rest of the row is the gap below.
    static let blockHeight: CGFloat = 1.4
    /// While typing, the rows are redrawn at most this often; the box
    /// follows scrolling at once.
    static let editRedrawDelay: TimeInterval = 0.1

    /// The text view the map shows (the window's first view).
    weak var textView: NSTextView?
    let lineIndex: LineIndex
    private var editRedrawPending = false
    /// Where in the box the drag holds it, in points from its top.
    private var dragOffset: CGFloat?

    init(lineIndex: LineIndex) {
        self.lineIndex = lineIndex
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        // Draw only inside the map: since macOS 14 the dirty rect can reach
        // past a view's bounds, and the map's background covered the text
        // (measured 2026-10-26).
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Document map")
        setAccessibilityHelp("Click or drag to scroll the text.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("DocumentMapView is built in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Rows that fit in the map.
    var visibleRows: Int { max(1, Int(bounds.height / Self.rowHeight)) }

    // MARK: Geometry

    /// What the map shows now: the lines on screen in the text, the line
    /// count, and the first line the map shows (fractional while it
    /// scrolls with the text).
    struct Geometry: Equatable {
        var firstVisibleLine: Int
        var lastVisibleLine: Int
        var lineCount: Int
        var mapTopLine: Double

        /// The box, in the map's coordinates.
        func box(width: CGFloat) -> NSRect {
            let top = (Double(firstVisibleLine) - mapTopLine) * Double(DocumentMapView.rowHeight)
            let height = Double(lastVisibleLine - firstVisibleLine + 1) * Double(DocumentMapView.rowHeight)
            return NSRect(x: 0, y: top, width: Double(width), height: height)
        }
    }

    /// The map's top line for `lineCount` lines of which `first` … `last`
    /// are on screen, with `rows` map rows: 0 when everything fits, else
    /// the same fraction of the overflow as the text is scrolled.
    static func mapTopLine(first: Int, last: Int, lineCount: Int, rows: Int) -> Double {
        let overflow = lineCount - rows
        guard overflow > 0 else { return 0 }
        let onScreen = last - first + 1
        let scrollable = max(1, lineCount - onScreen)
        let fraction = min(1, max(0, Double(first) / Double(scrollable)))
        return fraction * Double(overflow)
    }

    /// The geometry now, or nil when the lines on screen are not known yet.
    func currentGeometry() -> Geometry? {
        guard !lineIndex.isPaused, let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage else { return nil }
        var visible = textView.visibleRect
        visible.origin.x -= textView.textContainerOrigin.x
        visible.origin.y -= textView.textContainerOrigin.y
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let lastCharacter = characters.length > 0 ? NSMaxRange(characters) - 1 : characters.location
        guard let first = lineIndex.line(containing: characters.location),
              let last = lineIndex.line(containing: min(lastCharacter, storage.length)) else { return nil }
        let count = max(lineIndex.estimatedLineCount, last + 1)
        return Geometry(firstVisibleLine: first, lastVisibleLine: last, lineCount: count,
                        mapTopLine: Self.mapTopLine(first: first, last: last, lineCount: count, rows: visibleRows))
    }

    // MARK: Drawing

    /// Times `draw` ran (tests).
    private(set) var drawCount = 0

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        let dirty = dirtyRect.intersection(bounds)
        NSColor.textBackgroundColor.setFill()
        dirty.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: dirty.minY, width: 1, height: dirty.height).fill()
        guard let geometry = currentGeometry(), let storage = textView?.textStorage,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let rects = blockRects(geometry: geometry, string: storage.string as NSString)
        NSColor.textColor.withAlphaComponent(0.45).setFill()
        context.fill(rects)
        let box = geometry.box(width: bounds.width)
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        box.fill()
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        let outline = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }

    /// The blocks of the rows the map shows. Each row reads at most as
    /// many characters as fit across the map; a tab moves to the next
    /// tab stop (Settings' tab width).
    func blockRects(geometry: Geometry, string: NSString) -> [CGRect] {
        let firstRow = Int(geometry.mapTopLine.rounded(.down))
        let shift = CGFloat(geometry.mapTopLine - Double(firstRow)) * Self.rowHeight
        let columns = Int((bounds.width - 2) / Self.columnWidth)
        let tabWidth = max(1, Defaults.integer(.tabWidth))
        let length = string.length
        var rects: [CGRect] = []
        var buffer = [unichar](repeating: 0, count: columns)
        for row in 0...visibleRows {
            let line = firstRow + row
            guard let start = lineIndex.lineStart(line), start < length else { break }
            let next = lineIndex.lineStart(line + 1) ?? length
            let count = min(columns, max(0, next - start))
            guard count > 0 else { continue }
            buffer.withUnsafeMutableBufferPointer { pointer in
                string.getCharacters(pointer.baseAddress!, range: NSRange(location: start, length: count))
            }
            let y = CGFloat(row) * Self.rowHeight - shift
            var column = 0
            var runStart = -1
            func endRun() {
                if runStart >= 0 {
                    rects.append(CGRect(x: 2 + CGFloat(runStart) * Self.columnWidth, y: y,
                                        width: CGFloat(column - runStart) * Self.columnWidth, height: Self.blockHeight))
                    runStart = -1
                }
            }
            for i in 0..<count where column < columns {
                let c = buffer[i]
                switch c {
                case 0x0A, 0x0D, 0x85, 0x2028, 0x2029:
                    endRun()
                case 0x09:
                    endRun()
                    column = (column / tabWidth + 1) * tabWidth
                case 0x20, 0xA0:
                    endRun()
                    column += 1
                default:
                    if runStart < 0 { runStart = column }
                    column += 1
                }
            }
            column = min(column, columns)
            endRun()
        }
        return rects
    }

    // MARK: Updates

    /// The text changed: redraw the rows soon, at most every
    /// `editRedrawDelay`, so typing does not pay for the map each key.
    func textDidChange() {
        guard !isHidden, !editRedrawPending else { return }
        editRedrawPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.editRedrawDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.editRedrawPending = false
                self.needsDisplay = true
            }
        }
    }

    // MARK: Click and drag

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let geometry = currentGeometry() else { return }
        let box = geometry.box(width: bounds.width)
        if box.contains(NSPoint(x: box.midX, y: point.y)) {
            dragOffset = point.y - box.minY
        } else {
            dragOffset = box.height / 2
            scroll(toMapY: point.y, geometry: geometry)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let geometry = currentGeometry() else { return }
        scroll(toMapY: point.y, geometry: geometry)
    }

    override func mouseUp(with event: NSEvent) {
        dragOffset = nil
    }

    /// Scrolls the text so the box's top lands where the mouse holds it.
    /// The map scrolls in proportion as the text does, so the line is
    /// found through the inverse of `mapTopLine`, not the map's top now.
    private func scroll(toMapY y: CGFloat, geometry: Geometry) {
        let onScreen = geometry.lastVisibleLine - geometry.firstVisibleLine + 1
        let topLine = Self.firstLine(forBoxTop: y - (dragOffset ?? 0), lineCount: geometry.lineCount,
                                     onScreen: onScreen, rows: visibleRows, height: bounds.height)
        scrollText(toLine: topLine)
    }

    /// The first line on screen that puts the box's top at `boxTop` (map
    /// points), given `mapTopLine`: the box top is (first - mapTop) rows
    /// and mapTop grows with first by overflow / (lineCount - onScreen).
    static func firstLine(forBoxTop boxTop: CGFloat, lineCount: Int, onScreen: Int, rows: Int,
                          height: CGFloat) -> Int {
        let scrollable = max(0, lineCount - onScreen)
        guard scrollable > 0 else { return 0 }
        let boxRows = Double(boxTop / rowHeight)
        let first: Double
        if lineCount <= rows {
            first = boxRows
        } else if rows > onScreen {
            // boxRows = first * (rows - onScreen) / scrollable
            first = boxRows * Double(scrollable) / Double(rows - onScreen)
        } else {
            // The box fills the map: follow the pointer's place in it.
            first = Double(boxTop / max(1, height)) * Double(scrollable)
        }
        return min(max(0, Int(first.rounded())), scrollable)
    }

    /// Puts 0-based `line` at the top of the text's visible area. Only the
    /// layout around that line is made (non-contiguous layout).
    func scrollText(toLine line: Int) {
        guard let textView, let layoutManager = textView.layoutManager, let storage = textView.textStorage,
              let start = lineIndex.lineStart(line) else { return }
        let length = storage.length
        func top() -> CGFloat {
            if start < length {
                let glyph = layoutManager.glyphIndexForCharacter(at: start)
                return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            }
            return length > 0 ? layoutManager.extraLineFragmentRect.minY : 0
        }
        // Twice: laying out the newly shown lines can move the estimated
        // heights of the lines above (non-contiguous layout), and the
        // line with them.
        for _ in 0..<2 {
            let y = top() + textView.textContainerOrigin.y
            guard abs(textView.visibleRect.minY - y) > 0.5 else { break }
            textView.scroll(NSPoint(x: 0, y: y))
            var visible = textView.visibleRect
            visible.origin.y -= textView.textContainerOrigin.y
            if let container = textView.textContainer { layoutManager.ensureLayout(forBoundingRect: visible, in: container) }
        }
    }
}

/// A document window's content (1.2.0): the scroll view and, on the
/// right, the document map, which takes no width while hidden.
final class DocumentContainerView: NSView {
    let scrollView: NSScrollView
    let documentMap: DocumentMapView

    init(scrollView: NSScrollView, documentMap: DocumentMapView) {
        self.scrollView = scrollView
        self.documentMap = documentMap
        super.init(frame: scrollView.frame)
        addSubview(scrollView)
        addSubview(documentMap)
        tile()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("DocumentContainerView is built in code") }

    /// The map's width now: 0 while hidden.
    var mapWidth: CGFloat { documentMap.isHidden ? 0 : DocumentMapView.width }

    override func resizeSubviews(withOldSize oldSize: NSSize) { tile() }

    func tile() {
        let mapWidth = self.mapWidth
        scrollView.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - mapWidth), height: bounds.height)
        documentMap.frame = NSRect(x: bounds.width - DocumentMapView.width, y: 0,
                                   width: DocumentMapView.width, height: bounds.height)
    }
}
