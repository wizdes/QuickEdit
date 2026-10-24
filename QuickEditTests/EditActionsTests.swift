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
