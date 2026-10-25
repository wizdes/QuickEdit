import AppKit
import Synchronization
import UniformTypeIdentifiers

/// One open plain-text file (contract `doc-model`). Port of the plain-text parts
/// of reference/apple/Document.m.
final class TextDocument: NSDocument {
    nonisolated static let plainTextType = UTType.plainText.identifier

    /// The text. Filled by `read(from:ofType:)`, which AppKit may call on a
    /// background thread before any window (and so any layout manager) exists,
    /// and read by the write path while AppKit blocks user interaction.
    /// Everything else touches it on the main thread only.
    nonisolated(unsafe) let textStorage = NSTextStorage()

    /// How the file was stored on disk, so a save writes the same kind of bytes.
    nonisolated var format: DecodedText.Format {
        get { state.withLock { $0.format } }
        set { state.withLock { $0.format = newValue } }
    }

    /// The file did not fit any encoding and was shown with replacement
    /// characters; writing over it loses data, so the user is asked first
    /// (TextEdit's lossy flag, Document.m:247-250).
    nonisolated var loadedLossily: Bool {
        get { state.withLock { $0.loadedLossily } }
        set { state.withLock { $0.loadedLossily = newValue } }
    }

    /// Format > Prevent Editing. Not saved in plain files.
    private(set) var preventsEditing = false

    /// Format > Wrap to Page. New documents start from the `ShowPageBreaks`
    /// default; files read from disk start in Wrap to Window, as plain files
    /// do in TextEdit (Document.m:121, :253-258). Not saved in plain files.
    /// Not an undoable change and not an edit (TextEdit 1.9, Document.m:721-727).
    var hasMultiplePages = false {
        didSet {
            guard hasMultiplePages != oldValue else { return }
            for controller in windowControllers {
                (controller as? DocumentWindowController)?.setHasMultiplePages(hasMultiplePages)
            }
        }
    }

    /// Set once text has been read from a file, so the window starts in Wrap to Window.
    private nonisolated let wasRead = Atomic<Bool>(false)

    /// The untitled window made at launch (or by a Dock click with no
    /// windows), not yet touched. Opening a file replaces it in place
    /// (reference/apple/Document.m:525-543, DocumentController.m:153-277).
    /// Any edit, a window move or resize, or a second document clears it.
    var isTransient = false

    /// A transient document can be replaced only while no sheet is open on it.
    var isTransientAndCanBeReplaced: Bool {
        isTransient && !windowControllers.contains { $0.window?.attachedSheet != nil }
    }

    /// The paper and margins for Wrap to Page and PDFs: Settings' paper
    /// size when the document is made (new or opened), then kept, so an
    /// open document does not change when the setting does (M7 review
    /// item 4). AppKit may make documents on a background thread, hence
    /// the lock.
    private nonisolated let fixedPageLayout = Mutex(PageLayout.forNewDocument())
    /// The print info `printInfo` hands out; made on first read.
    private var ownPrintInfo: NSPrintInfo?
    /// The PDF Save panel is open: a second Print… or Export waits (item 6).
    private(set) var isPDFPanelOpen = false
    /// A large PDF being written off the main thread (M8 n6); a second
    /// Print… or Export waits for it too.
    private(set) var pdfJob: PDFJob?
    /// Tests: replace the PDF Save panel and the PDF writer.
    var pdfPanelRunner: PDFPanelRunner?
    var pdfWriter: ((URL, PDFOptions) throws -> Void)?
    /// How often AppKit asked for a print operation (tests; always refused).
    private(set) var printOperationRequests = 0

    /// Built from `pageLayout`, never copied from NSPrintInfo.shared:
    /// QuickEdit has no Page Setup (U1). Kept here, not in NSDocument: its
    /// setter records an undoable change, so a first read would mark the
    /// document edited (M7 review item 3). Setting a print info (only tests
    /// do) takes its paper and margins as the page layout.
    /// `dynamic`, so a Swift caller goes through the Objective-C setter and
    /// key-value observers (the window's page view) hear the change.
    @objc dynamic override var printInfo: NSPrintInfo {
        get {
            if let ownPrintInfo { return ownPrintInfo }
            let info = pageLayout.makePrintInfo()
            ownPrintInfo = info
            return info
        }
        set {
            fixedPageLayout.withLock { $0 = PageLayout(printInfo: newValue) }
            ownPrintInfo = newValue
        }
    }

    /// Shows the encoding and lossy-file alerts; tests put a fake here.
    lazy var alertPresenter: DocumentAlertPresenter = SheetAlertPresenter()

    private struct State {
        var format = DecodedText.Format.newDocument
        var loadedLossily = false
        /// The Open panel's choice for this file (an encoding or Automatic),
        /// used again by a revert and an outside-change reload.
        var openChoice = OpenChoice.none
        /// The last write recorded the encoding in the xattr.
        var attributeWritten = true
        /// The format the running save writes, when the Save panel chose a
        /// new encoding; nil means the document's own format.
        var pendingWriteFormat: DecodedText.Format?
        /// Bytes of the file as last read; 0 for a new document.
        var readByteCount = 0
    }
    private nonisolated let state = Mutex(State())

    /// What the Open panel said about this file. Automatic is a real choice,
    /// distinct from "no panel" (M3+M5 review row 2): only "no panel" falls
    /// back to the `PlainTextEncoding` default.
    enum OpenChoice: Equatable, Sendable {
        case none, automatic, encoding(String.Encoding)
    }

    /// The `preferred` encoding for a decode of this file.
    private nonisolated func preferredEncoding() -> String.Encoding? {
        switch state.withLock({ $0.openChoice }) {
        case .none: Self.defaultOpenEncoding()
        case .automatic: nil
        case .encoding(let chosen): chosen
        }
    }

