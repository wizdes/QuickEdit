import AppKit

/// One window per document: a scroll view around one TextKit 1 text view on
/// the document's storage (contract `win-text`).
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    let textView: NSTextView

    init(document: TextDocument) {
        let contentSize = TextViewFactory.initialContentSize()
        let scrollView = NSScrollView()
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

        textView = TextViewFactory.makeTextView(storage: document.textStorage, size: contentSize)
        scrollView.documentView = textView

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: frameSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.contentView = scrollView
        window.initialFirstResponder = textView
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        textView.delegate = self
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
        updateEditable(for: document)
        // Save the new selection and scroll place at the next state save.
        // invalidateRestorableState only marks the state dirty; AppKit
        // encodes it later, off the typing path.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(restorableStateChanged(_:)),
                           name: NSTextView.didChangeSelectionNotification, object: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(restorableStateChanged(_:)),
                           name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("DocumentWindowController is built in code") }

    // MARK: State restoration (selection and scroll place)

    private enum RestoreKey {
        static let selectionLocation = "QESelectionLocation"
        static let selectionLength = "QESelectionLength"
        static let topCharacter = "QETopCharacter"
    }

    @objc private func restorableStateChanged(_ notification: Notification) {
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
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            // Only the glyphs already laid out on screen are asked about.
            let glyphs = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: textView.visibleRect,
                                                  in: container)
            coder.encode(layoutManager.characterIndexForGlyph(at: glyphs.location), forKey: RestoreKey.topCharacter)
        }
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
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

    /// The selection and the first character on screen, so a reload can put
    /// them back (M2 review row 3).
    struct Place {
        var selection: NSRange
        var topCharacter: Int
    }

    func currentPlace() -> Place {
        var top = textView.selectedRange().location
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            let glyphs = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: textView.visibleRect, in: container)
            top = layoutManager.characterIndexForGlyph(at: glyphs.location)
        }
        return Place(selection: textView.selectedRange(), topCharacter: top)
    }

    /// Puts a saved place back, clamped to the text's new length.
    func restore(_ place: Place) {
        let length = textView.textStorage?.length ?? 0
        let location = min(place.selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(place.selection.length, length - location)))
        scrollLineToTop(containing: min(place.topCharacter, length))
    }

    /// Scrolls so the line holding `character` is the top line on screen.
    /// With non-contiguous layout, asking for that one line fragment lays out
    /// only around it, never the whole document.
    private func scrollLineToTop(containing character: Int) {
        let length = textView.textStorage?.length ?? 0
        guard let layoutManager = textView.layoutManager, length > 0, character <= length else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(character, length - 1))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        textView.scroll(NSPoint(x: 0, y: line.minY + textView.textContainerOrigin.y))
    }

    // MARK: Line endings and the encoding check (M3 n3)

    /// Set when an edit inserts a character the document's encoding cannot
    /// hold; the question is asked once the edit is in the storage.
    private var encodingCheckPending = false

    /// Return and Enter type the document's main line ending (LF for new
    /// documents), so a CRLF or CR file stays that way. Better than TextEdit,
    /// which always types LF (docs/codemap.md 4.3). Paste is untouched.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)),
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
        if let replacementString, let document = document as? TextDocument,
           document.insertionDoesNotFit(replacementString) {
            textView.breakUndoCoalescing()
            encodingCheckPending = true
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard encodingCheckPending else { return }
        encodingCheckPending = false
        guard let document = document as? TextDocument else { return }
        document.encodingNoLongerFits { [weak self] in
            self?.textView.undoManager?.undo()
        }
    }

    func breakUndoCoalescing() {
        textView.breakUndoCoalescing()
    }

    func updateEditable() {
        if let document = document as? TextDocument { updateEditable(for: document) }
    }

    private func updateEditable(for document: TextDocument) {
        textView.isEditable = !document.preventsEditing
    }

    /// The user took an interest in the window: it is no longer transient
    /// (reference/apple/DocumentWindowController.m:884-901).
    func windowDidResize(_ notification: Notification) {
        (document as? TextDocument)?.isTransient = false
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
