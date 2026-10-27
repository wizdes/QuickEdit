import AppKit
import Synchronization
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

    /// A file of any text type (.md, .swift, .json, .html...) opens as
    /// `public.plain-text`, the one type QuickEdit writes, so Save and
    /// autosave can write it in place. TextEdit narrows types the same way
    /// (reference/apple/Document.m:80-100 and :167). Any other file
    /// (extension-less or unknown data) opens as `public.data`, a Viewer type
    /// like TextEdit's "Unknown document": it is shown as plain text, and
    /// saving it goes through Save As to plain text. AppKit calls this on
    /// background threads while it opens files, so it must not need the main
    /// actor; it reads the file's type itself instead of calling super, and
    /// returns other types (folders, packages) unchanged so AppKit shows its
    /// own "cannot open files in this format" error for them.
    override nonisolated func typeForContents(of url: URL) throws -> String {
        guard let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
        }
        if type.conforms(to: .text) { return TextDocument.plainTextType }
        if type.conforms(to: .data) { return UTType.data.identifier }
        return type.identifier
    }

    // MARK: Open panel encoding (reference/apple/DocumentController.m:296-338)

    /// The Open panel's encoding choice per file, from the panel (main
    /// thread) to that file's read (a background thread). The read takes its
    /// entry; the open's completion clears any entry no read took (the file
    /// was already open). Keys are resolved paths. A stored nil is an
    /// explicit "Automatic".
    private nonisolated static let openPanelEncodings = Mutex<[String: String.Encoding?]>([:])

    private nonisolated static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    /// The Open panel's choice for `url`, removed as it is read: nil when the
    /// file was not opened from the Open panel, `.some(nil)` for Automatic.
    nonisolated static func takeOpenPanelEncoding(for url: URL) -> String.Encoding?? {
        openPanelEncodings.withLock { $0.removeValue(forKey: key(url)) }
    }

    nonisolated static func setOpenPanelEncoding(_ encoding: String.Encoding?, for urls: [URL]) {
        openPanelEncodings.withLock { choices in
            for url in urls { choices[key(url)] = .some(encoding) }
        }
    }

    /// Adds "Plain Text Encoding:" with Automatic first, starting at the
    /// `PlainTextEncoding` default. The choice applies only to the files
    /// opened from this panel.
    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 628, height: 58))
        let label = NSTextField(labelWithString: "Plain Text Encoding:")
        label.alignment = .right
        label.frame = NSRect(x: 99, y: 22, width: 132, height: 17)
        accessory.addSubview(label)
        let popUp = EncodingPopUpButton(selected: TextDocument.defaultOpenEncoding(), includeAutomatic: true)
        popUp.identifier = NSUserInterfaceItemIdentifier("openEncoding")
        popUp.frame = NSRect(x: 234, y: 16, width: 293, height: 26)
        accessory.addSubview(popUp)
        openPanel.accessoryView = accessory
        openPanel.isAccessoryViewDisclosed = true
        super.beginOpenPanel(openPanel, forTypes: inTypes) { result in
            if result == NSApplication.ModalResponse.OK.rawValue {
                Self.setOpenPanelEncoding(popUp.selectedEncoding, for: openPanel.urls)
            }
            completionHandler(result)
        }
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

    /// Quit (1.2.0): blank untitled documents go first, with no question
    /// and no autosaved copy, so they do not come back at the next launch.
    override func reviewUnsavedDocuments(withAlertTitle title: String?, cancellable: Bool, delegate: Any?,
                                         didReviewAllSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        TextDocument.discardBlankUntitledDocuments(closing: false)
        super.reviewUnsavedDocuments(withAlertTitle: title, cancellable: cancellable, delegate: delegate,
                                     didReviewAllSelector: didReviewAllSelector, contextInfo: contextInfo)
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
                               completionHandler originalHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        // A file that was already open is not read again; drop its choice.
        let completionHandler: (NSDocument?, Bool, Error?) -> Void = { document, wasOpen, error in
            _ = Self.takeOpenPanelEncoding(for: url)
            originalHandler(document, wasOpen, error)
        }
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
                    // The read ran on another thread; the user may have typed
                    // into, saved, or opened a sheet on the untitled window
                    // meanwhile. Then it stays, and the file gets its own window.
                    if self.canStillReplace(transient) {
                        self.replace(transient, with: document)
                    } else {
                        self.display(document)
                    }
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

    private func canStillReplace(_ transient: TextDocument) -> Bool {
        documents.contains(transient) && !transient.isDocumentEdited && transient.fileURL == nil
            && !transient.windowControllers.contains { $0.window?.attachedSheet != nil }
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
