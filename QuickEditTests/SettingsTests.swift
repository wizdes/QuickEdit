import AppKit
import XCTest
@testable import QuickEdit

/// M6 n1: the Settings window (reference/apple/Preferences.m,
/// Base.lproj/Preferences.nib; docs/codemap.md sections 1.10 and 3).
/// Every test puts the app's real user defaults and plain font back.
@MainActor
final class SettingsTests: XCTestCase {
    private var saved: SavedSettings!
    private var controllers: [SettingsWindowController] = []

    override func setUp() async throws {
        saved = SavedSettings()
    }

    override func tearDown() async throws {
        for controller in controllers { controller.window?.close() }
        controllers = []
        saved.restore()
    }

    private func makeController() -> SettingsWindowController {
        let controller = SettingsWindowController()
        controller.loadSettingsWindowIfNeeded()
        controllers.append(controller)
        return controller
    }

    // MARK: The window

    func testWindowHasTextEditsTwoTabsAndPlainControls() throws {
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.title, "Settings")
        XCTAssertEqual(window.identifier, SettingsWindowController.windowIdentifier)
        XCTAssertTrue(window.isExcludedFromWindowsMenu)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertTrue(window.restorationClass == SettingsWindowController.self)
        XCTAssertEqual(window.contentView?.frame.width, 440)

        let tabs = try XCTUnwrap(controller.tabView)
        XCTAssertEqual(tabs.tabViewItems.map(\.label), ["New Document", "Open and Save"])

        let titles = Dictionary(uniqueKeysWithValues: controller.checkboxes.map { ($0.key, $0.value.title) })
        XCTAssertEqual(titles, [
            .showPageBreaks: "Wrap to page",
            .checkSpellingWhileTyping: "Check spelling as you type",
            .checkGrammarWithSpelling: "Check grammar with spelling",
            .correctSpellingAutomatically: "Correct spelling automatically",
            .dataDetectors: "Data detectors",
            .smartCopyPaste: "Smart copy/paste",
            .smartQuotes: "Smart quotes",
            .smartDashes: "Smart dashes",
            .textReplacement: "Text replacement",
            .addExtensionToNewPlainTextFiles: "Add \".txt\" extension to plain text files",
        ])
        let newDocument = try XCTUnwrap(tabs.tabViewItems[0].view)
        let openAndSave = try XCTUnwrap(tabs.tabViewItems[1].view)
        XCTAssertTrue(controller.checkboxes[.addExtensionToNewPlainTextFiles]!.isDescendant(of: openAndSave))
        XCTAssertTrue(try XCTUnwrap(controller.widthField).isDescendant(of: newDocument))
        XCTAssertTrue(try XCTUnwrap(controller.heightField).isDescendant(of: newDocument))
        XCTAssertTrue(try XCTUnwrap(controller.changeFontButton).isDescendant(of: newDocument))
        XCTAssertEqual(controller.changeFontButton?.title, "Change...")
        XCTAssertTrue(try XCTUnwrap(controller.openEncodingPopUp).isDescendant(of: openAndSave))
        XCTAssertTrue(try XCTUnwrap(controller.saveEncodingPopUp).isDescendant(of: openAndSave))
        XCTAssertEqual(controller.restoreButton?.title, "Restore All Defaults")

