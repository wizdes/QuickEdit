import AppKit
import XCTest
@testable import QuickEdit

/// Fixes for the M6 code review (docs/reviews/M6-code.md rows 1, 6, 7, 9,
/// 10, 13, 14). Encoding rows 2-5 are in M6EncodingTests.
@MainActor
final class M6ReviewFixTests: XCTestCase {
    private var saved: SavedSettings!
    private var controllers: [SettingsWindowController] = []
    private var documents: [NSDocument] = []
    private var store: UserDefaults { Defaults.store }

    override func setUp() async throws {
        saved = SavedSettings()
    }

    override func tearDown() async throws {
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        for controller in controllers { controller.window?.close() }
        controllers = []
        NSFontPanel.shared.orderOut(nil)
        saved.restore()
    }

    private func makeController() throws -> (SettingsWindowController, NSWindow) {
        let controller = SettingsWindowController()
        let window = controller.loadSettingsWindowIfNeeded()
        controllers.append(controller)
        return (controller, window)
    }

    /// Types `text` into `field` the way a person does: the field becomes
    /// first responder, its field editor gets the text, then editing ends.
    private func type(_ text: String, into field: NSTextField, in window: NSWindow) throws {
        XCTAssertTrue(window.makeFirstResponder(field), "the field takes focus")
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "no field editor")
        editor.selectAll(nil)
        if text.isEmpty { editor.deleteBackward(nil) } else { editor.insertText(text, replacementRange: editor.selectedRange()) }
        XCTAssertTrue(window.makeFirstResponder(nil), "editing ends")
    }

    // MARK: Row 1: a defaults change posted on a background thread

    func testRow1BackgroundDefaultsChangeIsHandledOnTheMainThread() async throws {
        let (controller, _) = try makeController()
        let box = try XCTUnwrap(controller.checkboxes[.smartQuotes])
        store.set(true, forKey: DefaultsKey.smartQuotes.rawValue)
        XCTAssertEqual(box.state, .on)
        // A write from another thread: UserDefaults posts its notice there.
        nonisolated(unsafe) let store = self.store // UserDefaults is thread-safe
        await Task.detached {
            store.set(false, forKey: DefaultsKey.smartQuotes.rawValue)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: store)
        }.value
        let deadline = Date().addingTimeInterval(2)
        while box.state != .off, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(box.state, .off, "the window follows the change, on the main thread")
    }

    // MARK: Row 6: a new document's first Save panel uses the "Saving files" encoding

    func testRow6NewDocumentStartsAtTheSavingFilesEncoding() throws {
        store.set(Int(String.Encoding.windowsCP1252.rawValue), forKey: DefaultsKey.plainTextEncodingForWrite.rawValue)
        let fits = TextDocument()
        documents.append(fits)
        fits.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "caf\u{E9}")
        let panel = NSSavePanel()
        XCTAssertTrue(fits.prepareSavePanel(panel))
        let popUp = try XCTUnwrap(panel.accessoryView?.subviews.compactMap { $0 as? EncodingPopUpButton }.first)
        XCTAssertEqual(popUp.selectedEncoding, .windowsCP1252, "the Saving files encoding holds the text")

        let doesNotFit = TextDocument()
        documents.append(doesNotFit)
        doesNotFit.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\u{65E5}\u{672C}")
        let other = NSSavePanel()
        XCTAssertTrue(doesNotFit.prepareSavePanel(other))
        let otherPopUp = try XCTUnwrap(other.accessoryView?.subviews.compactMap { $0 as? EncodingPopUpButton }.first)
        XCTAssertEqual(otherPopUp.selectedEncoding, .utf8, "it cannot hold Japanese: UTF-8")
    }

    // MARK: Row 7: a saved default that left the list stays shown

    func testRow7RemovedDefaultEncodingStaysShownAtTheTop() throws {
        EncodingManager.shared.setEnabled([.utf8, .utf16])
        defer { EncodingManager.shared.revertToDefault() }
        store.set(Int(String.Encoding.windowsCP1252.rawValue), forKey: DefaultsKey.plainTextEncoding.rawValue)
        let (controller, _) = try makeController()
        let popUp = try XCTUnwrap(controller.openEncodingPopUp)
        XCTAssertEqual(popUp.selectedEncoding, .windowsCP1252, "not Automatic")
        XCTAssertEqual(popUp.indexOfSelectedItem, 0)
        XCTAssertEqual(popUp.itemArray.first?.title, String.localizedName(of: .windowsCP1252))
        XCTAssertEqual(popUp.itemArray.dropFirst().first?.title, "Automatic")
        // It survives a list change.
        EncodingManager.shared.setEnabled([.utf8])
        XCTAssertEqual(popUp.selectedEncoding, .windowsCP1252)
        XCTAssertEqual(SettingsWindowController.encoding(for: .plainTextEncoding), .windowsCP1252, "the default is kept")
    }

    // MARK: Row 9: stronger tests through the real paths

    /// The Change… button, then a field takes focus (row 13: its field
    /// editor is first responder), then the Font panel's change arrives
    /// through the font manager, as it does from the panel.
    func testRow9And13FontChangeReachesTheControllerThroughTheFontManager() throws {
        let (controller, window) = try makeController()
        controller.setPlainTextFont(try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 11)))
        let manager = NSFontManager.shared
        let oldTarget = manager.target
        defer { manager.target = oldTarget }
        manager.target = nil
        let change = try XCTUnwrap(controller.changeFontButton)
        XCTAssertTrue(change.sendAction(change.action, to: change.target))
        XCTAssertTrue(window.makeFirstResponder(controller.widthField))
        XCTAssertNotNil(controller.widthField?.currentEditor(), "a field editor is first responder")
        let bigger = NSMenuItem()
        bigger.tag = Int(NSFontAction.sizeUpFontAction.rawValue)
        manager.modifyFont(bigger)
        XCTAssertEqual(NSFont.userFixedPitchFont(ofSize: 0)?.pointSize, 12)
        XCTAssertEqual(NSFont.userFixedPitchFont(ofSize: 0)?.fontName, "Menlo-Regular")
    }

    func testRow9JunkTypedInASizeFieldPutsBackTheOldValue() throws {
        store.set(77, forKey: DefaultsKey.widthInChars.rawValue)
        let (controller, window) = try makeController()
        let field = try XCTUnwrap(controller.widthField)
        XCTAssertEqual(field.integerValue, 77)
        for junk in ["abc", "0", "10001"] {
            try type(junk, into: field, in: window)
            XCTAssertEqual(field.stringValue, "77", "after \(junk)")
            XCTAssertEqual(Defaults.integer(.widthInChars), 77, "after \(junk)")
        }
        try type("64", into: field, in: window)
        XCTAssertEqual(Defaults.integer(.widthInChars), 64)
    }

    func testRow9RestoreAllDefaultsKeepsTheEncodingsList() throws {
        EncodingManager.shared.setEnabled([.utf8, .shiftJIS])
        defer { EncodingManager.shared.revertToDefault() }
        let (controller, _) = try makeController()
        try XCTUnwrap(controller.restoreButton).performClick(nil)
        XCTAssertEqual(EncodingManager.enabledEncodings(), [.utf8, .shiftJIS], "Restore All Defaults keeps Encodings")
    }

    /// The menu bar names the shared controller, and building it does not
    /// build that controller's window.
    func testRow9MenuBuildLeavesTheSharedControllerUnbuilt() throws {
        let shared = SettingsWindowController.shared
        let builtBefore = shared.isWindowBuilt
        let bar = MainMenu.build()
        let item = try XCTUnwrap(bar.items.first?.submenu?.item(withTitle: "Settings\u{2026}"))
        XCTAssertTrue(item.target === shared)
        XCTAssertEqual(shared.isWindowBuilt, builtBefore, "building the menu built the Settings window")
        // The app's own menu bar, built at launch, names the same controller.
        let live = NSApp.mainMenu?.items.first?.submenu?.item(withTitle: "Settings\u{2026}")
        XCTAssertTrue(live?.target === shared)
    }

    // MARK: Row 10: an emptied size field shows its value again

    func testRow10EmptySizeFieldRestoresTheShownValue() throws {
        store.set(55, forKey: DefaultsKey.heightInChars.rawValue)
        let (controller, window) = try makeController()
        let field = try XCTUnwrap(controller.heightField)
        try type("", into: field, in: window)
        XCTAssertEqual(field.stringValue, "55", "an empty field shows the value again")
        XCTAssertEqual(Defaults.integer(.heightInChars), 55)
    }

    // MARK: Row 13: tab order

    func testRow13TabOrderAndFirstField() throws {
        let (controller, window) = try makeController()
        let width = try XCTUnwrap(controller.widthField), height = try XCTUnwrap(controller.heightField)
        XCTAssertTrue(window.initialFirstResponder === width)
        XCTAssertTrue(width.nextKeyView === height, "Width -> Height")
        XCTAssertTrue(height.nextKeyView === controller.changeFontButton, "Height -> Change…")
        // The New Document tab's controls form one loop back to the start.
        var view: NSView? = controller.checkboxes[.showPageBreaks]
        var seen: [NSView] = []
        while let current = view, !seen.contains(where: { $0 === current }) {
            seen.append(current)
            view = current.nextKeyView
        }
        XCTAssertTrue(view === controller.checkboxes[.showPageBreaks], "the loop closes")
        XCTAssertEqual(seen.count, 13, "Wrap, Paper size, Width, Height, Change…, 8 options")
        // Open and Save: the .txt checkbox, then both pop-ups, and back.
        let txt = try XCTUnwrap(controller.checkboxes[.addExtensionToNewPlainTextFiles])
        XCTAssertTrue(txt.nextKeyView === controller.openEncodingPopUp)
        XCTAssertTrue(controller.openEncodingPopUp?.nextKeyView === controller.saveEncodingPopUp)
        XCTAssertTrue(controller.saveEncodingPopUp?.nextKeyView === txt)
    }

    // MARK: Row 14: tests can use their own defaults

    func testRow14ControlsWriteTheDefaultsStore() throws {
        let name = "dev.yili.QuickEdit.tests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let realBefore = UserDefaults.standard.persistentDomain(forName: SavedSettings.bundleID) as NSDictionary?
        let previous = Defaults.store
        Defaults.store = suite
        defer {
            Defaults.store = previous
            suite.removePersistentDomain(forName: name)
        }
        let (controller, _) = try makeController()
        let box = try XCTUnwrap(controller.checkboxes[.smartDashes])
        let before = Defaults.bool(.smartDashes)
        box.performClick(nil)
        XCTAssertEqual(suite.persistentDomain(forName: name)?[DefaultsKey.smartDashes.rawValue] as? Bool, !before,
                       "the click wrote the test suite")
        let realAfter = UserDefaults.standard.persistentDomain(forName: SavedSettings.bundleID) as NSDictionary?
        XCTAssertEqual(realAfter, realBefore, "the real settings did not change")
    }
}
