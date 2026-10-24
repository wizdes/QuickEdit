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

    /// Format > Prevent Editing. Not saved in plain files.
    private(set) var preventsEditing = false

    /// The untitled window made at launch (or by a Dock click with no
    /// windows), not yet touched. Opening a file replaces it in place
    /// (reference/apple/Document.m:525-543, DocumentController.m:153-277).
    /// Any edit, a window move or resize, or a second document clears it.
    var isTransient = false

    /// A transient document can be replaced only while no sheet is open on it.
    var isTransientAndCanBeReplaced: Bool {
        isTransient && !windowControllers.contains { $0.window?.attachedSheet != nil }
    }

    private struct State {
        var format = DecodedText.Format.newDocument
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

    /// An edit ends the transient state (Document.m:998-1004).
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        isTransient = false
        super.updateChangeCount(change)
    }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    // MARK: Reading

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        #if DEBUG
        Self.testHooks.withLock { $0.onRead }?(Thread.isMainThread)
        #endif
        let decoded: DecodedText
        do {
            decoded = try PlainTextIO.decode(data)
        } catch PlainTextIO.Error.notUTF8 {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError, userInfo: [
                NSLocalizedDescriptionKey: "The file is not valid UTF-8 text.",
                NSLocalizedRecoverySuggestionErrorKey: "QuickEdit can open only UTF-8 text files in this version.",
                NSStringEncodingErrorKey: String.Encoding.utf8.rawValue,
            ])
        }
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
        format = decoded.format
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

    /// Reloads a document that has no unsaved edits when another app changed
    /// its file. With unsaved edits it does nothing: NSDocument shows its own
    /// "changed by another application" sheet on the next save.
    func reloadAfterOutsideChange() {
        guard !isDocumentEdited, let url = fileURL, let type = fileType else { return }
        let onDisk: Date?
        do {
            onDisk = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } catch {
            // The file was moved or deleted; NSDocument tracks moves itself.
            FileHandle.standardError.write(Data("QuickEdit: cannot read \(url.path) after an outside change: \(error)\n".utf8))
            return
        }
        // Our own saves and an unchanged file need no reload.
        if let onDisk, let known = fileModificationDate, onDisk <= known { return }
        do {
            try revert(toContentsOf: url, ofType: type)
        } catch {
            presentError(error)
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
        super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
    }

    /// Runs on a background thread for async saves. AppKit blocks user
    /// interaction (the main thread waits) until `unblockUserInteraction()`,
    /// so the storage cannot change while it is copied here. Then the user
    /// can type again while the copy is encoded and written.
    override nonisolated func write(to url: URL, ofType typeName: String) throws {
        let text = String(textStorage.string) // an immutable copy, not the live NSString
        unblockUserInteraction()
        #if DEBUG
        Self.testHooks.withLock { $0.afterUnblock }?()
        #endif
        let data = try PlainTextIO.encode(text, as: format)
        try data.write(to: url, options: .atomic)
    }

    override func data(ofType typeName: String) throws -> Data {
        try PlainTextIO.encode(String(textStorage.string), as: format)
    }

    // MARK: Save panel

    override var shouldRunSavePanelWithAccessoryView: Bool { false }

    private weak var savePanel: NSSavePanel?

    /// TextEdit's ".txt" checkbox (reference/apple/Document.m:1266-1303).
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        self.savePanel = savePanel
        let checkbox = NSButton(checkboxWithTitle: "If no extension is provided, use \u{201C}.txt\u{201D}.",
                                target: self, action: #selector(appendPlainTextExtensionChanged(_:)))
        checkbox.identifier = NSUserInterfaceItemIdentifier("appendTxtExtension")
        checkbox.state = Defaults.bool(.addExtensionToNewPlainTextFiles) ? .on : .off
        checkbox.sizeToFit()
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: checkbox.frame.width + 40,
                                             height: checkbox.frame.height + 16))
        checkbox.setFrameOrigin(NSPoint(x: 20, y: 8))
        accessory.addSubview(checkbox)
        savePanel.accessoryView = accessory
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

    // MARK: Prevent Editing

    @objc func toggleReadOnly(_ sender: Any?) {
        preventsEditing.toggle()
        for controller in windowControllers {
            (controller as? DocumentWindowController)?.updateEditable()
        }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleReadOnly(_:)) {
            menuItem.title = preventsEditing ? "Allow Editing" : "Prevent Editing"
            return true
        }
        return super.validateMenuItem(menuItem)
    }
}