    #if DEBUG
    /// Seams for unit tests only; compiled out of Release builds.
    struct TestHooks {
        /// Runs on the writing thread right after `unblockUserInteraction()`.
        var afterUnblock: (@Sendable () -> Void)?
        /// Runs at the start of `read(from:ofType:)`; the argument says whether
        /// the read is on the main thread.
        var onRead: (@Sendable (_ isMainThread: Bool) -> Void)?
        /// Replaces the last-resort fallback encoding (the system's default
        /// C-string encoding), so a test can reach the lossy path.
        var fallbackEncoding: String.Encoding?
        /// Makes the `com.apple.TextEncoding` write fail, as setxattr can
        /// (for example on a volume without extended attributes).
        var failAttributeWrite = false
        /// Runs with the temporary PDF file after it is drawn and before it
        /// is checked and moved, so a test can see its folder or remove it.
        var pdfTemporaryFile: (@Sendable (URL) -> Void)?
        /// Runs with the private folder a PDF is drawn in, when it is made.
        var pdfTemporaryFolder: (@Sendable (URL) -> Void)?
    }
    nonisolated static let testHooks = Mutex(TestHooks())
    #endif

    /// AppKit makes documents on a background thread when
    /// `canConcurrentlyReadDocuments` is true, so this init must not carry the
    /// main-actor check Swift would add by default (it crashed the app).
    override nonisolated init() {
        super.init()
    }

    override nonisolated class var autosavesInPlace: Bool { true }

