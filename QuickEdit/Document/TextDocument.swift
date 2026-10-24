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

    private struct State {
        var format = DecodedText.Format.newDocument
        /// The text as it was when the current save started, taken on the main thread.
        var saveSnapshot: String?
    }
    private nonisolated let state = Mutex(State())

    /// AppKit makes documents on a background thread when
    /// `canConcurrentlyReadDocuments` is true, so this init must not carry the
    /// main-actor check Swift would add by default (it crashed the app).
    override nonisolated init() {
        super.init()
    }

    override nonisolated class var autosavesInPlace: Bool { true }

    override nonisolated class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    // MARK: Reading

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
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
        // Detach layout managers (only present on revert) so the storage is
        // filled with no layout work, then put them back.
        let layoutManagers = textStorage.layoutManagers
        for manager in layoutManagers { textStorage.removeLayoutManager(manager) }
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length),
                                      with: NSAttributedString(string: decoded.text, attributes: attributes))
        textStorage.endEditing()
        for manager in layoutManagers { textStorage.addLayoutManager(manager) }
        format = decoded.format
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
        let snapshot = String(textStorage.string) // an immutable copy, not the live NSString
        state.withLock { $0.saveSnapshot = snapshot }
        super.save(to: url, ofType: typeName, for: saveOperation) { error in
            self.state.withLock { $0.saveSnapshot = nil }
            completionHandler(error)
        }
    }

    /// Runs on a background thread for async saves. Takes the snapshot made in
    /// `save(to:...)`, lets the user type again, then encodes and writes.
    override nonisolated func write(to url: URL, ofType typeName: String) throws {
        let text: String
        if let snapshot = state.withLock({ $0.saveSnapshot }) {
            text = snapshot
        } else {
            // Paths that skip save(to:...) (such as a direct write in tests).
            // AppKit blocks user interaction until unblockUserInteraction(), so
            // the storage cannot change while it is copied.
            text = String(textStorage.string)
        }
        unblockUserInteraction()
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
        return true
    }

    @objc private func appendPlainTextExtensionChanged(_ sender: NSButton) {
        guard let savePanel else { return }
        applyExtensionChoice(sender.state == .on, to: savePanel)
    }

    private func applyExtensionChoice(_ addsExtension: Bool, to savePanel: NSSavePanel) {
        if addsExtension {
            savePanel.allowedContentTypes = [.plainText]
            savePanel.allowsOtherFileTypes = true
        } else {
            savePanel.allowedContentTypes = []
            savePanel.allowsOtherFileTypes = true
            // With no allowed types the panel adds no extension; show the bare name.
            let name = fileURL?.lastPathComponent ?? displayName ?? ""
            savePanel.nameFieldStringValue = name
        }
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