        let labels = allLabels(in: newDocument) + allLabels(in: openAndSave)
        for text in ["Format", "Window Size", "Width:", "characters", "Height:", "lines", "Font",
                     "Plain text font:", "Options", "When Saving a File:", "Plain Text File Encoding",
                     "Opening files:", "Saving files:"] {
            XCTAssertTrue(labels.contains(text), "missing label \(text)")
        }
        // Nothing from the dropped rich-text and HTML controls.
        for text in ["Rich text font:", "Author:", "Show ruler", "Smart links", "HTML Saving Options"] {
            XCTAssertFalse(labels.contains(text), "dropped control \(text) is present")
        }
        // Every control lies inside its tab, none overlap the tab's edge.
        for view in [newDocument, openAndSave] {
            for sub in view.subviews {
                XCTAssertTrue(view.bounds.contains(sub.frame), "\(sub) sticks out of its tab")
            }
        }
    }

    private func allLabels(in view: NSView) -> [String] {
        view.subviews.compactMap { ($0 as? NSTextField).flatMap { $0.isEditable ? nil : $0.stringValue } }
    }

    func testMenuHasSettingsItem() throws {
        let bar = MainMenu.build()
        let app = try XCTUnwrap(bar.items.first?.submenu)
        let settings = try XCTUnwrap(app.item(withTitle: "Settings\u{2026}"))
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(settings.action, #selector(NSWindowController.showWindow(_:)))
        XCTAssertTrue(settings.target === SettingsWindowController.shared)
        // About, a separator, Settings…, a separator, Services (Edit.nib:60-110).
        let index = app.index(of: settings)
        XCTAssertEqual(index, 2)
        XCTAssertTrue(app.item(at: 1)?.isSeparatorItem ?? false)
        XCTAssertTrue(app.item(at: 3)?.isSeparatorItem ?? false)
        XCTAssertEqual(app.item(at: 4)?.title, "Services")
    }

    func testControllerBuildsNoWindowUntilShown() {
        let controller = SettingsWindowController()
        controllers.append(controller)
        XCTAssertFalse(controller.isWindowBuilt)
        controller.loadSettingsWindowIfNeeded()
        XCTAssertTrue(controller.isWindowBuilt)
    }

    // MARK: Each control writes its default

    func testEveryCheckboxWritesItsDefault() throws {
        let controller = makeController()
        XCTAssertEqual(controller.checkboxes.count, 10)
        for (key, box) in controller.checkboxes {
            let before = Defaults.bool(key)
            XCTAssertEqual(box.state == .on, before, "\(key.rawValue) shows the wrong state")
            box.performClick(nil)
            XCTAssertEqual(Defaults.bool(key), !before, "\(key.rawValue) did not change")
            XCTAssertEqual(persisted(key) as? Bool, !before, "\(key.rawValue) is not in the saved defaults")
            box.performClick(nil)
            XCTAssertEqual(Defaults.bool(key), before, "\(key.rawValue) did not change back")
        }
    }

    /// The value in the app's saved defaults file: what a relaunch reads.
    private func persisted(_ key: DefaultsKey) -> Any? {
        UserDefaults.standard.persistentDomain(forName: SavedSettings.bundleID)?[key.rawValue]
    }

    func testSizeFieldsWriteTheirDefaults() throws {
        let controller = makeController()
        for (field, key, value) in [(controller.widthField, DefaultsKey.widthInChars, 60),
                                    (controller.heightField, .heightInChars, 12)] {
            let field = try XCTUnwrap(field)
            XCTAssertEqual(field.integerValue, Defaults.integer(key))
            field.integerValue = value
            XCTAssertTrue(field.sendAction(field.action, to: field.target))
            XCTAssertEqual(Defaults.integer(key), value)
            XCTAssertEqual(persisted(key) as? Int, value)
        }
    }

    /// 1 to 10000, whole numbers only (Preferences.nib:405-460); junk puts
    /// back the value from before editing (Preferences.m:211-220).
    func testSizeFieldsRejectJunk() throws {
        let controller = makeController()
        let field = try XCTUnwrap(controller.widthField)
        let formatter = try XCTUnwrap(field.formatter as? NumberFormatter)
        for junk in ["0", "10001", "-3", "4.5", "abc"] {
            var object: AnyObject?
            XCTAssertFalse(formatter.getObjectValue(&object, for: junk, errorDescription: nil), junk)
        }
        for good in ["1", "60", "10000"] {
            var object: AnyObject?
            XCTAssertTrue(formatter.getObjectValue(&object, for: good, errorDescription: nil), good)
        }

        UserDefaults.standard.set(77, forKey: DefaultsKey.widthInChars.rawValue)
        controller.refreshControls()
        controller.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        field.stringValue = "abc"
        XCTAssertTrue(controller.control(field, didFailToFormatString: "abc", errorDescription: nil))
        XCTAssertEqual(field.integerValue, 77)
        XCTAssertEqual(Defaults.integer(.widthInChars), 77)
    }

    func testEncodingPopUpsWriteTheirDefaults() throws {
        let controller = makeController()
        for (popUp, key) in [(controller.openEncodingPopUp, DefaultsKey.plainTextEncoding),
                             (controller.saveEncodingPopUp, .plainTextEncodingForWrite)] {
            let popUp = try XCTUnwrap(popUp)
            XCTAssertEqual(popUp.itemArray.first?.title, "Automatic")
            XCTAssertEqual(popUp.itemArray.last?.title, EncodingManager.customizeTitle)

            let utf8 = try XCTUnwrap(popUp.itemArray.firstIndex {
                ($0.representedObject as? NSNumber)?.uintValue == String.Encoding.utf8.rawValue
            })
            popUp.selectItem(at: utf8)
            XCTAssertTrue(popUp.sendAction(popUp.action, to: popUp.target))
            XCTAssertEqual(UserDefaults.standard.integer(forKey: key.rawValue), Int(String.Encoding.utf8.rawValue))
            XCTAssertEqual((persisted(key) as? NSNumber)?.uintValue, String.Encoding.utf8.rawValue)
            XCTAssertEqual(SettingsWindowController.encoding(for: key), .utf8)

            popUp.selectItem(at: 0)
            XCTAssertTrue(popUp.sendAction(popUp.action, to: popUp.target))
            XCTAssertEqual(UserDefaults.standard.integer(forKey: key.rawValue), Defaults.noStringEncoding)
            XCTAssertNil(SettingsWindowController.encoding(for: key))
        }
        // The documents read the same value (TextDocument.defaultOpenEncoding).
        UserDefaults.standard.set(Int(String.Encoding.windowsCP1252.rawValue), forKey: DefaultsKey.plainTextEncoding.rawValue)
        XCTAssertEqual(TextDocument.defaultOpenEncoding(), .windowsCP1252)
        XCTAssertEqual(controller.openEncodingPopUp?.selectedEncoding, .windowsCP1252)
    }

    func testPlainTextFontIsStoredAsTheUserFixedPitchFont() throws {
        let controller = makeController()
        let font = try XCTUnwrap(NSFont(name: "Menlo-Bold", size: 15))
        controller.setPlainTextFont(font)
        let stored = try XCTUnwrap(NSFont.userFixedPitchFont(ofSize: 0))
        XCTAssertEqual(stored.fontName, "Menlo-Bold")
        XCTAssertEqual(stored.pointSize, 15)
        XCTAssertEqual(TextViewFactory.plainFont().fontName, "Menlo-Bold")
        XCTAssertEqual(controller.fontNameField?.stringValue, "\(font.displayName ?? "") 15")
        XCTAssertNotNil(UserDefaults.standard.persistentDomain(forName: SavedSettings.bundleID)?["NSFixedPitchFont"])
    }

    /// The font manager's `changeFont:` message reaches the controller,
    /// which asks the manager to convert the current plain font
    /// (Preferences.m:102-108). Format > Font > Bigger's action stands in
    /// for the Font panel, which needs a screen.
    func testFontManagerChangeSetsThePlainFont() throws {
        let controller = makeController()
        controller.setPlainTextFont(try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 11)))
        let manager = NSFontManager.shared
        let oldTarget = manager.target
        defer { manager.target = oldTarget }
        manager.target = controller
        manager.setSelectedFont(controller.plainTextFont, isMultiple: false)
        let bigger = NSMenuItem()
        bigger.tag = Int(NSFontAction.sizeUpFontAction.rawValue)
        manager.modifyFont(bigger)
        XCTAssertEqual(NSFont.userFixedPitchFont(ofSize: 0)?.pointSize, 12)
        XCTAssertEqual(NSFont.userFixedPitchFont(ofSize: 0)?.fontName, "Menlo-Regular")
        XCTAssertEqual(controller.fontNameField?.stringValue, SettingsWindowController.fontDescription(controller.plainTextFont))
        XCTAssertEqual(controller.validModesForFontPanel(NSFontPanel.shared), [.face, .size, .collection])
    }

    func testRestoreAllDefaultsResetsEveryKey() throws {
        let controller = makeController()
        NSFont.setUserFixedPitch(nil)
        let systemFont = try XCTUnwrap(NSFont.userFixedPitchFont(ofSize: 0))

        // Change every control and the keys without a control.
        for box in controller.checkboxes.values { box.performClick(nil) }
        controller.widthField?.integerValue = 33
        controller.widthField.map { _ = $0.sendAction($0.action, to: $0.target) }
        UserDefaults.standard.set(44, forKey: DefaultsKey.heightInChars.rawValue)
        UserDefaults.standard.set(Int(String.Encoding.utf8.rawValue), forKey: DefaultsKey.plainTextEncoding.rawValue)
        UserDefaults.standard.set(Int(String.Encoding.utf16.rawValue), forKey: DefaultsKey.plainTextEncodingForWrite.rawValue)
        UserDefaults.standard.set(4, forKey: DefaultsKey.tabWidth.rawValue)
        UserDefaults.standard.set(5, forKey: DefaultsKey.autosavingDelay.rawValue)
        UserDefaults.standard.set(true, forKey: DefaultsKey.numberPagesWhenPrinting.rawValue)
        UserDefaults.standard.set(false, forKey: DefaultsKey.wrapToFitWhenPrinting.rawValue)
        controller.setPlainTextFont(try XCTUnwrap(NSFont(name: "Courier", size: 20)))

        let registered = Defaults.registeredValues()
        let changed = registered.filter { key, value in
            !(UserDefaults.standard.object(forKey: key) as AnyObject).isEqual(value)
        }
        // All but the hidden app-centric key were changed above.
        XCTAssertEqual(Set(changed.keys), Set(DefaultsKey.allCases.map(\.rawValue)).subtracting([DefaultsKey.encodings.rawValue]))

        let restore = try XCTUnwrap(controller.restoreButton)
        restore.performClick(nil)

        for (key, value) in registered {
            XCTAssertTrue((UserDefaults.standard.object(forKey: key) as AnyObject).isEqual(value),
                          "\(key) is \(String(describing: UserDefaults.standard.object(forKey: key))), not \(value)")
            XCTAssertNil(UserDefaults.standard.persistentDomain(forName: SavedSettings.bundleID)?[key],
                         "\(key) is still saved")
        }
        XCTAssertEqual(NSFont.userFixedPitchFont(ofSize: 0), systemFont)
        // The controls show the restored values.
        for (key, box) in controller.checkboxes {
            XCTAssertEqual(box.state == .on, Defaults.bool(key), key.rawValue)
        }
        XCTAssertEqual(controller.widthField?.integerValue, 90)
        XCTAssertEqual(controller.heightField?.integerValue, 30)
        XCTAssertEqual(controller.openEncodingPopUp?.indexOfSelectedItem, 0)
        XCTAssertEqual(controller.saveEncodingPopUp?.indexOfSelectedItem, 0)
        XCTAssertEqual(controller.fontNameField?.stringValue, SettingsWindowController.fontDescription(systemFont))
    }

    /// The window follows a default changed elsewhere (TextEdit's bindings did).
    func testControlsFollowOutsideChanges() throws {
        let controller = makeController()
        let box = try XCTUnwrap(controller.checkboxes[.smartQuotes])
        UserDefaults.standard.set(true, forKey: DefaultsKey.smartQuotes.rawValue)
        XCTAssertEqual(box.state, .on)
        UserDefaults.standard.set(false, forKey: DefaultsKey.smartQuotes.rawValue)
        XCTAssertEqual(box.state, .off)
    }

    func testRestorationReturnsTheSharedWindowAndRejectsOthers() {
        var restored: NSWindow?
        var failure: (any Error)?
        SettingsWindowController.restoreWindow(withIdentifier: NSUserInterfaceItemIdentifier("Other"),
                                               state: NSKeyedArchiver(requiringSecureCoding: true)) { window, error in
            restored = window
            failure = error
        }
        XCTAssertNil(restored)
        XCTAssertNotNil(failure)
        SettingsWindowController.restoreWindow(withIdentifier: SettingsWindowController.windowIdentifier,
                                               state: NSKeyedArchiver(requiringSecureCoding: true)) { window, _ in
            restored = window
        }
        XCTAssertNotNil(restored)
        XCTAssertTrue(restored === SettingsWindowController.shared.window)
        restored?.close()
    }

    // MARK: Renders

    /// Draws each tab offscreen into build/shots/settings-*.png.
    func testRenderTabs() throws {
        NSFont.setUserFixedPitch(nil)
        Defaults.restoreAll()
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        let tabs = try XCTUnwrap(controller.tabView)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/shots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, name, appearance) in [(0, "settings-new-document", NSAppearance.Name.darkAqua),
                                          (1, "settings-open-and-save", .darkAqua),
                                          (0, "settings-new-document-light", .aqua),
                                          (1, "settings-open-and-save-light", .aqua)] {
            window.appearance = NSAppearance(named: appearance)
            tabs.selectTabViewItem(at: index)
            let frameView = try XCTUnwrap(window.contentView?.superview)
            frameView.layoutSubtreeIfNeeded()
            frameView.display()
            let rep = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: folder.appendingPathComponent("\(name).png"))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

/// The app's saved defaults and plain font, taken before a test and put
/// back after it, so tests never leave the user's settings changed.
@MainActor
struct SavedSettings {
    static let bundleID = Bundle.main.bundleIdentifier ?? "dev.yili.QuickEdit"
    private let domain: [String: Any]?
    private let fixedPitchFont: NSFont?

    init() {
        domain = UserDefaults.standard.persistentDomain(forName: Self.bundleID)
        let hasFont = domain?["NSFixedPitchFont"] != nil
        fixedPitchFont = hasFont ? NSFont.userFixedPitchFont(ofSize: 0) : nil
    }

    func restore() {
        NSFont.setUserFixedPitch(fixedPitchFont)
        if let domain {
            UserDefaults.standard.setPersistentDomain(domain, forName: Self.bundleID)
        } else {
            UserDefaults.standard.removePersistentDomain(forName: Self.bundleID)
        }
    }
}