    override nonisolated class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    /// An edit ends the transient state (Document.m:998-1004). The first
    /// edit of a lossily loaded file asks before it can be written over.
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        isTransient = false
        super.updateChangeCount(change)
        if change == .changeDone || change == .changeRedone {
            confirmEditingLossyFile()
        }
    }

    override func makeWindowControllers() {
        if !wasRead.load(ordering: .relaxed) {
            hasMultiplePages = Defaults.bool(.showPageBreaks)
        }
        addWindowController(DocumentWindowController(document: self))
    }

    // MARK: Reading

    /// Files bigger than this many bytes open in large-file mode (M8 n2):
    /// the window turns off spelling, grammar, data detectors and the
    /// substitutions, which work on the text as it is typed, and says so in
    /// its title. 50 MB is the M8 brief's starting point. Tests change it.
    nonisolated(unsafe) static var largeFileThreshold = 50 * 1024 * 1024

    /// The file this document was read from is over `largeFileThreshold`.
    var isLargeFile: Bool {
        state.withLock { $0.readByteCount } > Self.largeFileThreshold
    }

    /// The `PlainTextEncoding` default: nil means Automatic.
    nonisolated static func defaultOpenEncoding() -> String.Encoding? {
        let raw = (Defaults.store.object(forKey: DefaultsKey.plainTextEncoding.rawValue) as? NSNumber)?.intValue
            ?? Defaults.noStringEncoding
        return raw == Defaults.noStringEncoding ? nil : String.Encoding(rawValue: UInt(raw))
    }

    /// Reads the file itself (not through `read(from data:)`) so decoding can
    /// see the file's `com.apple.TextEncoding` xattr and the Open panel's
    /// encoding choice for this URL.
    override nonisolated func read(from url: URL, ofType typeName: String) throws {
        #if DEBUG
        Self.testHooks.withLock { $0.onRead }?(Thread.isMainThread)
        #endif
        let signpost = Signposts.beginRead()
        defer { Signposts.endRead(signpost) }
        // Mapped, not copied (M8 n2): the decode reads the file's pages
        // straight from the file cache, so a 100 MB file does not first
        // take 100 MB of memory as a copy of its bytes.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        state.withLock { $0.readByteCount = data.count }
        switch DocumentController.takeOpenPanelEncoding(for: url) {
        case .some(.some(let chosen)): state.withLock { $0.openChoice = .encoding(chosen) }
        case .some(.none): state.withLock { $0.openChoice = .automatic }
        case .none: break // not from the Open panel: keep this document's choice
        }
        let decoded = try decode(data, url: url, preferred: preferredEncoding())
        Signposts.mark(.decodeEnd)
        load(decoded)
    }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        try load(decode(data, url: nil, preferred: Self.defaultOpenEncoding()))
    }

    /// PlainTextIO.decode with AppKit's fallback encoding, as an NSError
    /// AppKit can show ("…couldn't be opened using text encoding X.").
    nonisolated func decode(_ data: Data, url: URL?, preferred: String.Encoding?) throws -> DecodedText {
        var fallback = String.defaultCStringEncoding
        #if DEBUG
        if let hook = Self.testHooks.withLock({ $0.fallbackEncoding }) { fallback = hook }
        #endif
        do {
            return try PlainTextIO.decode(data, url: url, preferred: preferred, fallback: fallback)
        } catch PlainTextIO.Error.inapplicableEncoding(let encoding) {
            var info: [String: Any] = [NSStringEncodingErrorKey: encoding.rawValue]
            if let url { info[NSURLErrorKey] = url }
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: info)
        }
    }

    /// Puts decoded text into the storage.
    private nonisolated func load(_ decoded: DecodedText) {
        let attributes = TextViewFactory.plainTextAttributes()
        let layoutManagers = textStorage.layoutManagers
        // Revert: empty the storage while the layout managers are still
        // attached, so every text view moves its selection inside the new,
        // empty text (reference/apple/Document.m:189). Without this a
        // selection past the new end throws on the next keystroke.
        if !layoutManagers.isEmpty {
            textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: "")
        }
        // Detach layout managers (only present on revert) so the storage is
        // filled with no layout work, then put them back.
        for manager in layoutManagers { textStorage.removeLayoutManager(manager) }
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length),
                                      with: NSAttributedString(string: decoded.text, attributes: attributes))
        textStorage.endEditing()
        for manager in layoutManagers { textStorage.addLayoutManager(manager) }
        state.withLock {
            $0.format = decoded.format
            $0.loadedLossily = decoded.lossy
        }
        wasRead.store(true, ordering: .relaxed)
    }

    // MARK: Changes made by other apps

    /// NSFilePresenter: the file changed on disk. Runs on a background queue.
    override nonisolated func presentedItemDidChange() {
        super.presentedItemDidChange()
        let document = self
        DispatchQueue.main.async {
            MainActor.assumeIsolated { document.reloadAfterOutsideChange() }
        }
    }

    /// The bytes of the last outside change that could not be decoded, so
    /// its error shows once (M2 review row 3).
    private var undecodableOnDisk: Data?

    /// Reloads a document that has no unsaved edits when another app changed
    /// its file. With unsaved edits it does nothing: NSDocument shows its own
    /// "changed by another application" sheet on the next save.
    /// It reads and decodes the bytes and replaces the text only when the
    /// text differs, keeping each window's selection (clamped) and scroll
    /// place; a date-only change keeps the text, the caret and undo.
    /// It runs inside NSDocument's file access, so no save overlaps it. (The
    /// asynchronous form: AppKit keeps the synchronous form's block after it
    /// returns, which Swift stops as an escaped non-escaping closure. With no
    /// other file access running, AppKit runs this block at once.)
    func reloadAfterOutsideChange() {
        guard !isDocumentEdited, fileURL != nil else { return }
        performAsynchronousFileAccess { done in
            MainActor.assumeIsolated { self.reloadFromDisk() }
            done()
        }
    }

    private func reloadFromDisk() {
        guard !isDocumentEdited, let url = fileURL else { return }
        let onDisk: Date?
        let data: Data
        do {
            onDisk = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            data = try Data(contentsOf: url)
        } catch {
            // The file was moved or deleted; NSDocument tracks moves itself.
            FileHandle.standardError.write(Data("QuickEdit: cannot read \(url.path) after an outside change: \(error)\n".utf8))
            return
        }
        if data == undecodableOnDisk { return }
        let decoded: DecodedText
        do {
            decoded = try decode(data, url: url, preferred: preferredEncoding())
        } catch {
            undecodableOnDisk = data
            fileModificationDate = onDisk
            alertPresenter.presentReloadError(self, error: error)
            return
        }
        undecodableOnDisk = nil
        fileModificationDate = onDisk
        // The new bytes decide large-file mode (M8 review row 2).
        state.withLock { $0.readByteCount = data.count }
        defer { updateLargeFileMode() }
        // UTF-16 code units, not Swift's canonical equivalence: "é" and
        // "e" + U+0301 are different text on disk (M3+M5 review row 4).
        guard !decoded.text.utf16.elementsEqual(textStorage.string.utf16) else {
            state.withLock {
                $0.format = decoded.format
                $0.loadedLossily = decoded.lossy
            }
            return
        }
        let windows = windowControllers.compactMap { $0 as? DocumentWindowController }
        let places = windows.map { $0.currentPlace() }
        load(decoded)
        undoManager?.removeAllActions()
        updateChangeCount(.changeCleared)
        for (window, place) in zip(windows, places) { window.restore(place) }
    }

    /// Revert reads the file again (`read(from:ofType:)` records its
    /// size); the windows then follow its large-file mode (M8 review row 2).
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        defer { updateLargeFileMode() }
        try super.revert(toContentsOf: url, ofType: typeName)
    }

    /// Every window turns its checks and title note on or off to match `isLargeFile`.
    private func updateLargeFileMode() {
        for controller in windowControllers {
            (controller as? DocumentWindowController)?.applyLargeFileMode()
        }
    }

    // MARK: Writing

    override nonisolated func canAsynchronouslyWrite(to url: URL, ofType typeName: String,
                                                     for saveOperation: NSDocument.SaveOperationType) -> Bool {
        true
    }

    override nonisolated func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        [Self.plainTextType]
    }

    override nonisolated func fileNameExtension(forType typeName: String,
                                                saveOperation: NSDocument.SaveOperationType) -> String? {
        "txt"
    }

    /// Every save, autosave included, starts here on the main thread.
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        // Undo stops at the save point (reference/apple/Document.m:884-896).
        for controller in windowControllers {
            (controller as? DocumentWindowController)?.breakUndoCoalescing()
        }
        // The Save panel's encoding applies only to the save that panel made
        // after it returned OK (Document.m:1187-1193). A cancelled panel, a
        // later Cmd+S or an autosave never sees it (M3+M5 review row 9).
        let panelEncoding = panelSession.encodingForSave(saveOperation, to: url, panelURL: savePanel?.url)
        let written = panelEncoding.map { PlainTextIO.format(format, changedTo: $0) }

        // Any operation that writes over the file the text was read from
        // (Save, Save As or Save To onto it, autosave in place) asks first
        // when that would change its bytes (M3+M5 review row 3).
        let overwritesLossyFile = loadedLossily && url.standardizedFileURL == fileURL?.standardizedFileURL
            && saveOperation != .autosaveElsewhereOperation
        let save = {
            self.state.withLock { $0.pendingWriteFormat = written }
            super.save(to: url, ofType: typeName, for: saveOperation) { error in
                if error == nil, let written {
                    // After a good Save or Save As the chosen encoding becomes
                    // the document's (Document.m:1232-1234). The xattr now
                    // names it, so a revert or reload reads it as Automatic
                    // does; if the xattr could not be written, the encoding
                    // itself is kept as the choice.
                    self.state.withLock {
                        $0.format = written
                        $0.openChoice = $0.attributeWritten ? .automatic : .encoding(written.encoding)
                    }
                }
                self.state.withLock { $0.pendingWriteFormat = nil }
                completionHandler(error)
            }
        }
        guard overwritesLossyFile else { return save() }
        askBeforeOverwritingLossyFile { overwrite in
            if overwrite { save() } else { completionHandler(CocoaError(.userCancelled)) }
        }
    }

    /// Runs on a background thread for async saves.
    override nonisolated func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                                    originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        let format = state.withLock { $0.pendingWriteFormat ?? $0.format }
        try write(to: url, as: format)
    }

    override nonisolated func write(to url: URL, ofType typeName: String) throws {
        try write(to: url, as: format)
    }

    /// AppKit blocks user interaction (the main thread waits) until
    /// `unblockUserInteraction()`, so the storage cannot change while it is
    /// copied here. Then the user can type again while the copy is encoded
    /// and written. The `com.apple.TextEncoding` xattr goes on the new file,
    /// as AppKit writes it for TextEdit (Document.m:1223-1224).
    private nonisolated func write(to url: URL, as format: DecodedText.Format) throws {
        let text = String(textStorage.string) // an immutable copy, not the live NSString
        unblockUserInteraction()
        #if DEBUG
        Self.testHooks.withLock { $0.afterUnblock }?()
        #endif
        let data: Data
        do {
            data = try PlainTextIO.encode(text, as: format)
        } catch {
            throw CocoaError(.fileWriteInapplicableStringEncoding,
                             userInfo: [NSStringEncodingErrorKey: format.encoding.rawValue, NSURLErrorKey: url])
        }
        try data.write(to: url, options: .atomic)
        // The xattr is best effort (M3+M5 review row 10): the bytes are
        // saved; a file without it opens by BOM, UTF-8 or the fallback.
        do {
            #if DEBUG
            if Self.testHooks.withLock({ $0.failAttributeWrite }) {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
            }
            #endif
            try PlainTextIO.writeAttribute(for: format.encoding, to: url)
            state.withLock { $0.attributeWritten = true }
        } catch {
            state.withLock { $0.attributeWritten = false }
            FileHandle.standardError.write(Data("QuickEdit: saved \(url.path) but could not record its text encoding: \(error)\n".utf8))
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        try PlainTextIO.encode(String(textStorage.string), as: format)
    }

    // MARK: Save panel

    override var shouldRunSavePanelWithAccessoryView: Bool { false }

    /// The Save panel this document showed last, and its encoding session.
    private var savePanel: NSSavePanel?
    private var panelSession = SavePanelSession()

    /// Opens the panel's session; `runModalSavePanel` calls this, and a test
    /// can play a panel without showing one.
    func beginSavePanelSession() { panelSession.begin() }

    /// Ends it: the panel was cancelled, or its save finished.
    func endSavePanelSession() {
        panelSession.end()
        savePanel = nil
    }

    /// Every Save panel AppKit shows for this document comes through here
    /// (Save of an untitled document, Save As, the "choose another encoding"
    /// sheet). The panel's choice lives only until AppKit reports the
    /// panel's outcome, cancelled or saved.
    override func runModalSavePanel(for saveOperation: NSDocument.SaveOperationType, delegate: Any?,
                                    didSave didSaveSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        beginSavePanelSession()
        let forward = SavePanelCallback { [weak self] didSave in
            self?.endSavePanelSession()
            guard let self, let target = delegate as? NSObject, let didSaveSelector else { return }
            typealias DidSave = @convention(c) (NSObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
            let implementation = unsafeBitCast(target.method(for: didSaveSelector), to: DidSave.self)
            implementation(target, didSaveSelector, self, didSave, contextInfo)
        }
        super.runModalSavePanel(for: saveOperation, delegate: forward,
                                didSave: #selector(SavePanelCallback.document(_:didSave:contextInfo:)), contextInfo: nil)
    }

    /// Move To may show a Save panel with this accessory; its end closes the session.
    override func move(completionHandler: ((Bool) -> Void)? = nil) {
        super.move { didMove in
            self.endSavePanelSession()
            completionHandler?(didMove)
        }
    }

    /// The encoding a new save suggests: `PlainTextEncodingForWrite` when it
    /// is set and holds the text, else UTF-8 (Document.m:368-379).
    func suggestedSaveEncoding() -> String.Encoding {
        let raw = (Defaults.store.object(forKey: DefaultsKey.plainTextEncodingForWrite.rawValue) as? NSNumber)?.intValue
            ?? Defaults.noStringEncoding
        if raw != Defaults.noStringEncoding {
            let chosen = String.Encoding(rawValue: UInt(raw))
            if chosen != .utf16, chosen != .utf8, textStorage.string.canBeConverted(to: chosen) { return chosen }
        }
        return .utf8
    }

    /// The Save panel's start encoding: the document's if the text still
    /// fits it, else the suggested one (Document.m:1276-1277). A new
    /// document that was never read or saved has no encoding of its own yet
    /// (TextEdit's NoStringEncoding), so it starts at the suggested one: the
    /// "Saving files" encoding when it holds the text (TextEdit
    /// `suggestedDocumentEncoding`, M6 review row 6).
    func initialSaveEncoding() -> String.Encoding {
        if fileURL == nil, !wasRead.load(ordering: .relaxed) { return suggestedSaveEncoding() }
        let current = format.encoding
        return textStorage.string.canBeConverted(to: current) ? current : suggestedSaveEncoding()
    }

    /// Turns off every item whose encoding cannot hold `text`, unless items x
    /// characters is 5,000,000 or more (too slow, Document.m:1306-1315).
    static func disableUnfitItems(in popUp: NSPopUpButton, text: String) {
        let length = (text as NSString).length
        guard popUp.numberOfItems * length < 5_000_000 else { return }
        for item in popUp.itemArray {
            guard let encoding = EncodingManager.encoding(of: item), !PlainTextIO.holdsAnyText(encoding) else { continue }
            item.isEnabled = text.canBeConverted(to: encoding)
        }
    }

    /// TextEdit's encoding pop-up and ".txt" checkbox (Document.m:1266-1321),
    /// laid out with the frames of TextEdit's EncodingAccessory.nib.
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        self.savePanel = savePanel
        let encoding = initialSaveEncoding()
        if !panelSession.isOpen { panelSession.begin() }
        panelSession.choose(encoding)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 628, height: 58))
        let label = NSTextField(labelWithString: "Plain Text Encoding:")
        label.alignment = .right
        label.frame = NSRect(x: 99, y: 33, width: 132, height: 17)
        accessory.addSubview(label)
        let popUp = EncodingPopUpButton(selected: encoding, includeAutomatic: false)
        popUp.identifier = NSUserInterfaceItemIdentifier("saveEncoding")
        popUp.frame = NSRect(x: 234, y: 27, width: 293, height: 26)
        popUp.target = self
        popUp.action = #selector(encodingPopUpChanged(_:))
        // Also after a Customize Encodings change refills it (M3+M5 review row 6).
        popUp.refreshEnabledItems = { [weak self] popUp in
            guard let self else { return }
            Self.disableUnfitItems(in: popUp, text: self.textStorage.string)
        }
        Self.disableUnfitItems(in: popUp, text: textStorage.string)
        accessory.addSubview(popUp)

        let checkbox = NSButton(checkboxWithTitle: "If no extension is provided, use \u{201C}.txt\u{201D}.",
                                target: self, action: #selector(appendPlainTextExtensionChanged(_:)))
        checkbox.identifier = NSUserInterfaceItemIdentifier("appendTxtExtension")
        checkbox.toolTip = "Automatically append \u{201C}.txt\u{201D} to the file name if no known file name extension is provided."
        checkbox.state = Defaults.bool(.addExtensionToNewPlainTextFiles) ? .on : .off
        checkbox.sizeToFit()
        checkbox.setFrameOrigin(NSPoint(x: 234, y: 7))
        accessory.addSubview(checkbox)
        savePanel.accessoryView = accessory
        PlainTextExtensionPanelDelegate.install(on: savePanel)

        applyExtensionChoice(checkbox.state == .on, to: savePanel)
        if checkbox.state == .off {
            // NSDocument put ".txt" on the suggested name; show the bare name
            // instead, once, when the panel opens (Document.m:1291-1302).
            var name: String?
            if let fileURL { name = try? fileURL.resourceValues(forKeys: [.nameKey]).name }
            savePanel.nameFieldStringValue = name ?? displayName ?? ""
        }
        return true
    }

    /// Document.m:743-745.
    @objc private func encodingPopUpChanged(_ sender: EncodingPopUpButton) {
        guard let encoding = sender.selectedEncoding else { return }
        panelSession.choose(encoding)
    }

    /// Changes only the allowed types, never the typed name (Document.m:737-741).
    @objc private func appendPlainTextExtensionChanged(_ sender: NSButton) {
        guard let savePanel else {
            FileHandle.standardError.write(Data("QuickEdit: .txt checkbox changed with no Save panel\n".utf8))
            return
        }
        applyExtensionChoice(sender.state == .on, to: savePanel)
    }

    private func applyExtensionChoice(_ addsExtension: Bool, to savePanel: NSSavePanel) {
        savePanel.allowedContentTypes = addsExtension ? [.plainText] : []
        savePanel.allowsOtherFileTypes = addsExtension
    }

    // MARK: Encoding no longer fits (P25, Document.m:980-1047)

    private var isAskingAboutEncoding = false

    /// True when `inserted` (only the new characters, never the whole text)
    /// has a character the document's encoding cannot hold. Untitled
    /// documents are skipped, as in TextEdit (Document.m:983).
    func insertionDoesNotFit(_ inserted: String) -> Bool {
        guard fileURL != nil, !inserted.isEmpty else { return false }
        let encoding = format.encoding
        return !PlainTextIO.holdsAnyText(encoding) && !inserted.canBeConverted(to: encoding)
    }

    /// The text no longer fits the encoding: TextEdit's sheet. OK opens the
    /// Save panel to pick another encoding; Cancel, or cancelling that
    /// panel, runs `undo` to take the edit back.
    func encodingNoLongerFits(undo: @escaping () -> Void) {
        guard !isAskingAboutEncoding else { return }
        isAskingAboutEncoding = true
        let name = String.localizedName(of: format.encoding)
        alertPresenter.askToChooseAnotherEncoding(self, encodingName: name) { ok in
            guard ok else {
                self.isAskingAboutEncoding = false
                undo()
                return
            }
            self.alertPresenter.runSavePanel(self) { saved in
                self.isAskingAboutEncoding = false
                if !saved { undo() }
            }
        }
    }

    // MARK: Lossy file (P26, Document.m:950-960, :1084-1118)

    private var isAskingAboutLossyFile = false

    /// The first edit of a lossily loaded file: Duplicate copies it (with the
    /// edit) and takes the edit back here; Cancel takes the edit back;
    /// Overwrite lets saves write over the file.
    private func confirmEditingLossyFile() {
        guard loadedLossily, fileURL != nil, !isAskingAboutLossyFile else { return }
        isAskingAboutLossyFile = true
        alertPresenter.askBeforeOverwritingLossyFile(self) { choice in
            self.isAskingAboutLossyFile = false
            switch choice {
            case .overwrite:
                self.loadedLossily = false
            case .duplicate:
                do { _ = try self.duplicate() } catch { self.presentError(error) }
                self.undoManager?.undo()
            case .cancel:
                self.undoManager?.undo()
            }
        }
    }

    /// A save over the lossily loaded file itself: the same question.
    private func askBeforeOverwritingLossyFile(_ completion: @escaping (Bool) -> Void) {
        guard !isAskingAboutLossyFile else { return completion(false) }
        isAskingAboutLossyFile = true
        alertPresenter.askBeforeOverwritingLossyFile(self) { choice in
            self.isAskingAboutLossyFile = false
            switch choice {
            case .overwrite:
                self.loadedLossily = false
                completion(true)
            case .duplicate:
                do { _ = try self.duplicate() } catch { self.presentError(error) }
                completion(false)
            case .cancel:
                completion(false)
            }
        }
    }

    // MARK: Prevent Editing

    @objc func toggleReadOnly(_ sender: Any?) {
        preventsEditing.toggle()
        for controller in windowControllers {
            (controller as? DocumentWindowController)?.updateEditable()
        }
    }

    // MARK: Wrap to Page

    @objc func togglePageBreaks(_ sender: Any?) {
        hasMultiplePages.toggle()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(printToPDF(_:)) || menuItem.action == #selector(saveToPDF(_:)) {
            return !isPDFPanelOpen && pdfJob == nil
        }
        if menuItem.action == #selector(toggleReadOnly(_:)) {
            menuItem.title = preventsEditing ? "Allow Editing" : "Prevent Editing"
            return true
        }
        if menuItem.action == #selector(togglePageBreaks(_:)) {
            menuItem.title = hasMultiplePages ? "Wrap to Window" : "Wrap to Page"
            return true
        }
        return super.validateMenuItem(menuItem)
    }
}

