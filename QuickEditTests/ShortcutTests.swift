import AppKit
import XCTest
@testable import QuickEdit

/// M9 n3 (user decision U2): custom keyboard shortcuts. The store keeps
/// changes only, a change reaches the menu at once and after a relaunch
/// (a new MainMenu.build()), and a clash, a key macOS keeps, or a key with
/// no Cmd or Ctrl is refused with a message. Every test uses its own
/// defaults suite (SavedSettings) and its own built menu bar, never the
/// app's live one.
@MainActor
final class ShortcutTests: XCTestCase {
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

    private func command(_ id: String, in menu: NSMenu) throws -> (NSMenuItem, MenuCommand) {
        let found = Shortcuts.commandItems(in: menu).first { $0.command.id == id }
        let pair = try XCTUnwrap(found, "no command \(id)")
        return (pair.item, pair.command)
    }

    // MARK: 1. Stable ids, defaults in code

    /// Every id, in menu order. Saved shortcuts are keyed by these, so an
    /// id must never change (a rename loses the user's shortcut).
    static let allIDs = [
        "app.about", "app.settings", "app.hide", "app.hideOthers", "app.showAll", "app.quit",
        "file.new", "file.open", "file.close", "file.save", "file.duplicate", "file.saveAs",
        "file.rename", "file.moveTo", "file.saveAll", "file.revert", "file.exportPDF", "file.print",
        "edit.undo", "edit.redo", "edit.cut", "edit.copy", "edit.paste", "edit.delete", "edit.complete",
        "edit.selectAll",
        "find.find", "find.replace", "find.next", "find.previous", "find.useSelection", "find.jump",
        "find.selectLine",
        "spelling.show", "spelling.checkNow", "spelling.whileTyping", "spelling.grammar", "spelling.correct",
        "substitutions.show", "substitutions.smartCopyPaste", "substitutions.smartQuotes",
        "substitutions.smartDashes", "substitutions.dataDetectors", "substitutions.textReplacement",
        "transformations.upper", "transformations.lower", "transformations.capitalize",
        "speech.start", "speech.stop",
        "format.preventEditing", "format.wrapToPage",
        "view.actualSize", "view.zoomIn", "view.zoomOut", "view.fullScreen",
        "window.minimize", "window.zoom", "window.bringAllToFront",
    ]

    func testEveryCommandHasAStableUniqueID() {
        let ids = Shortcuts.commandItems(in: MainMenu.build()).map(\.command.id)
        XCTAssertEqual(ids, Self.allIDs)
        XCTAssertEqual(Set(ids).count, 58)
    }

    func testDefaultShortcutsAreTheMenusOwnKeys() {
        for (item, command) in Shortcuts.commandItems(in: MainMenu.build()) {
            XCTAssertEqual(KeyShortcut(of: item), command.defaultShortcut, command.id)
        }
        XCTAssertNil(saved.store.object(forKey: Defaults.keyboardShortcutsKey), "nothing is saved by default")
    }

    /// Every command QuickEdit builds is in the app's live menu bar too:
    /// AppKit's own additions (Revert To, Share, Writing Tools) replace
    /// none. AppKit keeps a second Enter Full Screen item; it shares the
    /// command, so it gets the same shortcut.
    func testLiveMenuBarHasEveryCommand() throws {
        let live = try XCTUnwrap(NSApp.mainMenu)
        var ids: [String] = []
        for id in Shortcuts.commandItems(in: live).map(\.command.id) where ids.last != id { ids.append(id) }
        XCTAssertEqual(ids, Self.allIDs)
        let rows = Shortcuts.rows(for: live).filter { if case .command = $0 { true } else { false } }
        XCTAssertEqual(rows.count, 58, "one row per command in the live menu bar")
    }

    // MARK: 2. The store keeps changes only

