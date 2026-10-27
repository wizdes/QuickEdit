import AppKit

/// The document map on the right of a document window (1.2.0; Sublime
/// Text calls it the minimap). Each logical line is one row `rowHeight`
/// points tall, drawn as small blocks for its runs of non-space
/// characters, read straight from the string (never through the layout
/// manager), and only for the rows the map shows. A shaded box marks the
/// lines on screen. When the text has more rows than the map, the map
/// scrolls along with the text, in proportion. A click or drag scrolls the
/// text: a click centers the clicked line; dragging the box moves it.
///
/// 1.2.1: the box is hidden until the mouse comes within `hoverMargin`
/// points of the map (the container tracks that area for the map), and
/// fades in and out; it stays while a drag in the map goes on. No line
/// separates the map from the text any more.
final class DocumentMapView: NSView {
    static let width: CGFloat = 100
    static let rowHeight: CGFloat = 2
    static let columnWidth: CGFloat = 1
    /// Height of a row's blocks; the rest of the row is the gap below.
    static let blockHeight: CGFloat = 1.4
    /// While typing, the rows are redrawn at most this often; the box
    /// follows scrolling at once.
    static let editRedrawDelay: TimeInterval = 0.1
    /// How far left of the map the mouse shows the box (1.2.1).
    static let hoverMargin: CGFloat = 8
    /// The box's fades (1.2.1), for a full 0 to 1 change; a fade that
    /// starts part way takes its share of the time.
    static let fadeInDuration: CFTimeInterval = 0.15
    static let fadeOutDuration: CFTimeInterval = 0.25

    /// Where the pointer is, in the window's coordinates, read when no
    /// event says (1.2.1 review): at mouse up and when the tracking area
    /// is made again. Tests replace it.
    static var pointerInWindow: @MainActor (NSWindow) -> NSPoint = { $0.mouseLocationOutsideOfEventStream }

    /// System Settings > Accessibility > Reduce Motion; tests replace it.
    static var reducesMotion: @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The area that shows the box (1.2.1): the map and `hoverMargin`
    /// points to its left, over the text's right edge. In the frame's
    /// coordinates.
    static func hoverRect(mapFrame: NSRect) -> NSRect {
        NSRect(x: mapFrame.minX - hoverMargin, y: mapFrame.minY,
               width: mapFrame.width + hoverMargin, height: mapFrame.height)
    }

    /// The text view the map shows (the window's first view).
    weak var textView: NSTextView?
    let lineIndex: LineIndex
    private var editRedrawPending = false
    /// Where in the box the drag holds it, in points from its top.
    private var dragOffset: CGFloat? {
        didSet { if (oldValue == nil) != (dragOffset == nil) { boxVisibilityChanged() } }
    }

    // MARK: The box's fade (1.2.1)