// MARK: PDF output (M7, user decision U1: no real printing)

extension TextDocument {
    /// The two TextEdit print options, chosen in the PDF Save panel.
    struct PDFOptions: Equatable, Sendable {
        var headerAndFooter: Bool
        var wrappingToFit: Bool
    }

    /// Shows the PDF Save panel and calls back with the chosen file, or nil.
    typealias PDFPanelRunner = (NSSavePanel, PrintPanelAccessoryController, @escaping (URL?) -> Void) -> Void

    /// Paper and margins for Wrap to Page and PDFs, fixed when the
    /// document was made (see `fixedPageLayout`).
    nonisolated var pageLayout: PageLayout {
        fixedPageLayout.withLock { $0 }
    }

    /// File > Print… (Cmd+P). A Save panel for a PDF, never the Print panel.
    @objc func printToPDF(_ sender: Any?) {
        runPDFSavePanel()
    }

    /// File > Export as PDF…: the same panel and the same pages as Print….
    override func saveToPDF(_ sender: Any?) {
        runPDFSavePanel()
    }

    /// A print request from outside the menus (Finder's File > Print, a
    /// script, the print Apple event): QuickEdit's PDF Save panel, never
    /// the Print panel and never NSDocument's print path (M7 review item
    /// 8). The caller hears true when a PDF was written.
    override func print(withSettings printSettings: [NSPrintInfo.AttributeKey: Any], showPrintPanel: Bool,
                        delegate: Any?, didPrint didPrintSelector: Selector?,
                        contextInfo: UnsafeMutableRawPointer?) {
        let report: (Bool) -> Void = { [weak self] didPrint in
            guard let self, let delegate = delegate as? NSObject, let didPrintSelector,
                  let method = class_getInstanceMethod(type(of: delegate), didPrintSelector) else { return }
            typealias DidPrint = @convention(c) (NSObject, Selector, NSDocument, ObjCBool, UnsafeMutableRawPointer?) -> Void
            let call = unsafeBitCast(method_getImplementation(method), to: DidPrint.self)
            call(delegate, didPrintSelector, self, ObjCBool(didPrint), contextInfo)
        }
        runPDFSavePanel(done: report)
    }

