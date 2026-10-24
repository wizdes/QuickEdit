import AppKit
import UniformTypeIdentifiers

/// The app's NSDocumentController. Created in main.swift before anything asks
/// for `NSDocumentController.shared`, so it becomes the shared instance.
final class DocumentController: NSDocumentController {
    override init() {
        super.init()
        // TextEdit binds this to the AutosavingDelay default (DocumentController.m:72-77).
        autosavingDelay = TimeInterval(Defaults.integer(.autosavingDelay))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("DocumentController is built in code") }

    /// QuickEdit writes only plain text.
    override var defaultType: String? { TextDocument.plainTextType }

    /// A file of any plain-text type (.md, .swift, .csv...) opens as
    /// `public.plain-text`, the one type QuickEdit writes, so Save and
    /// autosave can write it in place. TextEdit narrows types the same way
    /// (reference/apple/Document.m:80-100 and :167). AppKit calls this on
    /// background threads while it opens files, so it must not need the main
    /// actor; it reads the file's type itself instead of calling super, and
    /// returns other types unchanged so AppKit shows its own "cannot open
    /// files in this format" error for them.
    override nonisolated func typeForContents(of url: URL) throws -> String {
        guard let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
        }
        return type.conforms(to: .plainText) ? TextDocument.plainTextType : type.identifier
    }

    // MARK: Transient untitled window (reference/apple/DocumentController.m:153-277)

    /// Set while a file is on its way to replace the transient window; other
    /// files opened meanwhile wait here so they cascade from the replaced
    /// window, as in TextEdit. Main thread only: AppKit calls the open
    /// completion handlers on the main thread, so no locks are needed.
    private var replacingTransient = false
    private var deferredDocuments: [NSDocument] = []

    /// The untitled window made by the launch (open-application) or Dock
    /// (reopen-application) Apple event is transient. File > New is not.
    override func openUntitledDocumentAndDisplay(_ displayDocument: Bool) throws -> NSDocument {
        let document = try super.openUntitledDocumentAndDisplay(displayDocument)
        if documents.count == 1, let textDocument = document as? TextDocument,
           let event = NSAppleEventManager.shared().currentAppleEvent, event.eventClass == kCoreEventClass,
           event.eventID == kAEOpenApplication || event.eventID == kAEReopenApplication {
            textDocument.isTransient = true
        }
        return document
    }

    /// A second document ends the first one's transient state.
    override func addDocument(_ document: NSDocument) {
        if documents.count == 1, let first = documents.first as? TextDocument, first.isTransient {
            first.isTransient = false
        }
        super.addDocument(document)
    }

    private func transientDocumentToReplace() -> TextDocument? {
        guard documents.count == 1, let only = documents.first as? TextDocument,
              only.isTransientAndCanBeReplaced else { return nil }
        return only
    }

    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        guard displayDocument else {
            // Opens without a window (none in M2) leave the transient window alone.
            super.openDocument(withContentsOf: url, display: false, completionHandler: completionHandler)
            return
        }
        if let transient = transientDocumentToReplace() {
            // Claim it now so files opened meanwhile do not claim it too.
            transient.isTransient = false
            replacingTransient = true
            super.openDocument(withContentsOf: url, display: false) { document, wasOpen, error in
                if let document {
                    self.replace(transient, with: document)
                }
                self.replacingTransient = false
                let waiting = self.deferredDocuments
                self.deferredDocuments = []
                for other in waiting { self.display(other) }
                completionHandler(document, wasOpen, error)
            }
        } else if replacingTransient {
            super.openDocument(withContentsOf: url, display: false) { document, wasOpen, error in
                if let document {
                    if self.replacingTransient { self.deferredDocuments.append(document) } else { self.display(document) }
                }
                completionHandler(document, wasOpen, error)
            }
        } else {
            super.openDocument(withContentsOf: url, display: true, completionHandler: completionHandler)
        }
    }

    /// Closes the transient document and shows `document` in a window with
    /// the same frame. (TextEdit moves the window controller itself across;
    /// a new window at the old frame looks the same and keeps each window
    /// controller tied to one text storage.)
    private func replace(_ transient: TextDocument, with document: NSDocument) {
        let frame = transient.windowControllers.first?.window?.frame
        transient.close()
        if document.windowControllers.isEmpty { document.makeWindowControllers() }
        if let frame, let window = document.windowControllers.first?.window {
            window.setFrame(frame, display: false)
        }
        document.showWindows()
        // The window now shows other text; tell VoiceOver (DocumentController.m:207-213).
        if let textView = (document.windowControllers.first as? DocumentWindowController)?.textView {
            NSAccessibility.post(element: textView, notification: .valueChanged)
        }
    }

    private func display(_ document: NSDocument) {
        if document.windowControllers.isEmpty { document.makeWindowControllers() }
        document.showWindows()
    }
}