    /// True while the mouse is in `hoverRect` (the container's tracking
    /// area sends mouseEntered and mouseExited here).
    private(set) var isMouseNear = false {
        didSet { if oldValue != isMouseNear { boxVisibilityChanged() } }
    }
    /// True from mouse down to mouse up in the map.
    var isDragging: Bool { dragOffset != nil }
    /// The box should show: the mouse is near, or a drag goes on.
    var showsViewportBox: Bool { isMouseNear || isDragging }
    /// How much of the box is drawn now, 0 (none) to 1.
    private(set) var boxAlpha: CGFloat = 0
    /// When the fade now running started, and the alpha it started from.
    private(set) var fadeStart: CFTimeInterval = 0
    private var fadeFrom: CGFloat = 0
    /// Drives a fade frame by frame; nil while idle, so nothing runs then.
    private var fadeLink: CADisplayLink?
    /// True while a fade runs.
    var isFading: Bool { fadeLink != nil }

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
        // The map's background is the text's, with no separator line
        // between them (1.2.1).
        NSColor.textBackgroundColor.setFill()
        dirty.fill()
        guard let geometry = currentGeometry(), let storage = textView?.textStorage,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let rects = blockRects(geometry: geometry, string: storage.string as NSString)
        NSColor.textColor.withAlphaComponent(0.45).setFill()
        context.fill(rects)
        // The box only while hovered or dragged, faded by boxAlpha (1.2.1).
        guard boxAlpha > 0 else { return }
        let box = geometry.box(width: bounds.width)
        NSColor.labelColor.withAlphaComponent(0.10 * boxAlpha).setFill()
        box.fill()
        NSColor.labelColor.withAlphaComponent(0.22 * boxAlpha).setStroke()
        let outline = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }

    // MARK: Hover and fade (1.2.1)

    override func mouseEntered(with event: NSEvent) { isMouseNear = true }

    override func mouseExited(with event: NSEvent) { isMouseNear = false }

    /// The map was hidden, left its window, or its tracking area went
    /// away: the mouse is no longer near it and the box goes at once. The
    /// display link is stopped here too: it holds the map, and a view's
    /// link stops firing off screen, so a fade cut short by a closing
    /// window would keep the map, its line index and the text alive
    /// (1.2.1 review).
    func resetHover() {
        isMouseNear = false
        stopFade()
        boxAlpha = showsViewportBox ? 1 : 0
    }

    private func stopFade() {
        fadeLink?.invalidate()
        fadeLink = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { resetHover() }
    }

    /// Whether the pointer is in the hover area now, read from the window
    /// rather than an event (1.2.1 review): a drag that ends outside may
    /// bring no mouseExited.
    func resampleHover() {
        guard !isHidden, let window, let container = superview else {
            isMouseNear = false
            return
        }
        let point = container.convert(Self.pointerInWindow(window), from: nil)
        isMouseNear = Self.hoverRect(mapFrame: frame).contains(point)
    }

    /// Starts a fade toward the box's new target from where it is now. A
    /// hidden map, one off screen, or Reduce Motion jumps straight there.
    private func boxVisibilityChanged() {
        let target: CGFloat = showsViewportBox ? 1 : 0
        fadeFrom = boxAlpha
        fadeStart = CACurrentMediaTime()
        guard boxAlpha != target else {
            stopFade()
            return
        }
        if isHidden || window == nil || Self.reducesMotion() {
            stopFade()
            boxAlpha = target
            needsDisplay = true
            return
        }
        if fadeLink == nil {
            let link = displayLink(target: self, selector: #selector(fadeFrame(_:)))
            link.add(to: .main, forMode: .common)
            fadeLink = link
        }
    }

    @objc private func fadeFrame(_ link: CADisplayLink) {
        stepFade(at: CACurrentMediaTime())
    }

    /// Moves the fade to time `now` and redraws the box's area; stops the
    /// display link once the box reaches its target.
    func stepFade(at now: CFTimeInterval) {
        let target: CGFloat = showsViewportBox ? 1 : 0
        let duration = (target > fadeFrom ? Self.fadeInDuration : Self.fadeOutDuration) * Double(abs(target - fadeFrom))
        var progress = duration > 0 ? min(1, max(0, (now - fadeStart) / duration)) : 1
        // `fadeStart + d - fadeStart` can come out a hair under `d`.
        if progress > 0.999 { progress = 1 }
        boxAlpha = fadeFrom + (target - fadeFrom) * CGFloat(progress)
        if progress >= 1 {
            boxAlpha = target
            fadeLink?.invalidate()
            fadeLink = nil
        }
        if let geometry = currentGeometry() {
            setNeedsDisplay(geometry.box(width: bounds.width).insetBy(dx: 0, dy: -1).intersection(bounds))
        } else {
            needsDisplay = true
        }
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
        // Where the pointer is first, so a drag that ended outside the
        // area does not flash the box back on (1.2.1 review).
        resampleHover()
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
        updateTrackingAreas()
    }

    /// The area near the map that shows its box (1.2.1). It reaches over
    /// the text's right edge, so it lives here, not on the map.
    private var mapTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let rect = DocumentMapView.hoverRect(mapFrame: documentMap.frame)
        if let area = mapTrackingArea, !documentMap.isHidden, area.rect == rect { return }
        if let area = mapTrackingArea {
            removeTrackingArea(area)
            mapTrackingArea = nil
        }
        guard !documentMap.isHidden else {
            documentMap.resetHover()
            return
        }
        // During a drag too, so leaving the area with the button down
        // still sends mouseExited (1.2.1 review).
        let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag],
                                  owner: documentMap, userInfo: nil)
        addTrackingArea(area)
        mapTrackingArea = area
        // A new area sends no entered event for a pointer already inside.
        documentMap.resampleHover()
    }
}
