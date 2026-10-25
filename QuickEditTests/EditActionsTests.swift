import AppKit
import XCTest
@testable import QuickEdit

/// M4 n1: each Edit and Format menu item's action, sent from the real menu
/// item, reaches a QuickEdit text view (or document) and does what TextEdit's does.
@MainActor
final class EditActionsTests: XCTestCase {
    private var windows: [NSWindow] = []
    /// A text view does not keep its storage alive; these do.
    private var storages: [NSTextStorage] = []
    private var documents: [NSDocument] = []
    /// AppKit may save substitution toggles to the app's defaults. The tests
    /// run inside the real app, so the user's settings are put back afterwards.
    private var savedDefaults: [String: Any]?
    private let bundleID = Bundle.main.bundleIdentifier ?? "dev.yili.QuickEdit"

    override func setUp() async throws {
        savedDefaults = UserDefaults.standard.persistentDomain(forName: bundleID)
    }

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows = []
        storages = []
        for document in documents { document.close() }
        documents = []
        if let savedDefaults {
            UserDefaults.standard.setPersistentDomain(savedDefaults, forName: bundleID)
        } else {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }

    // MARK: Helpers

    private func item(_ path: String...) throws -> NSMenuItem {
        try item(path)
    }

    /// A text view from TextViewFactory, first responder in an offscreen window.
    private func makeTextView(_ text: String) -> NSTextView {
        let storage = NSTextStorage(string: text, attributes: TextViewFactory.plainTextAttributes())
        storages.append(storage)
        let size = NSSize(width: 400, height: 200)
        let textView = TextViewFactory.makeTextView(storage: storage, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = textView
        window.makeFirstResponder(textView)
        windows.append(window)
        return textView
    }

    /// Sends the item's action to `target` the way the menu does.
    private func send(_ item: NSMenuItem, to target: AnyObject, file: StaticString = #filePath, line: UInt = #line) {
        guard let action = item.action else { return XCTFail("\(item.title) has no action", file: file, line: line) }
        XCTAssertTrue(target.responds(to: action), "\(type(of: target)) does not do \(item.title)", file: file, line: line)
        XCTAssertTrue(NSApp.sendAction(action, to: target, from: item), "\(item.title) was not handled",
                      file: file, line: line)
    }

    // MARK: Transformations

    func testTransformationsChangeTheSelectedText() throws {
        let textView = makeTextView("hello wORLD")
        // One undo group per menu choice, as one menu event makes in the app.
        let undoManager = try XCTUnwrap(textView.undoManager)
        undoManager.groupsByEvent = false
        defer { undoManager.groupsByEvent = true }
        func choose(_ title: String) throws {
            textView.selectAll(nil)
            undoManager.beginUndoGrouping()
            send(try item("Edit", "Transformations", title), to: textView)
            undoManager.endUndoGrouping()
        }
        try choose("Make Upper Case")
        XCTAssertEqual(textView.string, "HELLO WORLD")
        try choose("Make Lower Case")
        XCTAssertEqual(textView.string, "hello world")
        try choose("Capitalize")
        XCTAssertEqual(textView.string, "Hello World")
        // Each one is a normal edit: Undo takes it back.
        undoManager.undo()
        XCTAssertEqual(textView.string, "hello world")
    }

    // MARK: Complete

    private final class CompletionSpy: NSObject, NSTextViewDelegate {
        var partialWords: [String] = []
        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            partialWords.append((textView.string as NSString).substring(with: charRange))
            return [] // no completion window
        }
    }