    func testStoreKeepsOnlyChanges() throws {
        let menu = MainMenu.build()
        let (_, new) = try command("file.new", in: menu)
        let (_, save) = try command("file.save", in: menu)
        Shortcuts.set(KeyShortcut("y", [.command, .shift]), for: new, applyingTo: menu)
        Shortcuts.set(.empty, for: save, applyingTo: menu)
        let stored = try XCTUnwrap(saved.persisted?[Defaults.keyboardShortcutsKey] as? [String: [String: Any]])
        XCTAssertEqual(Set(stored.keys), ["file.new", "file.save"])
        XCTAssertEqual(stored["file.new"]?["key"] as? String, "y")
        XCTAssertEqual(stored["file.new"]?["modifiers"] as? Int,
                       Int(NSEvent.ModifierFlags([.command, .shift]).rawValue))
        XCTAssertEqual(stored["file.save"]?["key"] as? String, "")

        // Setting the default again removes the change; no changes, no key.
        Shortcuts.set(KeyShortcut("n"), for: new, applyingTo: menu)
        Shortcuts.set(nil, for: save, applyingTo: menu)
        XCTAssertNil(saved.persisted?[Defaults.keyboardShortcutsKey])
    }

    func testMalformedSavedEntryKeepsTheDefault() throws {
        saved.store.set(["file.new": ["key": 5], "file.open": ["key": "k", "modifiers": Int(NSEvent.ModifierFlags.command.rawValue)]],
                        forKey: Defaults.keyboardShortcutsKey)
        let menu = MainMenu.build()
        XCTAssertEqual(KeyShortcut(of: try command("file.new", in: menu).0), KeyShortcut("n"))
        XCTAssertEqual(KeyShortcut(of: try command("file.open", in: menu).0), KeyShortcut("k"))
    }

    // MARK: 3. Applied at once, and after a relaunch

    func testChangeAppliesToTheMenuAtOnceAndAfterARelaunch() throws {
        let menu = MainMenu.build()
        let (item, new) = try command("file.new", in: menu)
        Shortcuts.set(KeyShortcut("y", [.command, .shift]), for: new, applyingTo: menu)
        XCTAssertEqual(item.keyEquivalent, "y")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        // A relaunch builds the menu bar again from the saved changes.
        let relaunched = MainMenu.build()
        let (again, _) = try command("file.new", in: relaunched)
        XCTAssertEqual(again.keyEquivalent, "y")
        XCTAssertEqual(again.keyEquivalentModifierMask, [.command, .shift])
        // The menu really answers the new key, and no longer the old one.
        XCTAssertTrue(try menuAnswers(relaunched, "y", [.command, .shift]) === again)
        XCTAssertNil(try menuAnswers(relaunched, "n", [.command]))
    }

