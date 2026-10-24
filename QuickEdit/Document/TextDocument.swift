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

    /// Shows the encoding and lossy-file alerts; tests put a fake here.
    lazy var alertPresenter: DocumentAlertPresenter = SheetAlertPresenter()

    private struct State {
        var format = DecodedText.Format.newDocument
        var loadedLossily = false
        /// The encoding chosen in the Open panel for this file, used again
        /// by a revert until a save records the encoding in the xattr.
        var openPanelEncoding: String.Encoding?
        /// The Save panel's encoding while that panel is up or saving.
        var savePanelEncoding: String.Encoding?
        /// The format the running save writes, when the Save panel chose a
        /// new encoding; nil means the document's own format.
        var pendingWriteFormat: DecodedText.Format?
    }
    private nonisolated let state = Mutex(State())

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

    /// The `PlainTextEncoding` default: nil means Automatic.
    nonisolated static func defaultOpenEncoding() -> String.Encoding? {
        let raw = (UserDefaults.standard.object(forKey: DefaultsKey.plainTextEncoding.rawValue) as? NSNumber)?.intValue
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
        let data = try Data(contentsOf: url)
        let preferred: String.Encoding?
        switch DocumentController.takeOpenPanelEncoding(for: url) {
        case .some(.some(let chosen)):
            preferred = chosen
            state.withLock { $0.openPanelEncoding = chosen }
        case .some(.none): // Automatic chosen in the Open panel
            preferred = nil
            state.withLock { $0.openPanelEncoding = nil }
        case .none:
            preferred = state.withLock { $0.openPanelEncoding } ?? Self.defaultOpenEncoding()
        }
        try load(decode(data, url: url, preferred: preferred))
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
        let preferred = state.withLock { $0.openPanelEncoding } ?? Self.defaultOpenEncoding()
        let decoded: DecodedText
        do {
            decoded = try decode(data, url: url, preferred: preferred)
        } catch {
            undecodableOnDisk = data
            fileModificationDate = onDisk
            alertPresenter.presentReloadError(self, error: error)
            return
        }
        undecodableOnDisk = nil
        fileModificationDate = onDisk
        guard decoded.text != textStorage.string else {
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
        // The Save panel's encoding applies to the save that panel started
        // (Document.m:1187-1193); a later Cmd+S or autosave never sees it.
        let fromPanel = (saveOperation == .saveOperation || saveOperation == .saveAsOperation)
            && savePanel != nil && savePanel?.url?.standardizedFileURL == url.standardizedFileURL
        savePanel = nil
        let panelEncoding = state.withLock { state -> String.Encoding? in
            defer { state.savePanelEncoding = nil }
            return fromPanel ? state.savePanelEncoding : nil
        }
        let written = panelEncoding.map { PlainTextIO.format(format, changedTo: $0) }
        state.withLock { $0.pendingWriteFormat = written }

        let overwritesLossyFile = loadedLossily && url.standardizedFileURL == fileURL?.standardizedFileURL
            && (saveOperation == .saveOperation || saveOperation == .autosaveInPlaceOperation)
        let save = {
            super.save(to: url, ofType: typeName, for: saveOperation) { error in
                if error == nil, let written {
                    // After a good Save or Save As the chosen encoding becomes
                    // the document's (Document.m:1232-1234); the xattr now
                    // records it, so a revert no longer needs the Open panel's.
                    self.state.withLock {
                        $0.format = written
                        $0.openPanelEncoding = nil
                    }
                }
                self.state.withLock { $0.pendingWriteFormat = nil }
                completionHandler(error)
            }
        }
        guard overwritesLossyFile else { return save() }
        askBeforeOverwritingLossyFile { overwrite in
            if overwrite { save() } else {
                self.state.withLock { $0.pendingWriteFormat = nil }
                completionHandler(CocoaError(.userCancelled))
            }
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
        try PlainTextIO.writeAttribute(for: format.encoding, to: url)
    }

    override func data(ofType typeName: String) throws -> Data {
        try PlainTextIO.encode(String(textStorage.string), as: format)
    }

    // MARK: Save panel

    override var shouldRunSavePanelWithAccessoryView: Bool { false }

    private var savePanel: NSSavePanel?

    /// The encoding a new save suggests: `PlainTextEncodingForWrite` when it
    /// is set and holds the text, else UTF-8 (Document.m:368-379).
    func suggestedSaveEncoding() -> String.Encoding {
        let raw = (UserDefaults.standard.object(forKey: DefaultsKey.plainTextEncodingForWrite.rawValue) as? NSNumber)?.intValue
            ?? Defaults.noStringEncoding
        if raw != Defaults.noStringEncoding {
            let chosen = String.Encoding(rawValue: UInt(raw))
            if chosen != .utf16, chosen != .utf8, textStorage.string.canBeConverted(to: chosen) { return chosen }
        }
        return .utf8
    }

    /// The Save panel's start encoding: the document's if the text still
    /// fits it, else the suggested one (Document.m:1276-1277).
    func initialSaveEncoding() -> String.Encoding {
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
        state.withLock { $0.savePanelEncoding = encoding }

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
        state.withLock { $0.savePanelEncoding = encoding }
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