    func testCompleteAsksForCompletionsOfTheWordBeforeTheCaret() throws {
        let textView = makeTextView("say hel")
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        let spy = CompletionSpy()
        textView.delegate = spy
        let complete = try item("Edit", "Complete")
        XCTAssertEqual(complete.keyEquivalent, "\u{1B}")
        XCTAssertEqual(complete.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.option])
        send(complete, to: textView)
        XCTAssertEqual(spy.partialWords, ["hel"])
        XCTAssertEqual(textView.string, "say hel", "no completions, so the text stays")
        textView.delegate = nil
    }

    // MARK: Spelling and Substitutions toggles

    func testEachToggleFlipsItsTextViewFlag() throws {
        let textView = makeTextView("text")
        let toggles: [(path: [String], flag: (NSTextView) -> Bool)] = [
            (["Spelling and Grammar", "Check Spelling While Typing"], { $0.isContinuousSpellCheckingEnabled }),
            (["Spelling and Grammar", "Check Grammar With Spelling"], { $0.isGrammarCheckingEnabled }),
            (["Spelling and Grammar", "Correct Spelling Automatically"], { $0.isAutomaticSpellingCorrectionEnabled }),
            (["Substitutions", "Smart Copy/Paste"], { $0.smartInsertDeleteEnabled }),
            (["Substitutions", "Smart Quotes"], { $0.isAutomaticQuoteSubstitutionEnabled }),
            (["Substitutions", "Smart Dashes"], { $0.isAutomaticDashSubstitutionEnabled }),
            (["Substitutions", "Data Detectors"], { $0.isAutomaticDataDetectionEnabled }),
            (["Substitutions", "Text Replacement"], { $0.isAutomaticTextReplacementEnabled }),
        ]
        for toggle in toggles {
            let menuItem = try item(["Edit"] + toggle.path)
            let before = toggle.flag(textView)
            // The menu shows the current state with a check mark.
            XCTAssertTrue(textView.validateMenuItem(menuItem), menuItem.title)
            XCTAssertEqual(menuItem.state, before ? .on : .off, "check mark for \(menuItem.title)")
            send(menuItem, to: textView)
            XCTAssertEqual(toggle.flag(textView), !before, "\(menuItem.title) did not flip")
            send(menuItem, to: textView)
            XCTAssertEqual(toggle.flag(textView), before, "\(menuItem.title) did not flip back")
        }
    }

    private func item(_ path: [String]) throws -> NSMenuItem {
        var menu = MainMenu.build()
        for title in path.dropLast() {
            menu = try XCTUnwrap(menu.item(withTitle: title)?.submenu, "no menu \(title)")
        }
        return try XCTUnwrap(menu.item(withTitle: path.last!), "no item \(path.joined(separator: " > "))")
    }

    /// Why Data Detectors stays: on a plain TextKit 1 view it marks the phone
    /// number, date and address (temporary attributes the layout manager
    /// draws on hover) and adds nothing to the stored text, so saved bytes
    /// cannot change.
    func testDataDetectorsMarksTextWithoutChangingIt() throws {
        let sample = "Call 408-996-1010 or meet on March 3, 2027 at 3pm at 1 Infinite Loop, Cupertino, CA 95014. "
        let textView = makeTextView("")
        textView.isAutomaticDataDetectionEnabled = false
        send(try item("Edit", "Substitutions", "Data Detectors"), to: textView)
        XCTAssertTrue(textView.isAutomaticDataDetectionEnabled)
        textView.insertText(sample, replacementRange: NSRange(location: 0, length: 0))
        textView.checkTextInDocument(nil)

        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let key = NSAttributedString.Key("NSDataDetection")
        func marked() -> Bool {
            var index = 0
            while index < textView.string.utf16.count {
                var range = NSRange()
                if layoutManager.temporaryAttributes(atCharacterIndex: index, effectiveRange: &range)[key] != nil {
                    return true
                }
                index = max(index + 1, NSMaxRange(range))
            }
            return false
        }
        let deadline = Date().addingTimeInterval(10)
        while !marked() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(marked(), "Data Detectors marked nothing on a plain TextKit 1 view")
        XCTAssertEqual(textView.string, sample)
        var keys = Set<NSAttributedString.Key>()
        let storage = try XCTUnwrap(textView.textStorage)
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
            keys.formUnion(attributes.keys)
        }
        XCTAssertEqual(keys, [.font, .paragraphStyle, .foregroundColor], "Data Detectors changed the stored text")
    }

    // MARK: Find, Jump to Selection, Speech, panels

    func testFindShowsTheFindBarOfTheDocumentWindow() throws {
        let document = TextDocument()
        document.makeWindowControllers()
        documents.append(document)
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        let scrollView = try XCTUnwrap(controller.textView.enclosingScrollView)
        XCTAssertFalse(scrollView.isFindBarVisible)
        let find = try item("Edit", "Find", "Find\u{2026}")
        XCTAssertTrue(controller.textView.validateMenuItem(find))
        send(find, to: controller.textView)
        XCTAssertTrue(scrollView.isFindBarVisible)
        for title in ["Find and Replace\u{2026}", "Find Next", "Find Previous", "Use Selection for Find"] {
            XCTAssertTrue(controller.textView.responds(to: try item("Edit", "Find", title).action!), title)
        }
    }

    /// These open system panels or speak aloud, so the test checks only that
    /// the text view takes the action and enables the item.
    func testOtherItemsReachTheTextView() throws {
        let textView = makeTextView("some words")
        let paths: [[String]] = [
            ["Edit", "Undo"], ["Edit", "Redo"], ["Edit", "Cut"], ["Edit", "Copy"], ["Edit", "Paste"],
            ["Edit", "Delete"], ["Edit", "Select All"],
            ["Edit", "Find", "Jump to Selection"],
            ["Edit", "Spelling and Grammar", "Show Spelling and Grammar"],
            ["Edit", "Spelling and Grammar", "Check Document Now"],
            ["Edit", "Substitutions", "Show Substitutions"],
            ["Edit", "Speech", "Start Speaking"], ["Edit", "Speech", "Stop Speaking"],
        ]
        for path in paths {
            let menuItem = try item(path)
            let action = try XCTUnwrap(menuItem.action, menuItem.title)
            // Undo and Redo are answered by the window, not the text view.
            if action == Selector(("undo:")) || action == Selector(("redo:")) {
                XCTAssertNotNil(textView.undoManager, menuItem.title)
                continue
            }
            XCTAssertTrue(textView.responds(to: action), "the text view does not do \(menuItem.title)")
        }
        textView.selectAll(nil)
        send(try item("Edit", "Delete"), to: textView)
        XCTAssertEqual(textView.string, "")
    }

    // MARK: Sent with no target, results checked (M4 review row 2)

    /// Sends the item's action with no target, as a menu choice does.
    /// When `window` is the key window, this is `NSApp.sendAction(_:to:nil from:)`.
    /// A unit-test host cannot become the active app while the screen is
    /// locked, so it has no key window; then the action goes up the window's
    /// responder chain from its first responder, which is the part of
    /// AppKit's nil-target search that reaches a text view or its window.
    /// The UI tests in FindAndLineTests cover the real key-window path.
    private func sendWithNoTarget(_ item: NSMenuItem, in window: NSWindow,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard let action = item.action else { return XCTFail("\(item.title) has no action", file: file, line: line) }
        window.makeKeyAndOrderFront(nil)
        if NSApp.keyWindow === window {
            XCTAssertTrue(NSApp.sendAction(action, to: nil, from: item), "\(item.title) was not handled",
                          file: file, line: line)
            return
        }
        var responder: NSResponder? = window.firstResponder
        while let current = responder, !current.responds(to: action) {
            responder = current.nextResponder
        }
        guard let target = responder else {
            return XCTFail("nothing in the responder chain does \(item.title)", file: file, line: line)
        }
        if let validator = target as? NSMenuItemValidation {
            XCTAssertTrue(validator.validateMenuItem(item), "\(item.title) is disabled", file: file, line: line)
        }
        XCTAssertTrue(target.tryToPerform(action, with: item), "\(item.title) was not handled", file: file, line: line)
    }

    /// A text view in a scroll view, first responder in an offscreen window.
    private func makeScrollingTextView(_ text: String) -> NSTextView {
        let storage = NSTextStorage(string: text, attributes: TextViewFactory.plainTextAttributes())
        storages.append(storage)
        let size = NSSize(width: 400, height: 200)
        let textView = TextViewFactory.makeTextView(storage: storage, size: size)
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        windows.append(window)
        return textView
    }

    /// Copies of every item on the general pasteboard, put back after a test that uses it.
    private func savePasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    private func restorePasteboard(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = saved.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    func testCutCopyPasteDeleteUndoRedoChangeTextPasteboardAndUndoState() throws {
        let saved = savePasteboard()
        defer { restorePasteboard(saved) }
        let textView = makeTextView("alpha beta gamma")
        let window = try XCTUnwrap(textView.window)
        let undoManager = try XCTUnwrap(textView.undoManager)
        undoManager.removeAllActions()
        // One undo group per edit, as one menu event makes in the app. Undo
        // and Redo run outside any group, as they do from the menu.
        undoManager.groupsByEvent = false
        defer { undoManager.groupsByEvent = true }
        func choose(_ path: String...) throws {
            let edits = ["Cut", "Paste", "Delete"].contains(path.last!)
            if edits { undoManager.beginUndoGrouping() }
            sendWithNoTarget(try item(path), in: window)
            if edits { undoManager.endUndoGrouping() }
        }
        let pasteboard = NSPasteboard.general

        textView.setSelectedRange(NSRange(location: 6, length: 5))
        try choose("Edit", "Copy")
        XCTAssertEqual(pasteboard.string(forType: .string), "beta ")
        XCTAssertEqual(textView.string, "alpha beta gamma", "Copy changed the text")
        XCTAssertFalse(undoManager.canUndo, "Copy made an undo step")

        textView.setSelectedRange(NSRange(location: 0, length: 6))
        try choose("Edit", "Cut")
        XCTAssertEqual(textView.string, "beta gamma")
        XCTAssertEqual(pasteboard.string(forType: .string), "alpha ")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertTrue(undoManager.canUndo)

        textView.setSelectedRange(NSRange(location: 10, length: 0))
        try choose("Edit", "Paste")
        XCTAssertEqual(textView.string, "beta gammaalpha ")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 16, length: 0))

        try choose("Edit", "Undo")
        XCTAssertEqual(textView.string, "beta gamma", "Undo did not take back Paste")
        XCTAssertTrue(undoManager.canRedo)
        try choose("Edit", "Undo")
        XCTAssertEqual(textView.string, "alpha beta gamma", "Undo did not take back Cut")
        XCTAssertFalse(undoManager.canUndo)
        try choose("Edit", "Redo")
        XCTAssertEqual(textView.string, "beta gamma", "Redo did not do Cut again")
        XCTAssertTrue(undoManager.canRedo, "the Paste step was lost")
        try choose("Edit", "Redo")
        XCTAssertEqual(textView.string, "beta gammaalpha ")
        XCTAssertFalse(undoManager.canRedo)

        textView.setSelectedRange(NSRange(location: 0, length: 5))
        try choose("Edit", "Delete")
        XCTAssertEqual(textView.string, "gammaalpha ")
        XCTAssertEqual(pasteboard.string(forType: .string), "alpha ", "Delete wrote to the pasteboard")

        try choose("Edit", "Select All")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 11))
    }

    func testJumpToSelectionScrollsTheSelectionIntoView() throws {
        let text = (1...300).map { "line \($0)" }.joined(separator: "\n")
        let textView = makeScrollingTextView(text)
        let window = try XCTUnwrap(textView.window)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let target = (text as NSString).range(of: "line 280")
        textView.setSelectedRange(target)
        layoutManager.ensureLayout(for: container)
        textView.scroll(.zero)
        let glyphs = layoutManager.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        XCTAssertFalse(textView.visibleRect.intersects(rect), "the selection was already in view")

        sendWithNoTarget(try item("Edit", "Find", "Jump to Selection"), in: window)
        XCTAssertTrue(textView.visibleRect.contains(rect), "Jump to Selection did not show the selection")
        XCTAssertEqual(textView.selectedRange(), target)
    }

    func testCheckDocumentNowSelectsTheFirstMisspelling() throws {
        let textView = makeTextView("the wrod is here")
        let window = try XCTUnwrap(textView.window)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        sendWithNoTarget(try item("Edit", "Spelling and Grammar", "Check Document Now"), in: window)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 4), "the misspelled word was not selected")
        XCTAssertEqual(textView.string, "the wrod is here")
    }

    func testShowPanelsOpenTheSpellingAndSubstitutionsPanels() throws {
        let textView = makeTextView("text")
        let window = try XCTUnwrap(textView.window)
        let checker = NSSpellChecker.shared
        let panels: [(path: [String], panel: NSPanel)] = [
            (["Edit", "Spelling and Grammar", "Show Spelling and Grammar"], checker.spellingPanel),
            (["Edit", "Substitutions", "Show Substitutions"], checker.substitutionsPanel),
        ]
        for (path, panel) in panels {
            panel.orderOut(nil)
            XCTAssertFalse(panel.isVisible)
            sendWithNoTarget(try item(path), in: window)
            XCTAssertTrue(panel.isVisible, "\(path.last!) did not show its panel")
            panel.orderOut(nil)
        }
    }

    /// Speaks aloud for a moment, then stops. The text view's speech state
    /// is read from its Stop Speaking item, which it enables only while it
    /// speaks. (NSSpeechSynthesizer.isAnyApplicationSpeaking stays false for
    /// a text view's speech on macOS 27, so it cannot be used.)
    func testStartAndStopSpeakingDriveTheSpeechSynthesizer() throws {
        let textView = makeTextView(String(repeating: "Quick edit speaks this sentence. ", count: 4))
        let window = try XCTUnwrap(textView.window)
        textView.selectAll(nil)
        let stop = try item("Edit", "Speech", "Stop Speaking")
        func speaking() -> Bool { textView.validateMenuItem(stop) }
        XCTAssertFalse(speaking(), "the text view was already speaking")
        sendWithNoTarget(try item("Edit", "Speech", "Start Speaking"), in: window)
        XCTAssertTrue(speaking(), "Start Speaking did not start speech")
        sendWithNoTarget(stop, in: window)
        XCTAssertFalse(speaking(), "Stop Speaking did not stop speech")
    }

    // MARK: Prevent Editing

    func testPreventEditingMakesTheViewReadOnlyAndBack() throws {
        let document = TextDocument()
        document.makeWindowControllers()
        documents.append(document)
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        let textView = controller.textView
        textView.insertText("abc", replacementRange: NSRange(location: 0, length: 0))
        let toggle = try item("Format", "Prevent Editing")

        XCTAssertTrue(textView.isEditable)
        send(toggle, to: document)
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(document.validateMenuItem(toggle))
        XCTAssertEqual(toggle.title, "Allow Editing")
        // A read-only view refuses edits from other menu items too.
        textView.selectAll(nil)
        NSApp.sendAction(#selector(NSResponder.uppercaseWord(_:)), to: textView, from: nil)
        XCTAssertEqual(textView.string, "abc")

        send(toggle, to: document)
        XCTAssertTrue(textView.isEditable)
        XCTAssertTrue(document.validateMenuItem(toggle))
        XCTAssertEqual(toggle.title, "Prevent Editing")
        textView.selectAll(nil)
        NSApp.sendAction(#selector(NSResponder.uppercaseWord(_:)), to: textView, from: nil)
        XCTAssertEqual(textView.string, "ABC")
    }
}