    /// NSDocument's print path asks for this. QuickEdit never prints
    /// (U1), so it refuses with an error that says so.
    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        printOperationRequests += 1
        throw CocoaError(.featureUnsupported, userInfo: [
            NSLocalizedDescriptionKey: "QuickEdit does not print.",
            NSLocalizedRecoverySuggestionErrorKey: "Use File > Print\u{2026} to save the document as a PDF.",
        ])
    }

    /// A Save panel for a .pdf file with the two print options as its
    /// accessory; on Save, writes the PDF. A failure is shown as an alert.
    /// While the panel is open, another request opens nothing (and reports
    /// false). `done` hears whether a PDF was written.
    private func runPDFSavePanel(done: ((Bool) -> Void)? = nil) {
        guard !isPDFPanelOpen, pdfJob == nil else {
            done?(false)
            return
        }
        isPDFPanelOpen = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let baseName = fileURL?.deletingPathExtension().lastPathComponent ?? displayName ?? "Untitled"
        panel.nameFieldStringValue = baseName + ".pdf"
        let accessory = PrintPanelAccessoryController(showsWrappingToFit: !hasMultiplePages)
        panel.accessoryView = accessory.view
        let finish: (URL?) -> Void = { [weak self] url in
            self?.isPDFPanelOpen = false
            guard let self, let url else {
                done?(false)
                return
            }
            if self.pdfWriter == nil, self.textStorage.length > Self.backgroundPDFThreshold {
                self.startPDFWrite(to: url, options: accessory.options) { error in
                    done?(error == nil)
                    if let error { self.presentPDFError(error) }
                }
                return
            }
            do {
                if let pdfWriter = self.pdfWriter {
                    try pdfWriter(url, accessory.options)
                } else {
                    try self.writePDF(to: url, options: accessory.options)
                }
                done?(true)
            } catch {
                done?(false)
                self.presentPDFError(error)
            }
        }
        if let pdfPanelRunner {
            pdfPanelRunner(panel, accessory, finish)
        } else if let window = windowControllers.first?.window {
            panel.beginSheetModal(for: window) { response in
                finish(response == .OK ? panel.url : nil)
            }
        } else {
            finish(panel.runModal() == .OK ? panel.url : nil)
        }
    }

    /// A failed PDF write as an alert on the window; Cancel shows nothing.
    private func presentPDFError(_ error: Error) {
        if (error as? CocoaError)?.code == .userCancelled { return }
        if let window = windowControllers.first?.window {
            presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
        } else {
            presentError(error)
        }
    }

    /// Text longer than this (UTF-16 units, about 100 KB of plain text) is
    /// written off the main thread with a progress sheet (M8 n6). Shorter
    /// text is written on the main thread at once, as in M7: it takes
    /// about 50 ms, less than a sheet would be shown for.
    nonisolated static let backgroundPDFThreshold = 100_000

    /// Stops a PDF still being written when the document closes.
    override func close() {
        pdfJob?.cancel()
        super.close()
    }

    /// Writes the PDF with QuickEdit's own drawing (`PDFRenderer`), never
    /// the print system, on the main thread (the M7 path, used for short
    /// text and by tests). See `writePDFFile` for how the file is written.
    func writePDF(to url: URL, options: PDFOptions) throws {
        let source = try pdfSource(options: options, copiesText: false, laysOutScreenPages: true)
        try Self.writePDFFile(to: url) { temporary in try Self.renderPDF(source, to: temporary, job: nil) }
    }

    /// Writes the PDF on a background thread from a copy of the text, so
    /// the window stays responsive and the user can go on typing (M8 n6).
    /// First the text's attributes are read through on the main thread in
    /// short slices (`prepareTextForCopy`), so the copy itself is quick.
    /// A progress sheet with Cancel shows when the write takes longer than
    /// `PDFProgressSheet.delay`. `completion` runs on the main thread with
    /// nil, the error, or `CocoaError(.userCancelled)` after Cancel (or a
    /// close); a cancelled or failed write leaves no file and no folder,
    /// and an old file at `url` as it was.
    func startPDFWrite(to url: URL, options: PDFOptions, completion: @escaping (Error?) -> Void) {
        let job = PDFJob()
        pdfJob = job
        let name = fileURL?.deletingPathExtension().lastPathComponent ?? displayName ?? "Untitled"
        let sheet = PDFProgressSheet(job: job, title: "Exporting \u{201C}\(name)\u{201D} as PDF\u{2026}")
        sheet.schedule(on: windowControllers.first?.window)
        let end: (Error?) -> Void = { [weak self] error in
            if let self, self.pdfJob === job { self.pdfJob = nil }
            sheet.finish()
            completion(error)
        }
        prepareTextForCopy(job: job) { [weak self] in
            guard let self else { return end(CocoaError(.userCancelled)) }
            if job.isCancelled { return end(CocoaError(.userCancelled)) }
            let source: PDFSource
            do {
                source = try self.pdfSource(options: options, copiesText: true, laysOutScreenPages: false)
            } catch {
                return end(error)
            }
            nonisolated(unsafe) let finish = end
            DispatchQueue.global(qos: .userInitiated).async {
                var failure: Error?
                do {
                    try Self.writePDFFile(to: url, job: job) { temporary in try Self.renderPDF(source, to: temporary, job: job) }
                } catch {
                    failure = error
                }
                nonisolated(unsafe) let result = failure
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { finish(result) }
                }
            }
        }
    }

    /// The first pass over a freshly read text's attributes is slow:
    /// AppKit merges its attribute runs as it goes (10 MB: about 160 ms
    /// the first time, 0.01 ms after; measured 2026-10-24). Any whole copy
    /// of the text pays that, so it is paid here first, in slices of about
    /// 8 ms between run-loop turns (in every run-loop mode, so a progress
    /// sheet or a scroller drag does not stop it). Then calls `then`, also
    /// when the job was cancelled meanwhile (it checks).
    private func prepareTextForCopy(job: PDFJob, then: @escaping () -> Void) {
        AttributePass(storage: textStorage, job: job, then: then).step()
    }

    /// Draws into a new private folder on the target's volume, then moves
    /// the file to `url` in one step, so a failed or cancelled write leaves
    /// any old file as it was, and replacing a file on another disk works
    /// (M7 review item 1). Before the move, the file must be a whole PDF
    /// with every page drawn (`checkPDF`), so a partial PDF never replaces
    /// a good one (M7 re-review item 1). Throws when no whole PDF was
    /// written or the move fails; the folder is always removed. Any thread.
    /// With a `job`, Cancel is checked once more right before the move, so
    /// a Cancel or close after the last page never replaces the old file
    /// (M8 review row 6); it throws `CocoaError(.userCancelled)`.
    nonisolated static func writePDFFile(to url: URL, job: PDFJob? = nil, draw: (URL) throws -> Int) throws {
        let files = FileManager.default
        let folder = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                   appropriateFor: url.deletingLastPathComponent(), create: true)
        #if DEBUG
        testHooks.withLock { $0.pdfTemporaryFolder }?(folder)
        #endif
        defer {
            do {
                try files.removeItem(at: folder)
            } catch {
                FileHandle.standardError.write(Data("QuickEdit: could not remove \(folder.path): \(error)\n".utf8))
            }
        }
        let temporary = folder.appendingPathComponent(url.lastPathComponent)
        let pages = try draw(temporary)
        #if DEBUG
        testHooks.withLock { $0.pdfTemporaryFile }?(temporary)
        #endif
        guard checkPDF(at: temporary, pages: pages) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSURLErrorKey: url,
                NSLocalizedDescriptionKey: "The PDF \u{201C}\(url.lastPathComponent)\u{201D} could not be written.",
                NSLocalizedRecoverySuggestionErrorKey: "QuickEdit stopped before the PDF was finished.",
            ])
        }
        try job?.checkCancelled()
        if files.fileExists(atPath: url.path) {
            // The Save panel asked already; replace in one step.
            _ = try files.replaceItemAt(url, withItemAt: temporary)
        } else {
            try files.moveItem(at: temporary, to: url)
        }
    }

    /// True when `url` is a whole PDF with `pages` pages: it ends with the
    /// end-of-file marker Core Graphics writes last, Core Graphics opens
    /// it, and it has that many pages. Uses CGPDFDocument, not PDFKit, so
    /// the app does not link one more framework at launch.
    nonisolated static func checkPDF(at url: URL, pages: Int) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty,
              data.suffix(1024).range(of: Data("%%EOF".utf8)) != nil,
              let pdf = CGPDFDocument(url as CFURL) else { return false }
        return pdf.numberOfPages == pages
    }

    /// What a PDF needs from the document and its window, read on the
    /// main thread. The text is the live storage on the main-thread path,
    /// or a copy for a background write.
    struct PDFSource: @unchecked Sendable {
        let text: NSAttributedString
        let width: CGFloat
        let layout: PageLayout
        let origin: NSPoint
        let scalesToFit: Bool
        let header: PDFRenderer.Header?
    }

    /// Lays out the pages and draws them to `url` (Document.m:633-677) on
    /// the main thread. Returns the pages drawn.
    @discardableResult
    func drawPDF(to url: URL, options: PDFOptions) throws -> Int {
        try Self.renderPDF(pdfSource(options: options, copiesText: false, laysOutScreenPages: true), to: url, job: nil)
    }

    /// Lays out the pages from the source's text with its own layout
    /// manager, so the document's text never gets a second one, and draws
    /// them to `url`. Any thread, when the source's text is a copy.
    nonisolated static func renderPDF(_ source: PDFSource, to url: URL, job: PDFJob?) throws -> Int {
        let pagination = try PDFRenderer.Pagination(text: source.text, width: source.width, layout: source.layout,
                                                    origin: source.origin, scalesToFit: source.scalesToFit, job: job)
        return try PDFRenderer.write(pagination, layout: source.layout, header: source.header, to: url, job: job)
    }

    /// The source for a PDF of this document. `laysOutScreenPages`: in
    /// Wrap to Page, lay out every page on screen first, as printing did
    /// (Document.m:643-645); the background write leaves that to the
    /// window's idle layout instead.
    func pdfSource(options: PDFOptions, copiesText: Bool, laysOutScreenPages: Bool) throws -> PDFSource {
        if windowControllers.isEmpty { makeWindowControllers() }
        guard let controller = windowControllers.first as? DocumentWindowController else {
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedDescriptionKey: "This document has no window to print from.",
            ])
        }
        let layout = pageLayout
        // TextEdit's job title: the window's view's printJobTitle (Document.m:662).
        let title = controller.scrollView.documentView?.printJobTitle ?? displayName ?? "Untitled"
        let header = options.headerAndFooter ? PDFRenderer.Header(title: title, date: PDFRenderer.Header.dateText(for: Date())) : nil
        let text: NSAttributedString = copiesText ? NSAttributedString(attributedString: textStorage) : textStorage
        if hasMultiplePages, let pagesView = controller.pagesView {
            // The pages shown on screen: the page's text width at full
            // size, the text where the page's text view puts it.
            if laysOutScreenPages { controller.layOutWholeText() }
            let paper = pagesView.pageRect(forPage: 0)
            let area = pagesView.documentRect(forPage: 0)
            return PDFSource(text: text, width: layout.documentSizeInPage.width, layout: layout,
                             origin: NSPoint(x: area.minX - paper.minX, y: area.minY - paper.minY),
                             scalesToFit: false, header: header)
        }
        // The page's text width (Rewrap on) or the window's (off),
        // scaled to fit; the container starts at the margins.
        let width = options.wrappingToFit ? layout.documentSizeInPage.width : controller.textView.frame.width
        return PDFSource(text: text, width: width, layout: layout,
                         origin: NSPoint(x: layout.leftMargin, y: layout.topMargin), scalesToFit: true, header: header)
    }
}

