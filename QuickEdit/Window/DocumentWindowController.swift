import AppKit

/// One window per document: a scroll view around one TextKit 1 text view on
/// the document's storage (contract `win-text`).
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
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
        shouldCascadeWindows = true
        window.delegate = self
        window.center()
        updateEditable(for: document)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("DocumentWindowController is built in code") }

    func breakUndoCoalescing() {
        textView.breakUndoCoalescing()
    }

    func updateEditable() {
        if let document = document as? TextDocument { updateEditable(for: document) }
    }

    private func updateEditable(for document: TextDocument) {
        textView.isEditable = !document.preventsEditing
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if window?.firstResponder === textView {
            LaunchStamp.firstWindowReady()
        }
    }
}
