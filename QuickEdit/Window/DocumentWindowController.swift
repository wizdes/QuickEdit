import AppKit

/// One window per document (contract `win-text`): a ScalingScrollView and one
/// TextKit 1 layout manager on the document's storage, shared by every text
/// view in the window. Wrap to Window has one text view; Wrap to Page has one
/// fixed-size text view per page inside a MultiplePageView. The views share
/// selection, typing attributes and undo through the layout manager
/// (reference/apple/DocumentWindowController.m, docs/codemap.md section 5).
///
/// The layout manager is used on the main thread only; `@preconcurrency`
/// makes Swift check that at run time for its delegate calls.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate,
    @preconcurrency NSLayoutManagerDelegate {
    /// One layout manager for every text view in this window.
    let layoutManager: NSLayoutManager
    let scrollView: ScalingScrollView

    /// Wrap to Page is on. Follows the document's `hasMultiplePages`.
    private(set) var hasMultiplePages = false

    /// The first text view: the only one in Wrap to Window, page 1's in
    /// Wrap to Page. Selection, typing attributes and undo are shared, so
    /// actions on it act on the whole document.
    var textView: NSTextView {
        guard let view = layoutManager.textContainers.first?.textView else {
            preconditionFailure("a document window always has at least one text view")
        }
        return view
    }

    /// Every text view, in page order.
    var textViews: [NSTextView] { layoutManager.textContainers.compactMap(\.textView) }

    /// The page view in Wrap to Page, else nil.
    var pagesView: MultiplePageView? { scrollView.documentView as? MultiplePageView }

    /// Page count; 1 in Wrap to Window (DocumentWindowController.m:436-438).
    var numberOfPages: Int { hasMultiplePages ? (pagesView?.numberOfPages ?? 0) : 1 }

    /// The text area size the window was last given. When the scroller style
    /// changes, the window is resized so this stays the same (P44).
    private(set) var viewSize: NSSize = .zero
    private var isSettingSize = false
    private var observations: [NSKeyValueObservation] = []

    /// The document this window shows. NSWindowController's `document` is
    /// set only after init, so init keeps its own reference.
    private weak var textDocument: TextDocument?

    init(document: TextDocument) {
        textDocument = document
        let contentSize = TextViewFactory.initialContentSize()
        layoutManager = TextViewFactory.makeLayoutManager()
        scrollView = ScalingScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        // The window wraps the text area the way TextEdit's resizeWindowForViewSize: does.
        let frameSize = NSScrollView.frameSize(forContentSize: contentSize,
                                               horizontalScrollerClass: nil,
                                               verticalScrollerClass: NSScroller.self,
                                               borderType: .noBorder,
                                               controlSize: .regular,
                                               scrollerStyle: NSScroller.preferredScrollerStyle)
        scrollView.frame = NSRect(origin: .zero, size: frameSize)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: frameSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.contentView = scrollView
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        document.textStorage.addLayoutManager(layoutManager)
        layoutManager.delegate = self
        // This makes the first text view (DocumentWindowController.m:681-698).
        setHasMultiplePages(document.hasMultiplePages, force: true)
        if hasMultiplePages, let pagesView {
            resizeWindow(forViewSize: pagesView.pageRect(forPage: 0).size)
        }

        window.center()
        // NSWindowController cascades only windows it loads from a nib, so
        // cascade by hand: step down and right from the front document window.
        if let front = NSApp.orderedWindows.first(where: {
            $0 !== window && $0.isVisible && $0.windowController is DocumentWindowController
        }) {
            window.cascadeTopLeft(from: front.cascadeTopLeft(from: .zero))
        } else {
            #if DEBUG
            // UI tests only: `-QETestUntitledTopLeft "{x, y}"` places the first
            // untitled window away from the center while it is made, before
            // it becomes transient, so a test can tell a copied frame from a
            // default one. Moving it later would end the transient state.
            if document.fileURL == nil, let point = UserDefaults.standard.string(forKey: "QETestUntitledTopLeft") {
                window.setFrameTopLeftPoint(NSPointFromString(point))
            }
            #endif
        }
        recordViewSize()

        // Save the new selection and scroll place at the next state save.
        // invalidateRestorableState only marks the state dirty; AppKit
        // encodes it later, off the typing path. Any of this window's text
        // views may post the selection change, so the sender is checked.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(selectionChanged(_:)),
                           name: NSTextView.didChangeSelectionNotification, object: nil)
        scrollView.contentView.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(restorableStateChanged(_:)),
                           name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(documentTextDidProcessEditing(_:)),
                           name: NSTextStorage.didProcessEditingNotification, object: document.textStorage)

        // Page Setup changes resize every page (DocumentWindowController.m:220-222, :264-279).
        observations.append(document.observe(\.printInfo) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.printInfoUpdated() }
        })
        // A new scroller style (a mouse plugged in, or the setting changed)
        // keeps the text width, not the window width (:212-219).
        if let scroller = scrollView.verticalScroller {
            observations.append(scroller.observe(\.scrollerStyle) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scrollerStyleChanged() }
            })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("DocumentWindowController is built in code") }

    // MARK: Wrap to Window and Wrap to Page (DocumentWindowController.m:459-615)

    /// Switches the window between one text view that wraps to the window
    /// and one text view per page. The text, selection, undo and edited
    /// state stay, because the new container joins the layout manager before
    /// the old ones leave (:540-544, :572-573). Never lays out the whole
    /// text: only up to the selection, then AppKit's background layout adds
    /// pages as it reaches them.
    func setHasMultiplePages(_ pages: Bool, force: Bool = false) {
        guard force || pages != hasMultiplePages else { return }
        hasMultiplePages = pages
        let hadViews = !layoutManager.textContainers.isEmpty

        if pages {
            let printInfo = textDocument?.printInfo ?? NSPrintInfo.shared
            let pagesView = MultiplePageView(printInfo: printInfo)
            scrollView.documentView = pagesView
            // The first page goes in front of the old view, not after it:
            // AppKit hands the shared input context to a view inserted
            // first, but not when the first view is removed, and keystrokes
            // would then go to the old, detached view. The page callback
            // waits until the old view is gone.
            layoutManager.delegate = nil
            addPage(inFront: hadViews)
            if hadViews { layoutManager.removeTextContainer(at: 1) }
            layoutManager.delegate = self
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            // The area around and between pages. TextEdit's nib uses
            // controlColor, which is white on macOS 27 and hides the pages.
            scrollView.backgroundColor = .underPageBackgroundColor
            if !hadViews { configureFirstTextView() }
            showSelectionAndCenterPage()
        } else {
            let (textView, container) = TextViewFactory.makeWindowModeTextView(size: scrollView.contentSize)
            layoutManager.insertTextContainer(container, at: 0)
            // Remove the pages from the end: each removal then invalidates
            // only the tail.
            while layoutManager.textContainers.count > 1 {
                layoutManager.removeTextContainer(at: layoutManager.textContainers.count - 1)
            }
            scrollView.documentView = textView
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            // Behind a short text when zoomed out: the text's own background.
            scrollView.backgroundColor = .textBackgroundColor
            if !hadViews { configureFirstTextView() }
            TextViewFactory.configureTypingAttributes(textView)
            textView.scrollRangeToVisible(textView.selectedRange())
        }
        // AppKit clears the shared delegate when the old first view leaves
        // the layout manager, so set it again.
        textView.delegate = self
        updateEditable()
        window?.makeFirstResponder(textView)
        // So focus is not stolen (DocumentWindowController.m:613-614).
        window?.initialFirstResponder = textView
    }

    /// The very first text view sets the state all views share.
    private func configureFirstTextView() {
        TextViewFactory.configureSharedState(textView)
        TextViewFactory.configureTypingAttributes(textView)
    }

    /// Adds one page: a container the size of the page's text area and a
    /// fixed-size text view on it (DocumentWindowController.m:459-495).
    private func addPage(inFront: Bool = false) {
        guard let pagesView else { return }
        let page = pagesView.numberOfPages
        pagesView.setNumberOfPages(page + 1)
        let (textView, container) = TextViewFactory.makePageTextView(frame: pagesView.documentRect(forPage: page))
        // As TextEdit's addPage (DocumentWindowController.m:487): the new
        // view gets the window's typing attributes and paragraph style before
        // it joins the layout manager (M3+M5 review row 13). They are copied
        // from the first view, so a Settings change made since the window
        // opened does not reach it (Settings apply to new windows).
        if let first = layoutManager.textContainers.first?.textView {
            textView.defaultParagraphStyle = first.defaultParagraphStyle
            textView.typingAttributes = first.typingAttributes
        }
        pagesView.addSubview(textView)
        if inFront {
            layoutManager.insertTextContainer(container, at: 0)
        } else {
            layoutManager.addTextContainer(container)
        }
    }

    /// Removes the last page (DocumentWindowController.m:497-506).
    private func removePage() {
        guard let pagesView, layoutManager.textContainers.count > 1 else { return }
        let last = layoutManager.textContainers.count - 1
        pagesView.setNumberOfPages(pagesView.numberOfPages - 1)
        layoutManager.textContainers[last].textView?.removeFromSuperview()
        layoutManager.removeTextContainer(at: last)
    }

    /// Scrolls to the selection; if the page is wider than the window,
    /// centers the text area, or shows its left edge when even that does
    /// not fit (DocumentWindowController.m:551-565).
    private func showSelectionAndCenterPage() {
        guard let pagesView else { return }
        textView.scrollRangeToVisible(textView.selectedRange())
        var visible = pagesView.visibleRect
        let pageRect = pagesView.pageRect(forPage: 0)
        guard visible.width < pageRect.width else { return }
        let documentRect = pagesView.documentRect(forPage: 0)
        if visible.width >= documentRect.width {
            visible.origin.x = max(documentRect.minX - ((visible.width - documentRect.width) / 2).rounded(.down),
                                   pageRect.minX)
        } else {
            visible.origin.x = documentRect.minX
        }
        pagesView.scrollToVisible(visible)
    }

    /// Adds a page when the last page fills, if that page really has text
    /// (the workaround at :1003), and removes empty trailing pages when
    /// layout ends with room to spare (DocumentWindowController.m:992-1022).
    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?,
                       atEnd layoutFinishedFlag: Bool) {
        guard hasMultiplePages else { return }
        let containers = layoutManager.textContainers
        if !layoutFinishedFlag || textContainer == nil {
            // Layout is not finished, or glyphs were laid nowhere.
            guard let last = containers.last, textContainer === last || textContainer == nil else { return }
            if layoutManager.glyphRange(for: last).length > 0 {
                addPage()
            }
        } else if let textContainer, let lastUsed = containers.firstIndex(where: { $0 === textContainer }) {
            // Layout is done and it all fit: drop the pages after the last used one.
            for _ in (lastUsed + 1)..<max(lastUsed + 1, containers.count) {
                removePage()
            }
        }
    }

    /// Text was deleted. When the text left is already laid out (for
    /// example, everything after a line end was deleted, or a revert made
    /// the text shorter), AppKit lays nothing out again and sends no layout
    /// callback, so the empty pages at the end would stay. TextEdit has the
    /// same gap. This removes them on the next turn of the run loop.
    @objc private func documentTextDidProcessEditing(_ notification: Notification) {
        guard hasMultiplePages, let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters), storage.changeInLength < 0 else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.removeEmptyTrailingPages() }
        }
    }

    /// Removes pages after the one holding the last character, only when
    /// all text is laid out already (otherwise the layout callback does it).
    /// Asks only about glyphs already laid out.
    func removeEmptyTrailingPages() {
        guard hasMultiplePages, layoutManager.textContainers.count > 1,
              let length = layoutManager.textStorage?.length,
              layoutManager.firstUnlaidCharacterIndex() >= length else { return }
        var lastUsed = 0
        if length > 0 {
            let glyph = layoutManager.glyphIndexForCharacter(at: length - 1)
            let containers = layoutManager.textContainers
            guard let container = layoutManager.textContainer(forGlyphAt: glyph, effectiveRange: nil,
                                                              withoutAdditionalLayout: true),
                  let index = containers.firstIndex(where: { $0 === container }) else { return }
            lastUsed = index
        }
        while layoutManager.textContainers.count > lastUsed + 1 {
            removePage()
        }
    }

    /// Page Setup changed: copy the print info and resize every page
    /// (DocumentWindowController.m:264-279).
    func printInfoUpdated() {
        guard hasMultiplePages, let pagesView, let textDocument else { return }
        pagesView.printInfo = textDocument.printInfo
        var page = 0
        // Re-read the counts each time: resizing a page can add or remove pages.
        while page < min(numberOfPages, layoutManager.textContainers.count) {
            let frame = pagesView.documentRect(forPage: page)
            let container = layoutManager.textContainers[page]
            container.size = frame.size
            container.textView?.frame = frame
            page += 1
        }
    }

    // MARK: Window size

    /// Sets the window frame so the text area is `size`; in Wrap to Window
    /// the line padding is added on both sides. The top-left corner stays
    /// (DocumentWindowController.m:639-654). TextEdit uses the system's
    /// preferred scroller style; this uses the scroll view's own, which is
    /// the same in the app and lets a test change it.
    func resizeWindow(forViewSize size: NSSize) {
        guard let window else { return }
        var size = size
        let style: NSScroller.Style
        if hasMultiplePages {
            style = .legacy // as TextEdit: Wrap to Page sizes for legacy scrollers
        } else {
            size.width += MultiplePageView.textPadding * 2
            style = scrollView.scrollerStyle
        }
        let scrollSize = NSScrollView.frameSize(forContentSize: size,
                                                horizontalScrollerClass: scrollView.hasHorizontalScroller ? NSScroller.self : nil,
                                                verticalScrollerClass: scrollView.hasVerticalScroller ? NSScroller.self : nil,
                                                borderType: scrollView.borderType, controlSize: .regular,
                                                scrollerStyle: style)
        let original = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: scrollSize))
        frame.origin = NSPoint(x: original.minX, y: original.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    /// The text area size for the current window frame (DocumentWindowController.m:884-897).
    private func currentViewSize(scrollerStyle: NSScroller.Style) -> NSSize {
        var size = NSScrollView.contentSize(forFrameSize: scrollView.frame.size,
                                            horizontalScrollerClass: scrollView.hasHorizontalScroller ? NSScroller.self : nil,
                                            verticalScrollerClass: scrollView.hasVerticalScroller ? NSScroller.self : nil,
                                            borderType: scrollView.borderType, controlSize: .regular,
                                            scrollerStyle: scrollerStyle)
        if !hasMultiplePages { size.width -= MultiplePageView.textPadding * 2 }
        return size
    }

    private func recordViewSize() {
        guard !isSettingSize else { return }
        isSettingSize = true
        viewSize = currentViewSize(scrollerStyle: scrollView.scrollerStyle)
        isSettingSize = false
    }

    private func scrollerStyleChanged() {
        invalidateRestorableState()
        if viewSize != .zero { resizeWindow(forViewSize: viewSize) }
    }

    /// The Zoom button in Wrap to Page fits one page width, keeping the
    /// top-left corner (DocumentWindowController.m:860-882).
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        guard hasMultiplePages, let textDocument else { return newFrame }
        let paper = textDocument.printInfo.paperSize
        let scrollSize = NSScrollView.frameSize(forContentSize: paper,
                                                horizontalScrollerClass: scrollView.hasHorizontalScroller ? NSScroller.self : nil,
                                                verticalScrollerClass: scrollView.hasVerticalScroller ? NSScroller.self : nil,
                                                borderType: scrollView.borderType, controlSize: .regular,
                                                scrollerStyle: .legacy)
        let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: scrollSize)).size
        let current = window.frame
        return NSRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height)
    }

    // MARK: State restoration (selection, scroll place, scroller style)

    private enum RestoreKey {
        static let selectionLocation = "QESelectionLocation"
        static let selectionLength = "QESelectionLength"
        static let topCharacter = "QETopCharacter"
        static let scrollerStyle = "scrollerStyle"
    }

    @objc private func restorableStateChanged(_ notification: Notification) {
        invalidateRestorableState()
    }

    @objc private func selectionChanged(_ notification: Notification) {
        guard (notification.object as? NSTextView)?.layoutManager === layoutManager else { return }
        invalidateRestorableState()
    }

    /// TextEdit 1.9 saves only the scroller style here
    /// (reference/apple/DocumentWindowController.m:619-637); QuickEdit also
    /// saves the selection and the first character on screen.
    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        let selection = textView.selectedRange()
        coder.encode(selection.location, forKey: RestoreKey.selectionLocation)
        coder.encode(selection.length, forKey: RestoreKey.selectionLength)
        if let top = topVisibleCharacter() {
            coder.encode(top, forKey: RestoreKey.topCharacter)
        }
        coder.encode(NSScroller.preferredScrollerStyle.rawValue, forKey: RestoreKey.scrollerStyle)
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        restoreTextWidth(with: coder)
        guard coder.containsValue(forKey: RestoreKey.selectionLocation) else { return }
        // The file may have changed since the state was saved: clamp to it.
        let length = textView.textStorage?.length ?? 0
        let location = min(max(0, coder.decodeInteger(forKey: RestoreKey.selectionLocation)), length)
        let selectionLength = min(max(0, coder.decodeInteger(forKey: RestoreKey.selectionLength)), length - location)
        textView.setSelectedRange(NSRange(location: location, length: selectionLength))
        let top = coder.containsValue(forKey: RestoreKey.topCharacter)
            ? min(max(0, coder.decodeInteger(forKey: RestoreKey.topCharacter)), length) : location
        // Scroll after this turn of the run loop, once the window has laid
        // out its visible part.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.scrollLineToTop(containing: top) }
        }
    }

    /// The window was saved with another scroller style: resize it so the
    /// text area is as wide as it was (DocumentWindowController.m:619-631).
    private func restoreTextWidth(with coder: NSCoder) {
        guard coder.containsValue(forKey: RestoreKey.scrollerStyle),
              let previous = NSScroller.Style(rawValue: coder.decodeInteger(forKey: RestoreKey.scrollerStyle)),
              previous != NSScroller.preferredScrollerStyle, !hasMultiplePages else { return }
        resizeWindow(forViewSize: currentViewSize(scrollerStyle: previous))
    }

    /// The first character on screen, from the glyphs already laid out.
    private func topVisibleCharacter() -> Int? {
        let view: NSTextView
        if let pagesView {
            let page = pagesView.pageNumber(for: pagesView.visibleRect.origin)
            guard page < layoutManager.textContainers.count,
                  let pageView = layoutManager.textContainers[page].textView else { return nil }
            view = pageView
        } else {
            view = textView
        }
        guard let container = view.textContainer else { return nil }
        // Only the glyphs already laid out on screen are asked about.
        let glyphs = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: view.visibleRect, in: container)
        return layoutManager.characterIndexForGlyph(at: glyphs.location)
    }

    /// The selection and the first character on screen, so a reload can put
    /// them back (M2 review row 3).
    struct Place {
        var selection: NSRange
        var topCharacter: Int
    }

    func currentPlace() -> Place {
        Place(selection: textView.selectedRange(), topCharacter: topVisibleCharacter() ?? textView.selectedRange().location)
    }

    /// Puts a saved place back, clamped to the text's new length.
    func restore(_ place: Place) {
        let length = textView.textStorage?.length ?? 0
        let location = min(place.selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(place.selection.length, length - location)))
        scrollLineToTop(containing: min(place.topCharacter, length))
    }

    /// Scrolls so the line holding `character` is the top line on screen.
    /// In Wrap to Window, non-contiguous layout lays out only around that
    /// line. In Wrap to Page, finding the page lays out the text before it.
    private func scrollLineToTop(containing character: Int) {
        let length = textView.textStorage?.length ?? 0
        guard length > 0, character <= length else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(character, length - 1))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard let view = layoutManager.textContainer(forGlyphAt: glyph, effectiveRange: nil)?.textView else { return }
        if let pagesView {
            let point = view.convert(NSPoint(x: 0, y: line.minY + view.textContainerOrigin.y), to: pagesView)
            pagesView.scroll(NSPoint(x: pagesView.visibleRect.minX, y: point.y))
        } else {
            view.scroll(NSPoint(x: 0, y: line.minY + view.textContainerOrigin.y))
        }
    }

    // MARK: Line endings and the encoding check (M3 n3)

    /// Set when an edit inserts a character the document's encoding cannot
    /// hold; the question is asked once the edit is in the storage.
    private var encodingCheckPending = false

    /// Commands that type a new line: Return and Enter, Option-Return, and
    /// insertParagraphSeparator: (M3+M5 review row 12). insertLineBreak:
    /// keeps AppKit's U+2028.
    private static let newlineCommands: Set<Selector> = [
        #selector(NSResponder.insertNewline(_:)),
        #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
        #selector(NSResponder.insertParagraphSeparator(_:)),
    ]

    /// They type the document's main line ending (LF for new documents), so
    /// a CRLF or CR file stays that way. Better than TextEdit, which always
    /// types LF (docs/codemap.md 4.3). Paste is untouched.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard Self.newlineCommands.contains(commandSelector),
              let document = document as? TextDocument else { return false }
        let ending = document.format.lineEnding
        guard ending != .lf else { return false }
        textView.insertText(ending.string, replacementRange: textView.selectedRange())
        return true
    }

    /// Checks only the inserted characters, never the whole text. The
    /// failing edit gets its own undo step, so Cancel takes back just it.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        checkInsertion([replacementString].compactMap { $0 }, in: textView)
        return true
    }

    /// Edits of several ranges at once, such as Replace All: every
    /// replacement string is checked (M3+M5 review row 14). When this method
    /// exists AppKit calls it instead of the one-range method.
    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
                  replacementStrings: [String]?) -> Bool {
        checkInsertion(replacementStrings ?? [], in: textView)
        return true
    }

    private func checkInsertion(_ strings: [String], in textView: NSTextView) {
        guard let document = document as? TextDocument,
              strings.contains(where: { document.insertionDoesNotFit($0) }) else { return }
        textView.breakUndoCoalescing()
        encodingCheckPending = true
    }

    func textDidChange(_ notification: Notification) {
        guard encodingCheckPending else { return }
        encodingCheckPending = false
        // While an input method composes, the marked text is not the user's
        // text yet: no question. The commit is checked again by itself
        // (M3+M5 review row 15).
        if (notification.object as? NSTextView)?.hasMarkedText() == true { return }
        guard let document = document as? TextDocument else { return }
        document.encodingNoLongerFits { [weak self] in
            self?.textView.undoManager?.undo()
        }
    }

    func breakUndoCoalescing() {
        textView.breakUndoCoalescing()
    }

    func updateEditable() {
        let editable = !(textDocument?.preventsEditing ?? false)
        for view in textViews { view.isEditable = editable }
    }

    /// The user took an interest in the window: it is no longer transient
    /// (reference/apple/DocumentWindowController.m:884-901). The new text
    /// area size is kept for scroller style changes.
    func windowDidResize(_ notification: Notification) {
        (document as? TextDocument)?.isTransient = false
        recordViewSize()
    }

    func windowDidMove(_ notification: Notification) {
        (document as? TextDocument)?.isTransient = false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if window?.firstResponder === textView {
            LaunchStamp.firstWindowReady()
        }
    }
}