// MARK: Alerts

enum LossyOverwriteChoice: Sendable {
    case duplicate, cancel, overwrite
}

/// Shows the document's questions. The real one uses sheets; tests use a fake.
@MainActor
protocol DocumentAlertPresenter: AnyObject {
    /// "This document can no longer be saved using its original … encoding."
    /// Calls back true for OK, false for Cancel.
    func askToChooseAnotherEncoding(_ document: TextDocument, encodingName: String,
                                    completion: @escaping (Bool) -> Void)
    /// The Save panel for a Save operation; calls back true when it saved.
    func runSavePanel(_ document: TextDocument, completion: @escaping (Bool) -> Void)
    /// "Are you sure you want to modify the document in place?"
    func askBeforeOverwritingLossyFile(_ document: TextDocument,
                                       completion: @escaping (LossyOverwriteChoice) -> Void)
    /// The file changed on disk and could not be read again.
    func presentReloadError(_ document: TextDocument, error: Error)
}

/// TextEdit's texts (Document.m:950-974), shown as sheets on the document window.
@MainActor
final class SheetAlertPresenter: DocumentAlertPresenter {
    static func encodingAlert(encodingName: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "This document can no longer be saved using its original \(encodingName) encoding."
        alert.informativeText = "Please choose another encoding (such as UTF-8)."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    static func lossyAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to modify the document in place?"
        alert.informativeText = "Modifying the document in place might cause you to lose some of the original formatting.  Would you like to duplicate the document first?"
        alert.addButton(withTitle: "Duplicate")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Overwrite")
        return alert
    }

