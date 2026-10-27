import AppKit
import QuickLookThumbnailing
import XCTest
@testable import QuickEdit

/// M9 n2: the parts macOS gives an app (docs/parity.md P71 to P73): drag
/// and drop, Share, Writing Tools, Services, keyboard access, Quick Look.
/// Since M9 n1 the test host runs sandboxed.
@MainActor
final class SystemPartsTests: XCTestCase {
    private var folder: URL!
    private var documents: [NSDocument] = []
    private var saved: SavedSettings!
    private var savedLargeThreshold = 0
    private var savedReadOnlyThreshold = 0

    override func setUp() async throws {
        saved = SavedSettings()
        savedLargeThreshold = TextDocument.largeFileThreshold
        savedReadOnlyThreshold = TextDocument.readOnlyThreshold
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-system-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        TextDocument.largeFileThreshold = savedLargeThreshold
        TextDocument.readOnlyThreshold = savedReadOnlyThreshold
        for document in documents + NSDocumentController.shared.documents
            where document.fileURL?.path.hasPrefix(folder.path) == true || documents.contains(document) {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        saved.restore()
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    private func write(_ text: String, name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func open(_ url: URL) throws -> (TextDocument, DocumentWindowController) {
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        document.makeWindowControllers()
        documents.append(document)
        return (document, try XCTUnwrap(document.windowControllers.first as? DocumentWindowController))
    }

    private func untitled() throws -> (TextDocument, DocumentWindowController) {
        let document = try XCTUnwrap(try NSDocumentController.shared.makeUntitledDocument(
            ofType: TextDocument.plainTextType) as? TextDocument)
        document.makeWindowControllers()
        documents.append(document)
        return (document, try XCTUnwrap(document.windowControllers.first as? DocumentWindowController))
    }

    private func waitForDocument(at url: URL, timeout: TimeInterval = 10) -> NSDocument? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let document = NSDocumentController.shared.document(for: url) { return document }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    private func pasteboard(_ urls: [URL]) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.writeObjects(urls as [NSURL])
        return board
    }

    // MARK: 1. Drag and drop (P72)

    /// A file dropped on the window outside the text (the title bar) opens
    /// it; a folder or a picture is refused.
    func testFileDroppedOnTheWindowOpens() throws {
        let (_, controller) = try untitled()
        let text = try write("dropped\n", name: "dropped.txt")
        let picture = folder.appendingPathComponent("picture.png")
        try XCTUnwrap(NSImage(size: NSSize(width: 4, height: 4), flipped: false) { _ in true }
            .tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
            .write(to: picture)
        let board = pasteboard([text, picture, folder])
        // Like the Open panel: any file (a picture opens as text, as in
        // TextEdit, Info.plist "Unknown document"), never a folder.
        XCTAssertEqual(DocumentWindowController.openableFileURLs(on: board).map(\.standardizedFileURL),
                       [text.standardizedFileURL, picture.standardizedFileURL])
        let board2 = pasteboard([text, folder])

        let drop = FakeDrop(board2)
        // The drop reaches the window, and the window hands it to its
        // delegate, the window controller.
        let window = try XCTUnwrap(controller.window)
        typealias Entered = @convention(c) (AnyObject, Selector, AnyObject) -> UInt
        typealias Perform = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let entered = #selector(NSDraggingDestination.draggingEntered(_:))
        let perform = #selector(NSDraggingDestination.performDragOperation(_:))
        XCTAssertTrue(window.responds(to: entered) && window.responds(to: perform))
        let enteredOp = unsafeBitCast(window.method(for: entered), to: Entered.self)(window, entered, drop)
        XCTAssertEqual(NSDragOperation(rawValue: enteredOp), .copy, "the window did not pass draggingEntered on")
        XCTAssertTrue(unsafeBitCast(window.method(for: perform), to: Perform.self)(window, perform, drop),
                      "the window did not pass the drop on")
        let opened = try XCTUnwrap(waitForDocument(at: text), "the dropped file did not open")
        documents.append(opened)
        XCTAssertEqual((opened as? TextDocument)?.textStorage.string, "dropped\n")

        let refused = FakeDrop(pasteboard([folder]))
        XCTAssertEqual(controller.draggingEntered(refused), [])
        XCTAssertFalse(controller.performDragOperation(refused))
    }

    /// The dragged files' types are read once, when the drag enters; each
    /// draggingUpdated (sent on every mouse move) reuses the answer (M9
    /// review row 11). A new drag reads them again.
    func testDragWorksOutTheOpenableFilesOnceWhenItEnters() throws {
        let (_, controller) = try untitled()
        let text = try write("dragged\n", name: "dragged.txt")
        let board = pasteboard([text])
        let drop = FakeDrop(board)
        XCTAssertEqual(controller.draggingEntered(drop), .copy)
        XCTAssertEqual(controller.draggedOpenableURLs?.map(\.standardizedFileURL), [text.standardizedFileURL])
        // Proof that updates do not read the pasteboard: empty it.
        board.clearContents()
        for _ in 0..<5 { XCTAssertEqual(controller.draggingUpdated(drop), .copy) }
        controller.draggingExited(drop)
        XCTAssertNil(controller.draggedOpenableURLs)
        // A new drag over the now-empty pasteboard is refused.
        XCTAssertEqual(controller.draggingEntered(drop), [])
        XCTAssertEqual(controller.draggingUpdated(drop), [])
        controller.draggingEnded(drop)
        XCTAssertNil(controller.draggedOpenableURLs)
    }

    /// A file dropped on the Dock icon reaches the app as an Open Documents
    /// Apple Event. This hands one straight to the app's event handler (no
    /// Launch Services, so nothing arrives after the test ends).
    func testOpenDocumentsEventLikeTheDocksOpensTheFile() throws {
        let url = try write("from the Dock\n", name: "dock.txt")
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments),
                                           targetDescriptor: NSAppleEventDescriptor.currentProcess(),
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(fileURL: url), at: 1)
        event.setParam(list, forKeyword: keyDirectObject)
        let raw = try XCTUnwrap(event.aeDesc)
        var reply = AppleEvent()
        var refCon = 0
        let status = NSAppleEventManager.shared().dispatchRawAppleEvent(raw, withRawReply: &reply, handlerRefCon: &refCon)
        AEDisposeDesc(&reply)
        XCTAssertEqual(Int(status), Int(noErr))
        let opened = try XCTUnwrap(waitForDocument(at: url), "the Open Documents event did not open the file")
        documents.append(opened)
        XCTAssertEqual((opened as? TextDocument)?.textStorage.string, "from the Dock\n")
    }

    /// Text dragged in or out is plain text only, and a file dropped into
    /// the text inserts its path (TextEdit's plain mode).
    func testTextDragsArePlainAndAFileDropInsertsItsPath() throws {
        let (_, controller) = try untitled()
        let textView = controller.textView
        // A drag out (or a copy) carries the selection as plain text only.
        textView.string = "drag me"
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertEqual(textView.writablePasteboardTypes, [NSPasteboard.PasteboardType("NSStringPboardType")])
        let out = NSPasteboard.withUniqueName()
        XCTAssertTrue(textView.writeSelection(to: out, types: textView.writablePasteboardTypes))
        XCTAssertEqual(out.types?.filter { !$0.rawValue.hasPrefix("dyn.") && $0.rawValue != "NSStringPboardType" }, [.string])
        XCTAssertEqual(out.string(forType: .string), "drag")

        // Rich text on the pasteboard comes in as its plain characters.
        textView.string = ""
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        let styled = NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 30)])
        board.writeObjects([styled])
        XCTAssertTrue(textView.readSelection(from: board))
        XCTAssertEqual(textView.string, "bold")
        let font = textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font, TextViewFactory.plainFont(), "the dropped text kept its own font")

        let url = try write("x\n", name: "path me.txt")
        textView.string = ""
        XCTAssertTrue(textView.readSelection(from: pasteboard([url]), type: .fileURL))
        XCTAssertEqual(textView.string, url.path)
    }

    // MARK: 2. Share (P73)

    /// AppKit's File > Share is off for a document never saved, on for one with a file.
    func testShareIsOffUntilTheDocumentHasAFile() throws {
        let (untitledDocument, _) = try untitled()
        XCTAssertFalse(ShareMenuValidator.canShare(untitledDocument))
        XCTAssertFalse(ShareMenuValidator.canShare(nil))
        let (savedDocument, _) = try open(try write("saved\n", name: "share.txt"))
        XCTAssertTrue(ShareMenuValidator.canShare(savedDocument))

        let file = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "File")?.submenu)
        XCTAssertTrue(file.delegate === ShareMenuValidator.shared)
        let share = try XCTUnwrap(ShareMenuValidator.shareItem(in: file), "AppKit added no File > Share")
        XCTAssertNotNil(share.submenu)

        // M9 review row 7: with each window in front, the File menu is
        // updated as when it opens (its delegate, then AppKit's own
        // enabling), and Share follows the front document.
        let untitledWindow = try XCTUnwrap(untitledDocument.windowControllers.first?.window)
        let savedWindow = try XCTUnwrap(savedDocument.windowControllers.first?.window)
        // The test host is not the active app, so it has no main window;
        // the validator is told which window is in front.
        let validator = ShareMenuValidator.shared
        let liveFront = validator.frontWindow
        defer { validator.frontWindow = liveFront }
        for (window, document, enabled) in [(untitledWindow, untitledDocument, false), (savedWindow, savedDocument, true),
                                            (untitledWindow, untitledDocument, false)] {
            window.orderFront(nil)
            validator.frontWindow = { window }
            XCTAssertTrue(validator.frontDocument === document, "\(document.displayName ?? "?") is not the front document")
            validator.menuNeedsUpdate(file)
            file.update()
            XCTAssertEqual(share.isEnabled, enabled, "Share with \(document.displayName ?? "?") in front")
        }
    }

    // MARK: 3. Writing Tools (P73)

    func testWritingToolsGivePlainTextAndAreOffForAFileTooLargeToEdit() throws {
        let (_, controller) = try untitled()
        XCTAssertEqual(controller.textView.writingToolsBehavior, .none)  // off by default since 1.2.1
        XCTAssertEqual(controller.textView.allowedWritingToolsResultOptions, [.plainText])

        TextDocument.largeFileThreshold = 10
        TextDocument.readOnlyThreshold = 20
        let (document, large) = try open(try write(String(repeating: "a long line\n", count: 4), name: "big.txt"))
        XCTAssertTrue(document.isTooLargeToEdit)
        XCTAssertEqual(large.textView.writingToolsBehavior, .none)
        // Wrap to Page: every page view has them off too.
        document.hasMultiplePages = true
        for view in large.textViews { XCTAssertEqual(view.writingToolsBehavior, .none) }
    }

    // MARK: 4. Services (P71)

    /// The Services menu sends the selection as plain text and puts plain
    /// text back.
    func testServicesSendAndReceivePlainText() throws {
        XCTAssertNotNil(NSApp.servicesMenu)
        let (_, controller) = try untitled()
        let textView = controller.textView
        textView.string = "hello services"
        textView.setSelectedRange(NSRange(location: 6, length: 8))
        // NSTextView, as in TextEdit, names its types the pre-UTI way; the
        // Services machinery and the pasteboard translate them.
        let plain = NSPasteboard.PasteboardType("NSStringPboardType")
        XCTAssertEqual(textView.writablePasteboardTypes, [plain], "sends only plain text")
        XCTAssertTrue(textView.validRequestor(forSendType: plain, returnType: plain) as AnyObject === textView)
        XCTAssertNil(textView.validRequestor(forSendType: NSPasteboard.PasteboardType("NeXT Rich Text Format v1.0 pasteboard type"),
                                             returnType: nil))
        let board = NSPasteboard.withUniqueName()
        XCTAssertTrue(textView.writeSelection(to: board, types: [plain]))
        XCTAssertEqual(board.string(forType: .string), "services")
        board.clearContents()
        board.setString("SERVICES", forType: .string)
        XCTAssertTrue(textView.readSelection(from: board))
        XCTAssertEqual(textView.string, "hello SERVICES")
    }

    // MARK: 5. Keyboard access

    /// Every control of each Settings tab is in that tab's key-view loop,
    /// so Full Keyboard Access (Tab) reaches it. Controls inside the
    /// Keyboard tab's table are reached through the table (Return, Delete).
    func testEverySettingsControlIsInATabsKeyLoop() throws {
        let controller = SettingsWindowController()
        controller.loadSettingsWindowIfNeeded()
        defer { controller.window?.close() }
        let tabs = try XCTUnwrap(controller.tabView)
        for item in tabs.tabViewItems {
            let view = try XCTUnwrap(item.view)
            var controls: [NSView] = []
            func collect(_ view: NSView) {
                for sub in view.subviews {
                    if sub is NSTableView { controls.append(sub); continue }
                    if let control = sub as? NSControl, control.isEnabled,
                       !((control as? NSTextField).map { !$0.isEditable && !$0.isSelectable } ?? false) {
                        controls.append(control)
                    }
                    collect(sub)
                }
            }
            collect(view)
            XCTAssertFalse(controls.isEmpty, item.label)
            // M9 review row 4: the window's Restore All Defaults, under the
            // tabs, is in every tab's loop, and the loop closes.
            tabs.selectTabViewItem(item)
            controls.append(try XCTUnwrap(controller.restoreButton))
            var loop: [NSView] = []
            var next: NSView? = controls.first
            while let view = next, !loop.contains(where: { $0 === view }), loop.count < 50 {
                loop.append(view)
                next = view.nextKeyView
            }
            XCTAssertTrue(next === controls.first, "\(item.label): the key loop does not lead back to its first control")
            for control in controls {
                XCTAssertTrue(loop.contains { $0 === control }, "\(item.label): \(control) is not in the key loop")
            }
        }
    }

    // MARK: 6. Quick Look

    /// macOS makes a thumbnail of a file QuickEdit saved. M9 n1: the test
    /// host is sandboxed, and `qlmanage -t` cannot run from it (measured
    /// 2026-10-25: "[Sandbox] Setting up sandbox for qlmanage failed,
    /// exiting!", exit 255), so the test asks the same system Quick Look
    /// service through QLThumbnailGenerator. Only a real thumbnail counts,
    /// never the file's icon.
    func testQuickLookMakesAThumbnailOfASavedFile() async throws {
        let (document, _) = try untitled()
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Quick Look sees this\n")
        let url = folder.appendingPathComponent("look.txt")
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: url, ofType: TextDocument.plainTextType, for: .saveAsOperation) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(error)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128), scale: 1,
                                                   representationTypes: .thumbnail)
        let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        XCTAssertEqual(thumbnail.type, .thumbnail, "Quick Look gave \(thumbnail.type.rawValue), not a thumbnail")
        XCTAssertGreaterThan(thumbnail.nsImage.size.width, 0)
    }
}

/// A drop for the dragging-destination calls: only the pasteboard matters.
private final class FakeDrop: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    @MainActor init(_ board: NSPasteboard) { draggingPasteboard = board }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
