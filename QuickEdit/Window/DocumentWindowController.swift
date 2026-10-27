import AppKit
import os

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
    /// The window's content (1.2.0): the scroll view and the document map.
    let container: DocumentContainerView
    /// Where each line starts, for the gutter and the map (1.2.0).
    let lineIndex: LineIndex
    /// The line-number gutter: the scroll view's vertical ruler (1.2.0).
    let lineNumberView: LineNumberRulerView
    /// The document map on the right (1.2.0).
    var documentMap: DocumentMapView { container.documentMap }

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
        lineIndex = LineIndex(storage: document.textStorage)
        lineNumberView = LineNumberRulerView(scrollView: scrollView, lineIndex: lineIndex)
        scrollView.verticalRulerView = lineNumberView
        container = DocumentContainerView(scrollView: scrollView, documentMap: DocumentMapView(lineIndex: lineIndex))
        container.autoresizingMask = [.width, .height]

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: frameSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.contentView = container
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        // A file dropped on the title bar (or anywhere outside the text)
        // opens it (P72); the text view takes its own drops.
        window.registerForDraggedTypes([.fileURL])
        Signposts.markOnce(.firstWindowCreated)

        document.textStorage.addLayoutManager(layoutManager)
        Signposts.mark(.storageInstalled)
        layoutManager.delegate = self
        // This makes the first text view (DocumentWindowController.m:681-698).
        setHasMultiplePages(document.hasMultiplePages, force: true)
        lineIndex.onProgress = { [weak self] in self?.lineIndexProgressed() }
        if hasMultiplePages, let pagesView {
            resizeWindow(forViewSize: pagesView.pageRect(forPage: 0).size)
        } else {
            // The gutter and the map take their room outside the text area,
            // so "Width: 90 characters" still means 90 characters of text.
            resizeWindow(forViewSize: NSSize(width: contentSize.width - MultiplePageView.textPadding * 2,
                                             height: contentSize.height))
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
        // Windows join tabs (tabbingMode stays .automatic, so Cmd+N and
        // opened files follow the system "Prefer tabs" setting); the tab
        // bar shows at 2 or more tabs and hides at 1 (M11). Tracked after
        // the frame is set: tracked before it, the new window stayed at the
        // screen's corner in a full unit run (ReviewFixTests cascade test,
        // 2026-10-26).
        TabBarRule.shared.track(window)

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
        // The gutter and the map follow scrolling and the text's height.
        center.addObserver(self, selector: #selector(visibleTextMoved(_:)),
                           name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(visibleTextMoved(_:)),
                           name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(documentTextDidProcessEditing(_:)),
                           name: NSTextStorage.didProcessEditingNotification, object: document.textStorage)
        center.addObserver(self, selector: #selector(documentTextWillProcessEditing(_:)),
                           name: NSTextStorage.willProcessEditingNotification, object: document.textStorage)

        // A new print info resizes every page (DocumentWindowController.m:220-222,
        // :264-279). QuickEdit has no Page Setup (U1); tests set one.
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
            // The document's paper as a plain value: no NSPrintInfo is asked
            // for its paper, so Wrap to Page never reaches the print helper (M7).
            let pagesView = MultiplePageView(layout: textDocument?.pageLayout ?? .forNewDocument())
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
            // The window lays out the pages itself, in short slices (M8 n3).
            // Edits made in Wrap to Window did not lower the glyph mark, so
            // it starts again from the start (M8 review row 9).
            layoutManager.backgroundLayoutEnabled = false
            resetIdleLayout()
            scheduleIdleLayout()
        } else {
            stopIdleLayout()
            layoutManager.backgroundLayoutEnabled = true
            let (textView, container) = TextViewFactory.makeWindowModeTextView(size: scrollView.contentSize)
            if !hadViews {
                // The first view goes into the scroll view before it meets
                // the text (M8, V3). The other way round, the layout
                // manager first makes the view as tall as the whole text,
                // and then joining the scroll view asks it for the glyphs
                // in all that height: 210 ms on the main thread for 1 GB.
                scrollView.documentView = textView
            }
            layoutManager.insertTextContainer(container, at: 0)
            // Remove the pages from the end: each removal then invalidates
            // only the tail.
            while layoutManager.textContainers.count > 1 {
                layoutManager.removeTextContainer(at: layoutManager.textContainers.count - 1)
            }
            if hadViews { scrollView.documentView = textView }
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
        updateGutterAndMap()
        updateEditable()
        window?.makeFirstResponder(textView)
        // So focus is not stolen (DocumentWindowController.m:613-614).
        window?.initialFirstResponder = textView
    }

    /// The very first text view sets the state all views share.
    private func configureFirstTextView() {
        TextViewFactory.configureSharedState(textView)
        TextViewFactory.configureTypingAttributes(textView)
        applyLargeFileMode(updatesTitle: false)
    }

    // MARK: Large files (M8 n2)

    /// Added to the window title of a large file, so the user knows why
    /// the checks are off. The Edit menu can still turn each one on for
    /// this window.
    static let largeFileTitleNote = "Large file: spelling and substitutions off"

    /// The window's checks from before large-file mode turned them off;
    /// nil while the mode is off.
    private var checksBeforeLargeFile: TextViewFactory.TypingChecks?

    /// Turns the checks off when the document is large, and puts the
    /// window's own back when it no longer is; then the title follows. The
    /// document calls this after a reload or a revert changed its size
    /// (M8 review row 2). The checks are shared by every view on the
    /// layout manager, so the first view stands for all.
    func applyLargeFileMode(updatesTitle: Bool = true) {
        // Revert and the reloads replace the whole text, maybe off the
        // main thread: the line index starts again (1.2.0).
        lineIndex.reset()
        updateGutterAndMap()
        let large = textDocument?.isLargeFile == true
        if large, checksBeforeLargeFile == nil {
            checksBeforeLargeFile = TextViewFactory.TypingChecks(of: textView)
            TextViewFactory.turnOffChecks(textView)
        } else if !large, let saved = checksBeforeLargeFile {
            saved.apply(to: textView)
            checksBeforeLargeFile = nil
        }
        if updatesTitle { synchronizeWindowTitleWithDocumentName() }
    }

    /// Added to the window title of a file too large to edit (M8, V3),
    /// with its size, in the same place as the large-file note, which it
    /// replaces (the checks are off too). A title note, not a banner: it
    /// is the place the large-file note already uses, it takes no room
    /// from the text, and the menus already show the state (Allow Editing
    /// greyed out).
    static func readOnlyTitleNote(byteCount: Int) -> String {
        "Read only: file too large to edit ("
            + ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) + ")"
    }

    /// Added after the read-only note when the file's disk cannot clone
    /// it, so Save As, Save To and Duplicate are off (M8 review row 29).
    static let noCopyTitleNote = "; Save As unavailable on this disk"

    /// The title bar's file icon gets a spoken name (M9 done-test 1: the
    /// audit flags AppKit's unnamed icon).
    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        if let name = document?.displayName {
            window?.standardWindowButton(.documentIconButton)?.setAccessibilityLabel("File icon of \(name)")
        }
    }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        guard let textDocument, textDocument.isLargeFile || textDocument.isTooLargeToEdit else { return displayName }
        if textDocument.isTooLargeToEdit {
            return displayName + " \u{2014} " + Self.readOnlyTitleNote(byteCount: textDocument.readByteCount)
                + (textDocument.cannotSaveACopy ? Self.noCopyTitleNote : "")
        }
        return displayName + " \u{2014} " + Self.largeFileTitleNote
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
            // Writing Tools as on the first page (off for a read-only large file).
            TextViewFactory.setWritingTools(on: first.writingToolsBehavior != .none, textView)
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
        Signposts.markOnce(.firstLayout)
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
    /// In Wrap to Page an edit also starts the idle layout again (M8 n3),
    /// and every edit ends the "storage edit" signpost interval (M8 n7).
    /// The storage is filled on a background thread at open and during a
    /// large-file reload (M8 review row 19); those edits are not the
    /// window's to follow (the reload attaches the window again after).
    @objc nonisolated private func documentTextDidProcessEditing(_ notification: Notification) {
        guard Thread.isMainThread else { return }
        nonisolated(unsafe) let note = notification
        MainActor.assumeIsolated { followTextEdit(note) }
    }

    private func followTextEdit(_ notification: Notification) {
        if let storageEditSignpost {
            Signposts.endStorageEdit(storageEditSignpost)
            self.storageEditSignpost = nil
        }
        if let storage = notification.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters),
           !scrollView.rulersVisible, documentMap.isHidden {
            // Nothing shows the line index (Wrap to Page, or both turned
            // off): forget it, at no cost per key; it is built again when
            // the gutter or the map needs it.
            lineIndex.reset()
        } else if let storage = notification.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) {
            let linesChanged = lineIndex.edit(editedRange: storage.editedRange, changeInLength: storage.changeInLength)
            if scrollView.rulersVisible {
                if linesChanged {
                    // The width waits for the next turn: a new width
                    // retiles the scroll view, which lays out text, and
                    // the storage is still editing here (an exception).
                    RunLoop.main.perform { [weak self] in
                        MainActor.assumeIsolated { self?.lineNumberView.updateThickness() }
                    }
                    lineNumberView.redraw()
                } else {
                    // Only text inside a line changed: no number moves at
                    // once, so typing does not pay for the gutter each key.
                    lineNumberView.scheduleRedraw()
                }
            }
            documentMap.textDidChange()
        }
        guard hasMultiplePages, let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        // The edit left glyphs and layout after it to make again.
        idleGlyphsDone = min(idleGlyphsDone, storage.editedRange.location)
        scheduleIdleLayout()
        guard storage.changeInLength < 0 else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.removeEmptyTrailingPages() }
        }
    }

    /// The "storage edit" signpost interval (M8 n7) runs from here to
    /// `documentTextDidProcessEditing`.
    private var storageEditSignpost: OSSignpostIntervalState?

    @objc nonisolated private func documentTextWillProcessEditing(_ notification: Notification) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { storageEditSignpost = Signposts.beginStorageEdit() }
    }

    // MARK: Idle layout in Wrap to Page (M8 n3)

    /// AppKit's background layout laid out Wrap to Page in pieces that
    /// blocked the main thread for 370 ms on a 10 MB file: the first
    /// layout call made the glyphs for the whole text at once. In Wrap to
    /// Page the window turns it off and does the work itself, in slices of
    /// about this long per run-loop turn: first the glyphs, then the
    /// layout (which adds the page views). Events and drawing run between
    /// slices. Wrap to Window keeps AppKit's background layout, which
    /// non-contiguous layout keeps near what is shown.
    static let idleLayoutSliceSeconds = 0.012
    /// Characters per glyph or layout call; doubled or halved to fit the slice.
    private var idleGlyphChunk = 65_536
    private var idleLayoutChunk = 4_096
    /// Glyphs are known to exist for the characters before this index.
    /// Lowered by edits (`documentTextDidProcessEditing`).
    private(set) var idleGlyphsDone = 0
    /// The next slice, while one is scheduled. Read by tests.
    private(set) var idleLayoutTimer: Timer?
    /// The window closed: no more idle layout (M8 review row 9).
    private var isClosed = false
    #if DEBUG
    /// Tests: replaces the layout call of a slice (`ensureLayout`), so a
    /// test can make a slice that lays out nothing.
    var idleLayoutCallForTests: ((NSLayoutManager, NSRange) -> Void)?
    #endif

    /// Lays out one more slice on the next run-loop turn, in the default
    /// mode only (not while the user drags a scroller or a menu is open,
    /// as AppKit's background layout).
    private func scheduleIdleLayout() {
        guard hasMultiplePages, !isClosed, idleLayoutTimer == nil else { return }
        let timer = Timer(timeInterval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.idleLayoutTimer = nil
                self.layOutIdleSlice()
            }
        }
        idleLayoutTimer = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    /// One slice: glyphs while some are missing, else layout. Calls the
    /// next slice while work is left.
    private func layOutIdleSlice() {
        guard hasMultiplePages, let length = layoutManager.textStorage?.length else { return }
        let budget = UInt64(Self.idleLayoutSliceSeconds * 1e9)
        let start = DispatchTime.now().uptimeNanoseconds
        /// Runs `work` and adapts `chunk` to the time it took.
        func timed(_ chunk: inout Int, _ work: () -> Void) -> UInt64 {
            let callStart = DispatchTime.now().uptimeNanoseconds
            work()
            let now = DispatchTime.now().uptimeNanoseconds
            let call = now - callStart
            if call < budget / 4 {
                chunk = min(chunk * 2, 1 << 22)
            } else if call > budget / 2 {
                chunk = max(chunk / 2, 256)
            }
            return now
        }
        idleGlyphsDone = min(idleGlyphsDone, length)
        while idleGlyphsDone < length {
            let range = NSRange(location: idleGlyphsDone, length: min(idleGlyphChunk, length - idleGlyphsDone))
            let now = timed(&idleGlyphChunk) { layoutManager.ensureGlyphs(forCharacterRange: range) }
            idleGlyphsDone = NSMaxRange(range)
            if now - start >= budget { return scheduleIdleLayout() }
        }
        var next = layoutManager.firstUnlaidCharacterIndex()
        while next < length {
            let end = min(length, next + idleLayoutChunk)
            let now = timed(&idleLayoutChunk) {
                let range = NSRange(location: end - 1, length: 1)
                #if DEBUG
                if let idleLayoutCallForTests { return idleLayoutCallForTests(layoutManager, range) }
                #endif
                layoutManager.ensureLayout(forCharacterRange: range)
            }
            let reached = layoutManager.firstUnlaidCharacterIndex()
            // No progress: stop, and schedule nothing (M8 review row 1).
            // An edit or a new page size starts it again.
            guard reached > next else { return }
            next = reached
            if now - start >= budget { break }
        }
        if next < length { scheduleIdleLayout() }
    }

    /// Stops the idle layout: the next slice is not run.
    private func stopIdleLayout() {
        idleLayoutTimer?.invalidate()
        idleLayoutTimer = nil
    }

    /// Forgets what the idle layout knew; the glyph pass starts at 0.
    private func resetIdleLayout() {
        stopIdleLayout()
        idleGlyphsDone = 0
        idleGlyphChunk = 65_536
        idleLayoutChunk = 4_096
    }

    /// The window closes: the idle layout stops for good (M8 review row 9).
    func windowWillClose(_ notification: Notification) {
        isClosed = true
        stopIdleLayout()
        lineIndex.stop()
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

    /// The document's print info changed: take its paper and margins and
    /// resize every page (DocumentWindowController.m:264-279).
    func printInfoUpdated() {
        guard hasMultiplePages, let pagesView, let textDocument, pagesView.layout != textDocument.pageLayout else { return }
        pagesView.layout = textDocument.pageLayout
        var page = 0
        // Re-read the counts each time: resizing a page can add or remove pages.
        while page < min(numberOfPages, layoutManager.textContainers.count) {
            let frame = pagesView.documentRect(forPage: page)
            let container = layoutManager.textContainers[page]
            container.size = frame.size
            container.textView?.frame = frame
            page += 1
        }
        scheduleIdleLayout()
    }

    /// Lays out the whole text, so Wrap to Page has every page; printing
    /// needs them all (Document.m:643-645). Only the print path calls this.
    func layOutWholeText() {
        let length = layoutManager.textStorage?.length ?? 0
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: length))
    }

    // MARK: Line numbers and the document map (1.2.0)

    /// Shows or hides the gutter and the map from View > Show Line Numbers
    /// and Show Document Map. Both hide in Wrap to Page and for a file in
    /// large-file mode (over 50 MB): its line index would take 8 bytes a
    /// line, gigabytes for a 1 GB file of short lines, so none is built.
    /// The window keeps its size: the text area gives or takes the room.
    func updateGutterAndMap() {
        let shown = !hasMultiplePages && textDocument?.isLargeFile != true
        let showGutter = shown && Defaults.store.bool(forKey: Defaults.showLineNumbersKey)
        let showMap = shown && Defaults.store.bool(forKey: Defaults.showDocumentMapKey)
        if !showGutter && !showMap { lineIndex.reset() }
        let firstView = layoutManager.textContainers.first?.textView
        lineNumberView.textView = firstView
        documentMap.textView = firstView
        if scrollView.hasVerticalRuler != showGutter || scrollView.rulersVisible != showGutter {
            scrollView.hasVerticalRuler = showGutter
            scrollView.rulersVisible = showGutter
        }
        if showGutter { lineNumberView.updateThickness() }
        if documentMap.isHidden == showMap {
            documentMap.isHidden = !showMap
            container.tile()
        }
        lineNumberView.redraw()
        documentMap.needsDisplay = true
        if !isSettingSize, viewSize != .zero { recordViewSize() }
    }

    /// Scrolled, or the text area changed size: the gutter and the map move.
    @objc private func visibleTextMoved(_ notification: Notification) {
        if scrollView.rulersVisible { lineNumberView.redraw() }
        if !documentMap.isHidden { documentMap.needsDisplay = true }
    }

    /// The line index found more lines on an idle turn.
    private func lineIndexProgressed() {
        if scrollView.rulersVisible {
            lineNumberView.updateThickness()
            lineNumberView.redraw()
        }
        if !documentMap.isHidden { documentMap.needsDisplay = true }
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
        var scrollSize = NSScrollView.frameSize(forContentSize: size,
                                                horizontalScrollerClass: scrollView.hasHorizontalScroller ? NSScroller.self : nil,
                                                verticalScrollerClass: scrollView.hasVerticalScroller ? NSScroller.self : nil,
                                                borderType: scrollView.borderType, controlSize: .regular,
                                                scrollerStyle: style)
        // NSScrollView's size math leaves out rulers; the map is beside it.
        scrollSize.width += sideWidth
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
        size.width -= gutterWidth
        if !hasMultiplePages { size.width -= MultiplePageView.textPadding * 2 }
        return size
    }

    /// The gutter's width while it shows, else 0.
    var gutterWidth: CGFloat {
        scrollView.hasVerticalRuler && scrollView.rulersVisible ? lineNumberView.ruleThickness : 0
    }

    /// The width the gutter and the map take beside the text area.
    var sideWidth: CGFloat { gutterWidth + container.mapWidth }

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
        let paper = textDocument.pageLayout.paperSize
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
        return Signposts.interval("line ending") {
            let ending = document.format.lineEnding
            guard ending != .lf else { return false }
            textView.insertText(ending.string, replacementRange: textView.selectedRange())
            return true
        }
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
              Signposts.interval("encoding check", { strings.contains(where: { document.insertionDoesNotFit($0) }) })
        else { return }
        textView.breakUndoCoalescing()
        encodingCheckPending = true
    }

    func textDidChange(_ notification: Notification) {
        Signposts.markOnce(.firstKeyAccepted)
        // A blank untitled window stays off the saved window list (1.2.0).
        if textDocument?.fileURL == nil { textDocument?.updateRestorable() }
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

    /// Prevent Editing, or a file too large to edit (M8, V3), makes every
    /// view read-only; during a large-file reload the views take no input
    /// at all (M8 review row 19), and from the start of any reload they
    /// take no edits (row 40).
    func updateEditable() {
        let editable = !(textDocument?.preventsEditing ?? false) && !(textDocument?.isTooLargeToEdit ?? false)
            && !isReloading && !(textDocument?.isReloading ?? false)
        let tooLarge = textDocument?.isTooLargeToEdit ?? false
        for view in textViews {
            view.isEditable = editable
            view.isSelectable = !isReloading
            // No Writing Tools on a file too large to edit (P73).
            TextViewFactory.setWritingTools(on: !tooLarge, view)
        }
    }

    /// A large-file reload has detached this window's layout manager.
    private(set) var isReloading = false

    /// The files of the drag over the window that QuickEdit opens, worked
    /// out once when the drag enters (M9 review row 11); nil between drags.
    private(set) var draggedOpenableURLs: [URL]?

    func beginReload() {
        isReloading = true
        stopIdleLayout()
        // The text is replaced on another thread now: the line index stops
        // scanning and answering, so the gutter and the map read nothing.
        lineIndex.pause()
        updateEditable()
    }

    /// The text is back: in Wrap to Page the idle layout starts again
    /// from the start, as the new text has no glyphs yet (M8 review row 34).
    func endReload() {
        isReloading = false
        lineIndex.resume()
        updateGutterAndMap()
        updateEditable()
        if hasMultiplePages {
            resetIdleLayout()
            scheduleIdleLayout()
        }
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

// MARK: New Tab (M11)

extension DocumentWindowController {
    /// The tab bar's + button: a new untitled document as a tab of this
    /// window (TabCommands.openNewTab). It also makes AppKit show the +
    /// button. Nothing happens while the window shows a sheet or a Save
    /// panel. File > New Tab goes through NewTabCommand instead.
    override func newWindowForTab(_ sender: Any?) {
        guard TabCommands.canAddTab(to: window) else { return }
        TabCommands.openNewTab(in: window)
    }
}

// MARK: Files dropped on the window (P72)

/// NSWindow sends the dragging-destination calls to its delegate. Only
/// files QuickEdit can open are taken; each opens in its own window, as a
/// file dropped on the Dock icon does.
extension DocumentWindowController: NSDraggingDestination {
    /// The dragged files that QuickEdit opens: plain-text types it reads,
    /// no folders.
    static func openableFileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let controller = NSDocumentController.shared
        return urls.filter { url in
            guard let type = try? controller.typeForContents(of: url) else { return false }
            return controller.documentClass(forType: type) != nil
        }
    }

    /// Reads each dragged file's type once per drag; draggingUpdated, sent
    /// on every mouse move, reuses the answer.
    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let urls = Self.openableFileURLs(on: sender.draggingPasteboard)
        draggedOpenableURLs = urls
        return urls.isEmpty ? [] : .copy
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let urls = draggedOpenableURLs else { return draggingEntered(sender) }
        return urls.isEmpty ? [] : .copy
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        draggedOpenableURLs = nil
    }

    func draggingEnded(_ sender: any NSDraggingInfo) {
        draggedOpenableURLs = nil
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = draggedOpenableURLs ?? Self.openableFileURLs(on: sender.draggingPasteboard)
        draggedOpenableURLs = nil
        guard !urls.isEmpty else { return false }
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
        return true
    }
}
