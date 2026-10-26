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
        /// The bytes the text was decoded from, for a file over
        /// `largeFileThreshold` (M8 review rows 14, 28 and 33): an APFS
        /// clone taken before the read, never the file's mapping. A reload
        /// compares the file's new clone with it; a file too large to edit
        /// saves a copy from it.
        var original: LargeFileOriginal?
        /// The clone a running save took of the file it wrote, inside its
        /// file access (M8 review row 41); adopted when the save succeeds.
        var savedClone: LargeFileOriginal?
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
        /// Runs on the background thread of a large-file reload, while the
        /// windows are detached, before the new text is filled in.
        var beforeReloadFill: (@Sendable () -> Void)?
        /// Runs in `read(from:ofType:)` with the file's URL, right after
        /// the storage is filled, so a test can change the file then.
        var afterReadFill: (@Sendable (URL) -> Void)?
        /// Runs on the background thread of a large-file reload before the
        /// new clone is compared and decoded (the check part).
        var beforeReloadCheck: (@Sendable () -> Void)?
        /// Runs on the main thread when a save of the document's own file
        /// has ended, before its completion handler (M8 review row 41).
        var afterSaveEnded: (@Sendable (URL) -> Void)?
    }
    nonisolated static let testHooks = Mutex(TestHooks())
    /// Tests: `showWindows()` shows nothing, so a document that AppKit
    /// displays (Duplicate) never puts a window in front.
    nonisolated(unsafe) static var hidesWindowsForTests = false
    #endif

    override func showWindows() {
        #if DEBUG
        if Self.hidesWindowsForTests { return }
        #endif
        super.showWindows()
    }

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

    /// Files bigger than this many bytes open read-only (M8, vote V3
    /// result B): editing, undo and saving would each need about one more
    /// copy of the text, which an 8 GiB Mac cannot spare at 1 GB. 512 MiB
    /// is the vote's starting point; `LargeFileSpeedTests.testOpenSizes`
    /// measures opens and saves at other sizes and limits.
    nonisolated static let defaultReadOnlyThreshold = 512 * 1024 * 1024
    /// The limit in use; tests change it.
    nonisolated(unsafe) static var readOnlyThreshold = defaultReadOnlyThreshold

    /// The file is over `readOnlyThreshold`: view, find, select, copy,
    /// Select Line, Save As (the original bytes) and Export as PDF work;
    /// nothing edits the text, and nothing writes over the file.
    var isTooLargeToEdit: Bool {
        state.withLock { $0.readByteCount } > Self.readOnlyThreshold
    }

    /// Bytes of the file as last read; 0 for a new document.
    var readByteCount: Int { state.withLock { $0.readByteCount } }

    /// The clone the text was decoded from (tests read it).
    var keptOriginal: LargeFileOriginal? { state.withLock { $0.original } }

    /// A file too large to edit whose disk could not clone it: no Save
    /// As, Save To or Duplicate, and the title says so (M8 review row 29).
    var cannotSaveACopy: Bool {
        state.withLock { $0.readByteCount > Self.readOnlyThreshold && $0.original == nil }
    }

    /// Records what a successful read found: its size and the clone it
    /// was decoded from (nil below `largeFileThreshold`, or when the disk
    /// cannot clone). Called only after the decode worked, so a rejected
    /// file changes nothing (M8 review row 15).
    private nonisolated func recordRead(byteCount: Int, original: LargeFileOriginal?) {
        let old = state.withLock { state -> LargeFileOriginal? in
            state.readByteCount = byteCount
            defer { state.original = original }
            return state.original
        }
        if let old, old !== original { old.removeFolder() }
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
        switch DocumentController.takeOpenPanelEncoding(for: url) {
        case .some(.some(let chosen)): state.withLock { $0.openChoice = .encoding(chosen) }
        case .some(.none): state.withLock { $0.openChoice = .automatic }
        case .none: break // not from the Open panel: keep this document's choice
        }
        // A large file is cloned first, and the text comes from the clone
        // (M8 review row 28): the window, Save As and a later reload's
        // check then see the same bytes, whatever the file does meanwhile.
        var clone = Self.fileSize(url) > Self.largeFileThreshold ? LargeFileOriginal.clone(url) : nil
        // Mapped, not copied (M8 n2): the decode reads the pages straight
        // from the file cache, so a 100 MB file does not first take
        // 100 MB of memory as a copy of its bytes.
        var data = try Data(contentsOf: clone?.file ?? url, options: .mappedIfSafe)
        if clone == nil, data.count > Self.largeFileThreshold {
            // It grew past the limit after the size check: clone it now.
            clone = LargeFileOriginal.clone(url)
            if let clone { data = try Data(contentsOf: clone.file, options: .mappedIfSafe) }
        }
        // UTF-8 stays as the mapped bytes until the storage copies it (M8, V3).
        let content = try decodeContent(data, url: url, attributesOf: clone?.file, preferred: preferredEncoding())
        Signposts.mark(.decodeEnd)
        load(content)
        #if DEBUG
        Self.testHooks.withLock { $0.afterReadFill }?(url)
        #endif
        // The mapping ends here: the storage has the text.
        recordRead(byteCount: data.count, original: clone)
    }

    /// The file's size from its metadata; 0 when it cannot be read (the
    /// read then reports the error).
    private nonisolated static func fileSize(_ url: URL) -> Int {
        var info = stat()
        return stat(url.path, &info) == 0 ? Int(info.st_size) : 0
    }

    /// Bytes with no file (M8 review row 16): the same limit; above the
    /// read-only limit the bytes go to a file in the clone folder, for
    /// Save As.
    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        try load(decodeContent(data, url: nil, preferred: Self.defaultOpenEncoding()))
        let kept = data.count > Self.readOnlyThreshold ? try LargeFileOriginal.keep(data, name: "Untitled.txt") : nil
        recordRead(byteCount: data.count, original: kept)
    }

    /// PlainTextIO.decode with AppKit's fallback encoding, as an NSError
    /// AppKit can show ("…couldn't be opened using text encoding X.").
    nonisolated func decode(_ data: Data, url: URL?, preferred: String.Encoding?) throws -> DecodedText {
        try decodeContent(data, url: url, preferred: preferred).decodedText
    }

    /// `decode`, with UTF-8 kept as bytes (`PlainTextIO.decodeInPlace`).
    /// `attributesOf`: the file whose encoding tag counts (a clone of
    /// `url`); `url` itself when nil. Errors name `url`.
    nonisolated func decodeContent(_ data: Data, url: URL?, attributesOf tagged: URL? = nil,
                                   preferred: String.Encoding?) throws -> DecodedContent {
        var fallback = String.defaultCStringEncoding
        #if DEBUG
        if let hook = Self.testHooks.withLock({ $0.fallbackEncoding }) { fallback = hook }
        #endif
        do {
            return try PlainTextIO.decodeInPlace(data, url: tagged ?? url, preferred: preferred, fallback: fallback)
        } catch PlainTextIO.Error.inapplicableEncoding(let encoding) {
            var info: [String: Any] = [NSStringEncodingErrorKey: encoding.rawValue]
            if let url { info[NSURLErrorKey] = url }
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: info)
        }
    }

    /// Puts decoded text into the storage.
    private nonisolated func load(_ decoded: DecodedText) {
        load(DecodedContent(decoded))
    }

    /// Puts decoded text into the storage: a String in one piece, UTF-8
    /// bytes in pieces, so the bytes are never a whole String (M8, V3).
    private nonisolated func load(_ decoded: DecodedContent) {
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
        switch decoded.body {
        case .text(let text):
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length),
                                          with: NSAttributedString(string: text, attributes: attributes))
            textStorage.endEditing()
        case .utf8(let bytes):
            LargeFileText.fill(textStorage, withUTF8: bytes, attributes: attributes)
        }
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
    /// The same for a large file: the clone of the bytes that failed.
    private var undecodableClone: LargeFileOriginal?

    /// One reload, from the request to its end. Close cancels it (M8
    /// review row 31): it then changes nothing and its clone goes.
    final class ReloadJob: @unchecked Sendable {
        private let cancelled = Atomic<Bool>(false)
        var isCancelled: Bool { cancelled.load(ordering: .relaxed) }
        func cancel() { cancelled.store(true, ordering: .relaxed) }
    }
    private var reloadJob: ReloadJob?

    /// A reload asked for has not ended yet: AppKit may run the file access
    /// later, and a large file is checked and filled in the background (M8
    /// review row 19). Meanwhile nothing reads or writes the text: saves,
    /// Revert, Duplicate, PDF output and printing are off (row 30).
    var isReloading: Bool { reloadJob != nil }

    /// An outside change came during a reload: one more reload at its end.
    private var reloadAgain = false
    /// An outside change came while PDF output read the text: the reload
    /// runs when that ends (M8 review row 30).
    private var reloadAfterPDF = false
    /// Close ran: no more reloads (M8 review row 31).
    private var isClosed = false

    /// Reloads a document that has no unsaved edits when another app changed
    /// its file. With unsaved edits it does nothing: NSDocument shows its own
    /// "changed by another application" sheet on the next save.
    /// It replaces the text only when the file's bytes or encoding tag
    /// changed, keeping each window's selection (clamped) and scroll place;
    /// a date-only change keeps the text, the caret and undo.
    /// It holds NSDocument's file access only while it reads a small file
    /// or clones a large one, so no save overlaps that step; then it ends
    /// the access, and a large file is checked and filled afterwards (M8
    /// review row 27: holding the access across background work that ends
    /// on the main thread hung Close, Quit and Duplicate). (The asynchronous
    /// form: AppKit keeps the synchronous form's block after it returns,
    /// which Swift stops as an escaped non-escaping closure. With no other
    /// file access running, AppKit runs this block at once.)
    func reloadAfterOutsideChange() {
        guard !isClosed, !isDocumentEdited, fileURL != nil else { return }
        if isReloading {
            reloadAgain = true
            return
        }
        if isPDFPanelOpen || pdfJob != nil {
            reloadAfterPDF = true
            return
        }
        let job = ReloadJob()
        reloadJob = job
        // From now on the views take no edits (M8 review row 40): an edit
        // typed during the check would be lost or overwritten.
        updateEditableWindows()
        performAsynchronousFileAccess { endAccess in
            MainActor.assumeIsolated {
                self.reloadFromDisk(job, endAccess: endAccess)
            }
        }
    }

    /// The end of a reload, whatever its outcome.
    private func reloadEnded(_ job: ReloadJob) {
        if reloadJob === job { reloadJob = nil }
        updateEditableWindows()
        guard !job.isCancelled, !isClosed else { return }
        if reloadAgain {
            reloadAgain = false
            reloadAfterOutsideChange()
        }
    }

    private func updateEditableWindows() {
        for controller in windowControllers {
            (controller as? DocumentWindowController)?.updateEditable()
        }
    }

    /// PDF output ended: a reload that waited for it runs now.
    private func pdfOutputEnded() {
        guard reloadAfterPDF, !isPDFPanelOpen, pdfJob == nil else { return }
        reloadAfterPDF = false
        reloadAfterOutsideChange()
    }

    /// Runs inside the file access. `endAccess` ends it.
    private func reloadFromDisk(_ job: ReloadJob, endAccess: @escaping () -> Void) {
        guard !job.isCancelled, !isDocumentEdited, let url = fileURL else {
            endAccess()
            return reloadEnded(job)
        }
        let onDisk: Date?
        let size: Int
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            onDisk = attributes[.modificationDate] as? Date
            size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            // The file was moved or deleted; NSDocument tracks moves itself.
            FileHandle.standardError.write(Data("QuickEdit: cannot read \(url.path) after an outside change: \(error)\n".utf8))
            endAccess()
            return reloadEnded(job)
        }
        if size > Self.largeFileThreshold || isLargeFile {
            // The clone is the only step that needs the file access (a few
            // milliseconds, as it shares the file's blocks).
            let clone = LargeFileOriginal.clone(url)
            endAccess()
            return reloadLargeFile(url, clone: clone, onDisk: onDisk, job: job)
        }
        defer {
            endAccess()
            reloadEnded(job)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
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
        undecodableClone = nil
        fileModificationDate = onDisk
        // The new bytes decide large-file mode (M8 review row 2) and
        // read-only mode (V3).
        recordRead(byteCount: data.count, original: nil)
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

    /// Reload of a large file (M8 review rows 19, 28, 32, 33), within
    /// done-test 4, after the file access ended. On a background thread:
    /// the new clone is compared with the clone the text came from, bytes
    /// and encoding tag; the same means the text, undo and format stay.
    /// Otherwise the clone is decoded (in place, as on open), and the
    /// main thread only detaches and attaches the windows around the fill.
    /// A disk that cannot clone gives no clone: the file itself is read,
    /// and it always counts as changed.
    private func reloadLargeFile(_ url: URL, clone: LargeFileOriginal?, onDisk: Date?, job: ReloadJob) {
        let preferred = preferredEncoding()
        let shown = state.withLock { $0.original }
        nonisolated(unsafe) let undecodable = undecodableClone
        nonisolated(unsafe) let document = self
        DispatchQueue.global(qos: .userInitiated).async {
            #if DEBUG
            Self.testHooks.withLock { $0.beforeReloadCheck }?()
            #endif
            enum Check { case cancelled, unchanged, stillUndecodable, failed(Error), changed(DecodedContent, Int) }
            let check: Check
            if job.isCancelled {
                check = .cancelled
            } else if let clone, let shown, clone.hasSameContent(as: shown) {
                check = .unchanged
            } else if let clone, let undecodable, clone.hasSameContent(as: undecodable) {
                check = .stillUndecodable
            } else {
                do {
                    let data = try Data(contentsOf: clone?.file ?? url, options: .mappedIfSafe)
                    check = .changed(try document.decodeContent(data, url: url, attributesOf: clone?.file, preferred: preferred),
                                     data.count)
                } catch {
                    check = .failed(error)
                }
            }
            nonisolated(unsafe) let result = check
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !job.isCancelled else { return document.reloadEnded(job) }
                    switch result {
                    case .cancelled:
                        document.reloadEnded(job)
                    case .unchanged, .stillUndecodable:
                        document.fileModificationDate = onDisk
                        document.reloadEnded(job)
                    case .failed(let error):
                        document.undecodableClone = clone
                        document.fileModificationDate = onDisk
                        document.alertPresenter.presentReloadError(document, error: error)
                        document.reloadEnded(job)
                    case .changed(let content, let byteCount):
                        // Typed into meanwhile: NSDocument asks on the next save.
                        guard !document.isDocumentEdited else { return document.reloadEnded(job) }
                        document.undecodableClone = nil
                        document.replaceTextInBackground(content, byteCount: byteCount, clone: clone, onDisk: onDisk, job: job)
                    }
                }
            }
        }
    }

    /// Detaches every window, fills the storage on a background thread
    /// (the mapped clone is read there, then let go), attaches the windows
    /// again and puts back each one's place. A Close meanwhile cancels the
    /// job: the fill is skipped if it has not started, and nothing is
    /// attached or recorded after it (M8 review row 31).
    private func replaceTextInBackground(_ content: DecodedContent, byteCount: Int, clone: LargeFileOriginal?,
                                         onDisk: Date?, job: ReloadJob) {
        nonisolated(unsafe) let windows = windowControllers.compactMap { $0 as? DocumentWindowController }
        nonisolated(unsafe) let places = windows.map { $0.currentPlace() }
        for window in windows { window.beginReload() }
        nonisolated(unsafe) let managers = textStorage.layoutManagers
        for manager in managers { textStorage.removeLayoutManager(manager) }
        nonisolated(unsafe) let document = self
        nonisolated(unsafe) var pending: DecodedContent? = content
        DispatchQueue.global(qos: .userInitiated).async {
            #if DEBUG
            Self.testHooks.withLock { $0.beforeReloadFill }?()
            #endif
            if !job.isCancelled, let content = pending { document.load(content) }
            pending = nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !job.isCancelled else { return document.reloadEnded(job) }
                    for manager in managers { document.textStorage.addLayoutManager(manager) }
                    document.recordRead(byteCount: byteCount, original: clone)
                    for window in windows { window.endReload() }
                    document.fileModificationDate = onDisk
                    document.undoManager?.removeAllActions()
                    document.updateChangeCount(.changeCleared)
                    document.updateLargeFileMode()
                    for (window, place) in zip(windows, places) { window.restore(place) }
                    document.reloadEnded(job)
                }
            }
        }
    }

    /// An error for an action that must wait until a reload ends.
    private func reloadingError(_ url: URL? = nil) -> CocoaError {
        var info: [String: Any] = [
            NSLocalizedDescriptionKey: "\u{201C}\(displayName ?? "The document")\u{201D} is being read again after another app changed it.",
            NSLocalizedRecoverySuggestionErrorKey: "Try again when its text is back in the window.",
        ]
        if let url { info[NSURLErrorKey] = url }
        return CocoaError(.fileWriteUnknown, userInfo: info)
    }

    /// The error when a file too large to edit has no clone (row 29).
    private func noCopyError(_ url: URL? = nil) -> CocoaError {
        var info: [String: Any] = [
            NSLocalizedDescriptionKey: "QuickEdit cannot save a copy of \u{201C}\(displayName ?? "this file")\u{201D}.",
            NSLocalizedRecoverySuggestionErrorKey: "The file is too large to edit, and its disk cannot keep a copy of it as it was read. Copy the file in the Finder instead.",
        ]
        if let url { info[NSURLErrorKey] = url }
        return CocoaError(.fileWriteUnknown, userInfo: info)
    }

    /// Revert reads the file again (`read(from:ofType:)` records its
    /// size); the windows then follow its large-file mode (M8 review row 2).
    /// Not while a reload fills the text.
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        if isReloading { throw reloadingError(url) }
        defer { updateLargeFileMode() }
        try super.revert(toContentsOf: url, ofType: typeName)
    }

    /// Duplicate writes the text (or the clone) to a new file: not while
    /// a reload fills the text (row 30), and not for a file too large to
    /// edit with no clone (row 29).
    override func duplicate() throws -> NSDocument {
        if isReloading { throw reloadingError() }
        if cannotSaveACopy { throw noCopyError() }
        return try super.duplicate()
    }

    /// Every window turns its checks, read-only state and title note on or
    /// off to match `isLargeFile` and `isTooLargeToEdit`. (No undo is
    /// cleared here: every route that makes a document read-only, revert
    /// and both reloads, replaces the text and clears undo itself; M8
    /// review row 35.)
    private func updateLargeFileMode() {
        for controller in windowControllers {
            guard let controller = controller as? DocumentWindowController else { continue }
            controller.applyLargeFileMode()
            controller.updateEditable()
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
        // A file too large to edit is never written over (M8, V3): its
        // text cannot change, so the file already holds it. Save As and
        // Save To a new file still write (the original bytes).
        if isTooLargeToEdit, saveOperation == .autosaveInPlaceOperation
            || (saveOperation == .saveOperation && url.standardizedFileURL == fileURL?.standardizedFileURL) {
            return completionHandler(nil)
        }
        // While a reload fills the text, nothing reads it (M8 review row
        // 27). A reload starts only with no unsaved edits and the views
        // take no input meanwhile, so an autosave has nothing to save.
        // An edited document is never reported saved (M8 review row 40).
        if isReloading {
            let autosaves = saveOperation == .autosaveInPlaceOperation || saveOperation == .autosaveElsewhereOperation
            return completionHandler(autosaves && !isDocumentEdited ? nil : reloadingError(url))
        }
        // No clone of a file too large to edit: no copy to write (row 29).
        if cannotSaveACopy { return completionHandler(noCopyError(url)) }
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
                #if DEBUG
                if error == nil, let own = self.fileURL { Self.testHooks.withLock { $0.afterSaveEnded }?(own) }
                #endif
                if error == nil {
                    self.cloneAgainAfterSave(saveOperation)
                } else {
                    self.state.withLock { $0.savedClone = nil }
                }
                completionHandler(error)
            }
        }
        guard overwritesLossyFile else { return save() }
        askBeforeOverwritingLossyFile { overwrite in
            if overwrite { save() } else { completionHandler(CocoaError(.userCancelled)) }
        }
    }

    /// A large file's own file was written: the text now matches it, so
    /// the clone the write took takes the old one's place, and a later
    /// date-only change keeps the text and undo (M8 review row 33). The
    /// clone was taken inside the save's file access, right after the
    /// bytes were written, so a write by another app after the save is
    /// never in it (row 41).
    private func cloneAgainAfterSave(_ operation: NSDocument.SaveOperationType) {
        let clone = state.withLock { state -> LargeFileOriginal? in
            defer { state.savedClone = nil }
            return state.savedClone
        }
        guard Self.writesOwnFile(operation), isLargeFile, !isTooLargeToEdit else { return }
        recordRead(byteCount: readByteCount, original: clone)
    }

    /// Save, Save As and autosave in place: the document's file afterwards.
    private nonisolated static func writesOwnFile(_ operation: NSDocument.SaveOperationType) -> Bool {
        operation == .saveOperation || operation == .saveAsOperation || operation == .autosaveInPlaceOperation
    }

    /// Autosave never writes a file too large to edit (M8, V3), nor
    /// during a reload (M8 review row 27).
    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool,
                           completionHandler: @escaping (Error?) -> Void) {
        if isTooLargeToEdit { return completionHandler(nil) }
        // During a reload the views take no edits, so there is normally
        // nothing to save; an edited document gets an error, never a
        // success that wrote nothing (M8 review row 40).
        if isReloading { return completionHandler(isDocumentEdited ? reloadingError() : nil) }
        super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable, completionHandler: completionHandler)
    }

    /// Runs on a background thread for async saves.
    override nonisolated func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                                    originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        let format = state.withLock { $0.pendingWriteFormat ?? $0.format }
        if let original = try originalForCopy(url) { return try writeOriginal(original, to: url, as: format) }
        try write(to: url, as: format)
        // Still inside the save's file access (row 41): clone what was written.
        let large = state.withLock { $0.readByteCount > Self.largeFileThreshold }
        if large, Self.writesOwnFile(saveOperation) {
            let clone = LargeFileOriginal.clone(url)
            state.withLock { $0.savedClone = clone }
        }
    }

    override nonisolated func write(to url: URL, ofType typeName: String) throws {
        if let original = try originalForCopy(url) { return try writeOriginal(original, to: url, as: format) }
        try write(to: url, as: format)
    }

    /// The clone a file too large to edit is written from; nil for an
    /// editable file (its text is written). A file too large to edit with
    /// no clone throws (M8 review row 29).
    private nonisolated func originalForCopy(_ url: URL?) throws -> LargeFileOriginal? {
        let (tooLarge, original) = state.withLock { ($0.readByteCount > Self.readOnlyThreshold, $0.original) }
        guard tooLarge else { return nil }
        guard let original else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "QuickEdit cannot save a copy of this file.",
                NSLocalizedRecoverySuggestionErrorKey: "The file is too large to edit, and its disk cannot keep a copy of it as it was read.",
            ])
        }
        return original
    }

    /// A file too large to edit: Save As and Save To write the bytes that
    /// were read, so line endings, encoding and BOM stay exactly as found
    /// (M8, V3); the text is never encoded again. The xattr as on any save.
    /// Bytes that fit no encoding were read as UTF-8 with replacement
    /// characters: the copy gets no encoding tag (a UTF-8 tag would make it
    /// refuse to open), so it opens as the original does (M8 review row 17).
    private nonisolated func writeOriginal(_ original: LargeFileOriginal, to url: URL, as format: DecodedText.Format) throws {
        unblockUserInteraction()
        #if DEBUG
        Self.testHooks.withLock { $0.afterUnblock }?()
        #endif
        try original.write(to: url)
        if loadedLossily && format.encoding == .utf8 {
            removexattr(url.path, PlainTextIO.encodingAttribute, 0)
        } else {
            writeEncodingAttribute(for: format, to: url)
        }
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
        writeEncodingAttribute(for: format, to: url)
    }

    /// The xattr is best effort (M3+M5 review row 10): the bytes are
    /// saved; a file without it opens by BOM, UTF-8 or the fallback.
    private nonisolated func writeEncodingAttribute(for format: DecodedText.Format, to url: URL) {
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
        if let original = try originalForCopy(nil) { return try original.bytes() }
        return try PlainTextIO.encode(String(textStorage.string), as: format)
    }

    // MARK: Save panel

    override var shouldRunSavePanelWithAccessoryView: Bool { false }

    /// The Save panel this document showed last, and its encoding session.
    private var savePanel: NSSavePanel?
    private var panelSession = SavePanelSession()

    /// A Save panel (Save, Save As, Move To) or the PDF Save panel is open
    /// on this document's window. In the sandbox these panels run in
    /// another process, so the window's `attachedSheet` stays nil under
    /// them (measured 2026-10-26); New Tab is off while this is true (M11).
    var isShowingSavePanel: Bool { savePanel != nil || isPDFPanelOpen }

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
        // Save As of a file too large to edit keeps its bytes, so its
        // encoding (and no check of the whole text on the main thread).
        if isTooLargeToEdit { return format.encoding }
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
        if isTooLargeToEdit {
            // Saved as its own bytes (M8, V3): the pop-up is off, so no
            // check of the whole text (a full copy of it, M8 review row 25).
            popUp.isEnabled = false
        } else {
            // Also after a Customize Encodings change refills it (M3+M5 review row 6).
            popUp.refreshEnabledItems = { [weak self] popUp in
                guard let self else { return }
                Self.disableUnfitItems(in: popUp, text: self.textStorage.string)
            }
            Self.disableUnfitItems(in: popUp, text: textStorage.string)
        }
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
        // A file too large to edit stays read-only (M8, V3).
        guard !isTooLargeToEdit else { return }
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
            return !isPDFPanelOpen && pdfJob == nil && !isReloading
        }
        // While a reload fills the text, nothing reads or writes it (M8
        // review rows 27 and 30).
        let readsOrWritesText: [Selector] = [#selector(save(_:)), #selector(saveAs(_:)), #selector(saveTo(_:)),
                                             #selector(duplicate(_:)), #selector(revertToSaved(_:)),
                                             #selector(browseVersions(_:))]
        if isReloading, let action = menuItem.action, readsOrWritesText.contains(action) { return false }
        // A file too large to edit whose disk cannot clone it (row 29).
        if cannotSaveACopy, menuItem.action == #selector(saveAs(_:)) || menuItem.action == #selector(saveTo(_:))
            || menuItem.action == #selector(duplicate(_:)) {
            return false
        }
        if menuItem.action == #selector(toggleReadOnly(_:)) {
            menuItem.title = preventsEditing || isTooLargeToEdit ? "Allow Editing" : "Prevent Editing"
            return !isTooLargeToEdit
        }
        // A file too large to edit: nothing writes over it or reverts it (M8, V3).
        if isTooLargeToEdit, menuItem.action == #selector(save(_:)) || menuItem.action == #selector(revertToSaved(_:))
            || menuItem.action == #selector(browseVersions(_:)) {
            return false
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
        // Not while a reload fills the text (M8 review row 30).
        guard !isPDFPanelOpen, pdfJob == nil, !isReloading else {
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
            // A reload that waited for the panel or a main-thread write
            // runs after it; a background write calls this at its end.
            defer { self?.pdfOutputEnded() }
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
    /// Also cancels a reload (M8 review row 31): it then changes nothing,
    /// starts no other reload, and its clone goes.
    override func close() {
        isClosed = true
        reloadJob?.cancel()
        reloadAgain = false
        reloadAfterPDF = false
        pdfJob?.cancel()
        super.close()
        // The clones go with the document (M8 review row 14).
        let original = state.withLock { state -> LargeFileOriginal? in
            defer { state.original = nil }
            return state.original
        }
        original?.removeFolder()
        undecodableClone?.removeFolder()
        undecodableClone = nil
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
            self?.pdfOutputEnded()
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