    private func show(_ alert: NSAlert, for document: TextDocument, _ completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = document.windowForSheet {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    func askToChooseAnotherEncoding(_ document: TextDocument, encodingName: String,
                                    completion: @escaping (Bool) -> Void) {
        show(Self.encodingAlert(encodingName: encodingName), for: document) { completion($0 == .alertFirstButtonReturn) }
    }

    func presentReloadError(_ document: TextDocument, error: Error) {
        if let window = document.windowForSheet {
            document.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
        } else {
            document.presentError(error)
        }
    }

    func runSavePanel(_ document: TextDocument, completion: @escaping (Bool) -> Void) {
        let callback = SavePanelCallback(completion)
        document.runModalSavePanel(for: .saveOperation, delegate: callback,
                                   didSave: #selector(SavePanelCallback.document(_:didSave:contextInfo:)),
                                   contextInfo: nil)
    }

    func askBeforeOverwritingLossyFile(_ document: TextDocument,
                                       completion: @escaping (LossyOverwriteChoice) -> Void) {
        show(Self.lossyAlert(), for: document) { response in
            switch response {
            case .alertFirstButtonReturn: completion(.duplicate)
            case .alertThirdButtonReturn: completion(.overwrite)
            default: completion(.cancel)
            }
        }
    }
}

/// Turns NSDocument's didSave selector into a closure. It keeps itself alive
/// until AppKit calls it back once.
@MainActor
private final class SavePanelCallback: NSObject {
    private var completion: ((Bool) -> Void)?
    private var keepAlive: SavePanelCallback?

    init(_ completion: @escaping (Bool) -> Void) {
        self.completion = completion
        super.init()
        keepAlive = self
    }

    @objc func document(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        completion?(didSave)
        completion = nil
        keepAlive = nil
    }
}


/// The Save panel's encoding choice as a small state machine (M3+M5 review
/// row 9). A session opens when the panel opens and ends when AppKit reports
/// the panel's outcome. Within it, the one Save or Save As to the panel's URL
/// (AppKit's save after OK) takes the choice; autosaves neither take nor
/// clear it. Outside a session nothing is returned.
struct SavePanelSession {
    private(set) var isOpen = false
    private var encoding: String.Encoding?
    private var used = false

    mutating func begin() {
        isOpen = true
        encoding = nil
        used = false
    }

    mutating func end() {
        isOpen = false
        encoding = nil
    }

    mutating func choose(_ encoding: String.Encoding) {
        guard isOpen else { return }
        self.encoding = encoding
    }

    mutating func encodingForSave(_ operation: NSDocument.SaveOperationType, to url: URL,
                                  panelURL: URL?) -> String.Encoding? {
        guard isOpen, !used, operation == .saveOperation || operation == .saveAsOperation,
              let panelURL, panelURL.standardizedFileURL == url.standardizedFileURL else { return nil }
        used = true
        return encoding
    }
}

/// Reads a text storage's attributes from start to end in slices of about
/// 8 ms, one per run-loop turn (`TextDocument.prepareTextForCopy`). Keeps
/// itself alive through its timer until it calls `then`.
@MainActor
private final class AttributePass {
    private let storage: NSTextStorage
    private let job: PDFJob
    private let then: () -> Void
    private var index = 0

    init(storage: NSTextStorage, job: PDFJob, then: @escaping () -> Void) {
        self.storage = storage
        self.job = job
        self.then = then
    }

    func step() {
        let deadline = DispatchTime.now().uptimeNanoseconds + 8_000_000
        while index < storage.length, DispatchTime.now().uptimeNanoseconds < deadline, !job.isCancelled {
            var run = NSRange()
            _ = storage.attributes(at: index, effectiveRange: &run)
            index = max(NSMaxRange(run), index + 1)
        }
        guard index < storage.length, !job.isCancelled else { return then() }
        let timer = Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { self.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