    /// The item `menu` runs for this key press: the event goes through
    /// AppKit's own `NSMenu.performKeyEquivalent` (M9 review row 6). Every
    /// command item's action is pointed at a spy first, so nothing really
    /// runs, and the spy names the item AppKit chose.
    private func menuAnswers(_ menu: NSMenu, _ key: String, _ modifiers: NSEvent.ModifierFlags) throws -> NSMenuItem? {
        let keyCodes: [String: UInt16] = ["y": 16, "n": 45, "p": 35, "s": 1, "o": 31]
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                   timestamp: 0, windowNumber: 0, context: nil,
                                                   characters: modifiers.contains(.shift) ? key.uppercased() : key,
                                                   charactersIgnoringModifiers: key,
                                                   isARepeat: false, keyCode: try XCTUnwrap(keyCodes[key], key)))
        let spy = MenuActionSpy()
        for (item, _) in Shortcuts.commandItems(in: menu) {
            item.target = spy
            item.action = #selector(MenuActionSpy.ran(_:))
        }
        let handled = menu.performKeyEquivalent(with: event)
        XCTAssertEqual(handled, spy.ran != nil, "performKeyEquivalent said \(handled), the spy saw \(String(describing: spy.ran))")
        return spy.ran
    }

    /// Two commands, one key, never: resetting New to Cmd+N while Print
    /// has Cmd+N is refused with the recorder's clash message (M9 review
    /// row 1), by the reset button and by Delete on the row.
    func testResettingARowWhoseDefaultKeyIsTakenIsRefused() throws {
        let menu = MainMenu.build()
        let tab = makeTab(menu)
        let (newItem, new) = try command("file.new", in: menu)
        let (printItem, print) = try command("file.print", in: menu)
        let moved = KeyShortcut("n", [.control, .option, .command])
        Shortcuts.set(moved, for: new, applyingTo: menu)
        Shortcuts.set(KeyShortcut("n"), for: print, applyingTo: menu)
        tab.reload()
        let expected = "\u{2318}N is already used by \u{201C}Print\u{2026}\u{201D} in the File menu."
        XCTAssertEqual(Shortcuts.resetRefusal(for: new, in: menu)?.message, expected)

        let row = try XCTUnwrap(tab.row(of: "file.new"))
        let reset = tab.tableView.view(atColumn: 1, row: row, makeIfNecessary: true)?.subviews
            .first { $0.identifier == KeyboardTabController.resetButtonIdentifier("file.new") } as? NSButton
        try XCTUnwrap(reset).performClick(nil)
        XCTAssertEqual(KeyShortcut(of: newItem), moved, "New keeps its moved key")
        XCTAssertEqual(KeyShortcut(of: printItem), KeyShortcut("n"), "Print keeps Cmd+N")
        XCTAssertEqual(tab.refusal?.message, expected)
        XCTAssertTrue(tab.messageField.stringValue.hasSuffix(expected), tab.messageField.stringValue)

        tab.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tab.tableView.keyDown(with: try key(51, "\u{7F}"))
        XCTAssertEqual(KeyShortcut(of: newItem), moved, "Delete did not reset New either")
        XCTAssertEqual(KeyShortcut(of: printItem), KeyShortcut("n"))
        let stored = try XCTUnwrap(saved.persisted?[Defaults.keyboardShortcutsKey] as? [String: Any])
        XCTAssertEqual(Set(stored.keys), ["file.new", "file.print"])

        // Once Print lets go of Cmd+N, the reset works and the message goes.
        Shortcuts.set(nil, for: print, applyingTo: menu)
        tab.reload()
        tab.resetRow(try XCTUnwrap(tab.row(of: "file.new")))
        XCTAssertEqual(KeyShortcut(of: newItem), KeyShortcut("n"))
        XCTAssertNil(tab.refusal)
        XCTAssertEqual(tab.messageField.stringValue, "")
    }

    /// The standard text-editing keys are refused with the editing action's
    /// name (M9 review row 5); the same keys without the editing modifier,
    /// or with Cmd added to a Ctrl key, are not editing keys.
    func testTextEditingKeysAreRefusedWithTheActionsName() throws {
        let menu = MainMenu.build()
        let (_, save) = try command("file.save", in: menu)
        func key(_ value: Int) -> String { String(Character(UnicodeScalar(UInt32(value))!)) }
        let left = key(NSLeftArrowFunctionKey), right = key(NSRightArrowFunctionKey)
        let up = key(NSUpArrowFunctionKey), down = key(NSDownArrowFunctionKey)
        var keys: [(KeyShortcut, String)] = [
            (KeyShortcut("a", [.control]), "Move to Beginning of Line"),
            (KeyShortcut("e", [.control]), "Move to End of Line"),
            (KeyShortcut("b", [.control]), "Move Backward"), (KeyShortcut("f", [.control]), "Move Forward"),
            (KeyShortcut("n", [.control]), "Move Down"), (KeyShortcut("p", [.control]), "Move Up"),
            (KeyShortcut("k", [.control]), "Delete to End of Line"), (KeyShortcut("y", [.control]), "Yank"),
            (KeyShortcut("d", [.control]), "Delete Forward"), (KeyShortcut("h", [.control]), "Delete Backward"),
            (KeyShortcut("t", [.control]), "Transpose"), (KeyShortcut("o", [.control]), "Insert Line Break"),
            (KeyShortcut(left, [.command]), "Move to Beginning of Line"),
            (KeyShortcut(right, [.command]), "Move to End of Line"),
            (KeyShortcut(up, [.command]), "Move to Beginning of Document"),
            (KeyShortcut(down, [.command]), "Move to End of Document"),
            (KeyShortcut(left, [.option]), "Move Word Left"), (KeyShortcut(right, [.option]), "Move Word Right"),
            (KeyShortcut(up, [.option]), "Move to Beginning of Paragraph"),
            (KeyShortcut(down, [.option]), "Move to End of Paragraph"),
            (KeyShortcut("\u{08}", [.command]), "Delete to Beginning of Line"),
            (KeyShortcut("\u{7F}", [.command]), "Delete to Beginning of Line"),
            (KeyShortcut("\u{08}", [.option]), "Delete Word Backward"),
            (KeyShortcut(left, [.command, .shift]), "Select to Beginning of Line"),
        ]
        // Ctrl+A as the recorder hands it over from a real key press.
        if case let .candidate(recorded) = ShortcutRecorder.outcome(for: try self.key(0, "\u{01}", [.control])) {
            keys.append((recorded, "Move to Beginning of Line"))
        } else {
            XCTFail("the recorder did not read Ctrl+A")
        }
        for (shortcut, action) in keys {
            let refusal = Shortcuts.refusal(for: shortcut, command: save, in: menu)
            XCTAssertEqual(refusal?.message,
                           "\(shortcut.normalized.display) is the text-editing key for \u{201C}\(action)\u{201D}.",
                           shortcut.display)
            XCTAssertEqual(refusal?.keysText, shortcut.normalized.display)
        }
        XCTAssertNil(Shortcuts.refusal(for: KeyShortcut("a", [.control, .command]), command: save, in: menu))
        XCTAssertNil(Shortcuts.refusal(for: KeyShortcut(left, [.control, .command]), command: save, in: menu))

        // The Keyboard tab refuses it and keeps recording.
        let tab = makeTab(menu)
        tab.startRecording("file.save")
        tab.handle(.candidate(KeyShortcut("k", [.control])))
        XCTAssertTrue(tab.isRecording)
        XCTAssertEqual(tab.refusal?.message, "\u{2303}K is the text-editing key for \u{201C}Delete to End of Line\u{201D}.")
        XCTAssertEqual(KeyShortcut(of: try command("file.save", in: menu).0), KeyShortcut("s"))
        tab.endRecording()
    }

    func testRestoreDefaultsPutsEveryKeyBack() throws {
        let menu = MainMenu.build()
        let (item, print) = try command("file.print", in: menu)
        Shortcuts.set(KeyShortcut("p", [.command, .shift]), for: print, applyingTo: menu)
        Shortcuts.restoreDefaults(applyingTo: menu)
        XCTAssertEqual(KeyShortcut(of: item), KeyShortcut("p"))
        XCTAssertNil(saved.persisted?[Defaults.keyboardShortcutsKey])
    }

    func testRestoreAllDefaultsDropsTheShortcutsToo() throws {
        let menu = MainMenu.build()
        Shortcuts.set(KeyShortcut("y", [.command, .shift]), for: try command("file.new", in: menu).1, applyingTo: menu)
        Defaults.restoreAll()
        XCTAssertNil(saved.persisted?[Defaults.keyboardShortcutsKey])
    }

    /// Save As… is Duplicate's Option-key alternate only while their keys pair.
    func testSaveAsStaysAnAlternateOnlyWhileItPairsWithDuplicate() throws {
        let menu = MainMenu.build()
        let (saveAs, _) = try command("file.saveAs", in: menu)
        let (_, duplicate) = try command("file.duplicate", in: menu)
        XCTAssertTrue(saveAs.isAlternate)
        Shortcuts.set(KeyShortcut("d", [.command, .shift]), for: duplicate, applyingTo: menu)
        XCTAssertFalse(saveAs.isAlternate, "Save As… shows as its own item")
        Shortcuts.set(nil, for: duplicate, applyingTo: menu)
        XCTAssertTrue(saveAs.isAlternate)
    }

    // MARK: 4. Refusals

    func testClashNamesTheOtherCommand() throws {
        let menu = MainMenu.build()
        let (_, save) = try command("file.save", in: menu)
        let clash = Shortcuts.refusal(for: KeyShortcut("o"), command: save, in: menu)
        XCTAssertEqual(clash, .clash(KeyShortcut("o"), name: "Open\u{2026}", menuPath: "File"))
        XCTAssertEqual(clash?.message, "\u{2318}O is already used by \u{201C}Open\u{2026}\u{201D} in the File menu.")

        let inSubmenu = Shortcuts.refusal(for: KeyShortcut("f"), command: save, in: menu)
        XCTAssertEqual(inSubmenu?.message,
                       "\u{2318}F is already used by \u{201C}Find\u{2026}\u{201D} in the Edit > Find menu.")
        // Shift+Cmd+; is the same key press as Show Spelling and Grammar's Cmd+:.
        let shifted = Shortcuts.refusal(for: KeyShortcut(";", [.command, .shift]), command: save, in: menu)
        XCTAssertEqual(shifted?.message, "\u{2318}: is already used by \u{201C}Show Spelling and Grammar\u{201D} "
                       + "in the Edit > Spelling and Grammar menu.")
        // Its own key is no clash.
        XCTAssertNil(Shortcuts.refusal(for: KeyShortcut("s"), command: save, in: menu))
        XCTAssertNil(Shortcuts.refusal(for: KeyShortcut("y", [.command, .shift]), command: save, in: menu))
    }

    /// Items AppKit adds count too (Close All is Option+Cmd+W in the live menu).
    func testClashWithAnItemAppKitAddedNamesIt() throws {
        let live = try XCTUnwrap(NSApp.mainMenu)
        let (_, new) = try command("file.new", in: live)
        let refusal = Shortcuts.refusal(for: KeyShortcut("w", [.command, .option]), command: new, in: live)
        XCTAssertEqual(refusal?.message, "\u{2325}\u{2318}W is already used by \u{201C}Close All\u{201D} in the File menu.")
    }

    func testKeysMacOSKeepsAreRefused() throws {
        let menu = MainMenu.build()
        let (_, save) = try command("file.save", in: menu)
        for (shortcut, text) in [(KeyShortcut("\t", [.command]), "\u{2318}\u{21E5}"),
                                 (KeyShortcut(" ", [.command]), "\u{2318}Space"),
                                 (KeyShortcut("\u{1B}", [.command, .option]), "\u{2325}\u{2318}\u{238B}")] {
            let refusal = Shortcuts.refusal(for: shortcut, command: save, in: menu)
            XCTAssertEqual(refusal, .system(shortcut))
            XCTAssertEqual(refusal?.message, "\(text) is kept by macOS.")
        }
    }

    func testShortcutNeedsCommandOrControlUnlessAFunctionKey() throws {
        let menu = MainMenu.build()
        let (_, save) = try command("file.save", in: menu)
        for bare in [KeyShortcut("y", []), KeyShortcut("y", [.option]), KeyShortcut("y", [.shift, .option])] {
            XCTAssertEqual(Shortcuts.refusal(for: bare, command: save, in: menu), .needsModifier)
        }
        XCTAssertEqual(Shortcuts.Refusal.needsModifier.message,
                       "A shortcut needs \u{2318} or \u{2303}, unless it is a function key.")
        let f5 = KeyShortcut(String(Character(UnicodeScalar(UInt32(NSF5FunctionKey))!)), [])
        XCTAssertTrue(f5.isFunctionKey)
        XCTAssertEqual(f5.display, "F5")
        XCTAssertNil(Shortcuts.refusal(for: f5, command: save, in: menu))
        // Ctrl+J: Ctrl alone is enough (Ctrl+Y, used here before M9 review
        // row 5, is the text-editing key Yank now).
        XCTAssertNil(Shortcuts.refusal(for: KeyShortcut("j", [.control]), command: save, in: menu))
    }

    // MARK: 5. Names of keys

    func testDisplayNamesMatchTheMenuBar() {
        XCTAssertEqual(KeyShortcut("y", [.command, .shift]).display, "\u{21E7}\u{2318}Y")
        XCTAssertEqual(KeyShortcut(":", [.command]).display, "\u{2318}:")
        XCTAssertEqual(KeyShortcut(";", [.command, .shift]).display, "\u{2318}:")
        XCTAssertEqual(KeyShortcut(".", [.command, .shift]).display, "\u{2318}>")
        XCTAssertEqual(KeyShortcut("\u{1B}", [.option]).display, "\u{2325}\u{238B}")
        XCTAssertEqual(KeyShortcut("f", [.command, .control]).display, "\u{2303}\u{2318}F")
        XCTAssertEqual(KeyShortcut("1", [.command, .shift]).display, "\u{21E7}\u{2318}1")
        XCTAssertEqual(KeyShortcut.empty.display, "")
    }

    // MARK: 6. Recording key events

    private func key(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    func testRecorderReadsKeyPresses() throws {
        XCTAssertEqual(ShortcutRecorder.outcome(for: try key(53, "\u{1B}")), .cancel)
        XCTAssertEqual(ShortcutRecorder.outcome(for: try key(51, "\u{7F}")), .remove)
        XCTAssertEqual(ShortcutRecorder.outcome(for: try key(117, String(Character(UnicodeScalar(UInt32(NSDeleteFunctionKey))!)))),
                       .remove)
        // Esc with Option is a candidate (Complete's own key), not Cancel.
        XCTAssertEqual(ShortcutRecorder.outcome(for: try key(53, "\u{1B}", [.option])),
                       .candidate(KeyShortcut("\u{1B}", [.option])))
        // Shift+Cmd+Y (kVK_ANSI_Y = 16) is "y" plus Shift: the layout's base key.
        XCTAssertEqual(ShortcutRecorder.outcome(for: try key(16, "Y", [.command, .shift])),
                       .candidate(KeyShortcut("y", [.command, .shift])))
        // Caps Lock and Fn are not part of a shortcut.
        XCTAssertEqual(ShortcutRecorder.outcome(for: try key(16, "y", [.command, .capsLock, .function])),
                       .candidate(KeyShortcut("y", [.command])))
        let f5 = String(Character(UnicodeScalar(UInt32(NSF5FunctionKey))!))
        XCTAssertEqual(ShortcutRecorder.outcome(for: try key(96, f5, [.function])), .candidate(KeyShortcut(f5, [])))
        let flags = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.command, .shift],
                                                   timestamp: 0, windowNumber: 0, context: nil, characters: "",
                                                   charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56))
        XCTAssertEqual(ShortcutRecorder.outcome(for: flags), .modifiers([.command, .shift]))
    }

    // MARK: 7. The Keyboard tab (mockup A, U4)

    private func makeTab(_ menu: NSMenu) -> KeyboardTabController {
        KeyboardTabController(menuBar: { menu })
    }

    /// One flat table: 6 menu rows, 5 Edit submenu rows, 58 commands (69
    /// rows; the mockup's 70 had Open Recent > Clear Menu, which AppKit owns).
    func testTabListsEveryCommandUnderAHeaderRowPerMenu() throws {
        let tab = makeTab(MainMenu.build())
        XCTAssertEqual(tab.rows.count, 69)
        let headers = tab.rows.compactMap { row -> String? in
            switch row {
            case let .menu(title): "menu " + title
            case let .submenu(title): "sub " + title
            case .command: nil
            }
        }
        XCTAssertEqual(headers, ["menu QuickEdit", "menu File", "menu Edit", "sub Find", "sub Spelling and Grammar",
                                 "sub Substitutions", "sub Transformations", "sub Speech", "menu Format", "menu View",
                                 "menu Window"])
        let names = tab.rows.compactMap { row -> String? in
            if case let .command(command, _) = row { command.name } else { nil }
        }
        XCTAssertFalse(names.contains("Clear Menu"))
        XCTAssertEqual(tab.tableView.numberOfRows, 69)
        XCTAssertTrue(tab.tableView.delegate?.tableView?(tab.tableView, isGroupRow: 0) ?? false)
        XCTAssertFalse(tab.tableView.delegate?.tableView?(tab.tableView, shouldSelectRow: 0) ?? true)
    }

    private func shortcutButton(_ tab: KeyboardTabController, _ id: String) throws -> NSView? {
        let row = try XCTUnwrap(tab.row(of: id))
        let cell = tab.tableView.view(atColumn: 1, row: row, makeIfNecessary: true)
        return cell?.subviews.first { $0.identifier == KeyboardTabController.shortcutButtonIdentifier(id) }
    }

    func testRecordingANewShortcutSavesAndAppliesIt() throws {
        let menu = MainMenu.build()
        let tab = makeTab(menu)
        tab.startRecording("file.new")
        XCTAssertTrue(tab.isRecording)
        XCTAssertEqual(tab.messageField.stringValue, KeyboardTabController.hintText)
        XCTAssertEqual((try shortcutButton(tab, "file.new") as? NSTextField)?.stringValue, "Type shortcut")
        tab.handle(.modifiers([.command, .shift]))
        XCTAssertEqual((try shortcutButton(tab, "file.new") as? NSTextField)?.stringValue, "\u{21E7}\u{2318}")
        tab.handle(.candidate(KeyShortcut("y", [.command, .shift])))
        XCTAssertFalse(tab.isRecording)
        XCTAssertEqual(tab.messageField.stringValue, "")
        let (item, _) = try command("file.new", in: menu)
        XCTAssertEqual(KeyShortcut(of: item), KeyShortcut("y", [.command, .shift]))
        let button = try XCTUnwrap(try shortcutButton(tab, "file.new") as? NSButton)
        XCTAssertEqual(button.title, "\u{21E7}\u{2318}Y")
        XCTAssertEqual(button.accessibilityLabel(), "Shortcut for New")
        // The row says it changed, and has a reset button that names the command.
        let row = try XCTUnwrap(tab.row(of: "file.new"))
        let name = tab.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
        XCTAssertEqual(name?.textField?.stringValue, "New (changed)")
        let reset = tab.tableView.view(atColumn: 1, row: row, makeIfNecessary: true)?.subviews
            .first { $0.identifier == KeyboardTabController.resetButtonIdentifier("file.new") } as? NSButton
        XCTAssertEqual(reset?.accessibilityLabel(), "Reset New to its default shortcut")
        reset?.performClick(nil)
        XCTAssertEqual(KeyShortcut(of: item), KeyShortcut("n"))
        XCTAssertNil(saved.persisted?[Defaults.keyboardShortcutsKey])
    }

    func testClashIsRefusedAndTheMessageStays() throws {
        let menu = MainMenu.build()
        let tab = makeTab(menu)
        tab.startRecording("file.save")
        tab.handle(.candidate(KeyShortcut("o")))
        XCTAssertTrue(tab.isRecording, "recording goes on after a refusal")
        XCTAssertTrue(tab.messageField.stringValue.hasSuffix(
            "\u{2318}O is already used by \u{201C}Open\u{2026}\u{201D} in the File menu."), tab.messageField.stringValue)
        XCTAssertEqual(tab.refusal?.message,
                       "\u{2318}O is already used by \u{201C}Open\u{2026}\u{201D} in the File menu.")
        XCTAssertEqual(KeyShortcut(of: try command("file.save", in: menu).0), KeyShortcut("s"), "Save keeps its key")
        XCTAssertNil(saved.persisted?[Defaults.keyboardShortcutsKey])
        tab.handle(.cancel)
        XCTAssertFalse(tab.isRecording)
        XCTAssertEqual(tab.messageField.stringValue, "")
    }

    func testDeleteRemovesTheShortcutAndRestoreBringsItBack() throws {
        let menu = MainMenu.build()
        let tab = makeTab(menu)
        tab.startRecording("file.print")
        tab.handle(.remove)
        let (item, _) = try command("file.print", in: menu)
        XCTAssertTrue(KeyShortcut(of: item).isNone)
        tab.restoreButton.performClick(nil)
        XCTAssertEqual(KeyShortcut(of: item), KeyShortcut("p"))
        XCTAssertEqual(tab.restoreButton.title, "Restore Keyboard Defaults")
    }

    /// U4: recording and reset work from the keyboard.
    func testReturnRecordsAndDeleteResetsTheSelectedRow() throws {
        let menu = MainMenu.build()
        let tab = makeTab(menu)
        let row = try XCTUnwrap(tab.row(of: "file.save"))
        tab.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tab.tableView.keyDown(with: try key(36, "\r"))
        XCTAssertEqual(tab.recordingID, "file.save")
        tab.handle(.candidate(KeyShortcut("y", [.command, .control])))
        XCTAssertEqual(KeyShortcut(of: try command("file.save", in: menu).0), KeyShortcut("y", [.command, .control]))
        tab.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tab.tableView.keyDown(with: try key(51, "\u{7F}"))
        XCTAssertEqual(KeyShortcut(of: try command("file.save", in: menu).0), KeyShortcut("s"))
    }

    /// WCAG contrast of `color` over `background` in `appearance` (alpha blended).
    private func contrast(_ color: NSColor, on background: NSColor, _ appearance: NSAppearance.Name) -> CGFloat {
        var ratio: CGFloat = 0
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            func rgba(_ c: NSColor) -> [CGFloat] {
                let s = c.usingColorSpace(.sRGB)!
                return [s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent]
            }
            let bg = rgba(background), fg = rgba(color)
            let mixed = (0..<3).map { fg[$0] * fg[3] + bg[$0] * (1 - fg[3]) }
            func luminance(_ c: [CGFloat]) -> CGFloat {
                let l = c.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
                return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
            }
            let a = luminance(mixed), b = luminance(Array(bg[0..<3]))
            ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        return ratio
    }

    /// The Keyboard tab's own text colors pass 4.5:1 (small text) on the
    /// window background and on the table's background, light and dark.
    func testKeyboardTabColorsHaveEnoughContrast() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for background in [NSColor.windowBackgroundColor, .controlBackgroundColor] {
                for (name, color) in [("warning", KeyboardTabController.warningColor),
                                      ("dim", KeyboardTabController.dimTextColor), ("label", NSColor.labelColor)] {
                    let ratio = contrast(color, on: background, appearance)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) on \(background) in \(appearance.rawValue): \(ratio)")
                }
            }
        }
    }

    // MARK: 8. In the Settings window

    func testSettingsHasAKeyboardTabThatSizesTheWindow() throws {
        let controller = SettingsWindowController()
        controller.loadSettingsWindowIfNeeded()
        controllers.append(controller)
        let window = try XCTUnwrap(controller.window)
        let tabs = try XCTUnwrap(controller.tabView)
        XCTAssertEqual(tabs.tabViewItems.map(\.label), ["New Document", "Open and Save", "Keyboard"])
        let tab = try XCTUnwrap(controller.keyboardTab)
        let top = window.frame.maxY
        let small = window.frame.height
        tabs.selectTabViewItem(at: 2)
        // The Keyboard tab's keyboard loop: the table, Restore Keyboard
        // Defaults, the window's Restore All Defaults, the tab strip (M9
        // review row 4).
        let restoreAll = try XCTUnwrap(controller.restoreButton)
        XCTAssertTrue(tab.tableView.nextKeyView === tab.restoreButton)
        XCTAssertTrue(tab.restoreButton.nextKeyView === restoreAll)
        XCTAssertTrue(restoreAll.nextKeyView === tabs)
        XCTAssertTrue(tabs.nextKeyView === tab.tableView)
        XCTAssertGreaterThan(window.frame.height, small)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5, "the window keeps its top edge")
        XCTAssertEqual(window.contentView?.frame.width, 440)
        let keyboard = try XCTUnwrap(tabs.tabViewItems[2].view)
        for sub in keyboard.subviews {
            XCTAssertTrue(keyboard.bounds.contains(sub.frame), "\(sub) sticks out of the Keyboard tab")
        }
        tabs.selectTabViewItem(at: 0)
        XCTAssertEqual(window.frame.height, small, accuracy: 0.5)
    }

    /// Draws the Keyboard tab offscreen into build/shots/settings-keyboard*.png
    /// in the clash state of the mockup (Print… changed, Save refusing Cmd+O).
    func testRenderKeyboardTab() throws {
        let controller = SettingsWindowController()
        controller.loadSettingsWindowIfNeeded()
        controllers.append(controller)
        let window = try XCTUnwrap(controller.window)
        let tabs = try XCTUnwrap(controller.tabView)
        let tab = try XCTUnwrap(controller.keyboardTab)
        let folder = TestShots.folder // build.sh copies it to build/shots (M9 sandbox)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        tabs.selectTabViewItem(at: 2)
        let live = try XCTUnwrap(NSApp.mainMenu)
        let print = try command("file.print", in: live).1
        Shortcuts.set(KeyShortcut("p", [.command, .shift]), for: print, applyingTo: live)
        defer { Shortcuts.restoreDefaults(applyingTo: live) }
        tab.reload()
        tab.startRecording("file.save")
        tab.handle(.candidate(KeyShortcut("o")))
        for (name, appearance) in [("settings-keyboard-light", NSAppearance.Name.aqua), ("settings-keyboard", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            let frameView = try XCTUnwrap(window.contentView?.superview)
            frameView.layoutSubtreeIfNeeded()
            frameView.display()
            let rep = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: folder.appendingPathComponent("\(name).png"))
        }
        tab.endRecording()
    }
}

/// Stands in for every menu action while a key event goes through a menu.
@MainActor
private final class MenuActionSpy: NSObject {
    private(set) var ran: NSMenuItem?
    @objc func ran(_ sender: NSMenuItem) { ran = sender }
}
