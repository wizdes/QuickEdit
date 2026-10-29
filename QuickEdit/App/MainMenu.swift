import AppKit

/// The menu bar, built in code (contract `app-menu`). Titles, keys and actions
/// follow docs/codemap.md section 2 (KEEP and CHANGE rows); order and
/// separators follow reference/apple/Base.lproj/Edit.nib. Items for later
/// milestones are left out, not stubbed.
@MainActor
enum MainMenu {
    static let appName = "QuickEdit"

    static func build() -> NSMenu {
        let mainMenu = NSMenu(title: "Main Menu")
        mainMenu.addItem(submenuItem(appMenu()))
        mainMenu.addItem(submenuItem(fileMenu()))
        mainMenu.addItem(submenuItem(editMenu()))
        mainMenu.addItem(submenuItem(formatMenu()))
        let view = viewMenu()
        mainMenu.addItem(submenuItem(view))
        let window = windowMenu()
        mainMenu.addItem(submenuItem(window))
        NSApp.windowsMenu = window
        // AppKit adds its own tab items to these two menus; its duplicates
        // of QuickEdit's and Show Tab Bar go (M11, TabBarRule.swift).
        TabMenuCleaner.shared.install(on: [window, view])
        let help = NSMenu(title: "Help")
        mainMenu.addItem(submenuItem(help))
        NSApp.helpMenu = help
        // The user's custom shortcuts (U2); with none saved this only
        // reads one default.
        Shortcuts.apply(to: mainMenu)
        return mainMenu
    }

    // MARK: Menus

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: appName)
        menu.addItem(item(id: "app.about", "About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        // TextEdit's "Preferences…" under its modern name (codemap section 2).
        // The controller is a plain object; its window is built on first use.
        let settings = item(id: "app.settings", "Settings\u{2026}", #selector(NSWindowController.showWindow(_:)), ",")
        settings.target = SettingsWindowController.shared
        menu.addItem(settings)
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = submenuItem(services)
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item(id: "app.hide", "Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item(id: "app.hideOthers", "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item(id: "app.showAll", "Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item(id: "app.quit", "Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        // AppKit adds File > Share by itself (autosavesInPlace); this
        // turns it off for a document that has no file yet (P73).
        menu.delegate = ShareMenuValidator.shared
        menu.addItem(item(id: "file.new", "New", #selector(NSDocumentController.newDocument(_:)), "n"))
        // The action the tab bar's + button sends (DocumentWindowController
        // answers that). The menu item has its own target, which picks the
        // document window (M11, TabBarRule.swift).
        let newTab = item(id: "file.newTab", "New Tab", #selector(NSResponder.newWindowForTab(_:)), "t")
        newTab.target = NewTabCommand.shared
        menu.addItem(newTab)
        menu.addItem(item(id: "file.open", "Open\u{2026}", #selector(NSDocumentController.openDocument(_:)), "o"))
        let recent = NSMenu(title: "Open Recent")
        // AppKit rebuilds this menu and replaces Clear Menu with its own
        // item, so it is not one of the commands whose shortcut can change.
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                               keyEquivalent: "")
        recent.addItem(clear)
        // Edit.nib names this menu "_NSRecentDocumentsMenu". Set in code, the
        // name works without the leading underscore (with it, measured
        // 2026-10-24, AppKit still adds its own). Without
        // the name AppKit does not recognise the menu and adds a second Open
        // Recent above it (first UI test run, 2026-10-24).
        let setMenuName = NSSelectorFromString("_setMenuName:")
        if recent.responds(to: setMenuName) {
            recent.perform(setMenuName, with: "NSRecentDocumentsMenu")
        } else {
            FileHandle.standardError.write(Data("QuickEdit: NSMenu has no _setMenuName:; File > Open Recent will appear twice\n".utf8))
        }
        menu.addItem(submenuItem(recent))
        menu.addItem(.separator())
        // The title is "Close Tab" while the window has two or more tabs
        // (ShareMenuValidator.menuNeedsUpdate).
        menu.addItem(item(id: "file.close", "Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item(id: "file.save", "Save", #selector(NSDocument.save(_:)), "s"))
        menu.addItem(item(id: "file.duplicate", "Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]))
        // Hold Option over Duplicate to get Save As…, as in TextEdit on macOS 27.
        let saveAs = item(id: "file.saveAs", "Save As\u{2026}", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift, .option],
                          alternateOf: "file.duplicate")
        saveAs.isAlternate = true
        menu.addItem(saveAs)
        menu.addItem(item(id: "file.rename", "Rename\u{2026}", #selector(NSDocument.rename(_:))))
        menu.addItem(item(id: "file.moveTo", "Move To\u{2026}", #selector(NSDocument.move(_:))))
        // TextEdit 1.9 has Save All (Edit.nib, after Save As…); it stays.
        menu.addItem(item(id: "file.saveAll", "Save All", #selector(NSDocumentController.saveAllDocuments(_:))))
        // With autosavesInPlace, AppKit turns this item into the "Revert To" submenu.
        menu.addItem(item(id: "file.revert", "Revert to Saved", #selector(NSDocument.revertToSaved(_:))))
        // User decision U1: no real printing. Both items show a Save panel
        // for a PDF (TextDocument). Print… has its own action, and
        // TextDocument sends printDocument: (Finder, scripts) to the same
        // panel, so nothing reaches the system Print panel. Show
        // Properties and Page Setup… are left out (Edit.nib:315-363).
        menu.addItem(.separator())
        menu.addItem(item(id: "file.exportPDF", "Export as PDF\u{2026}", #selector(NSDocument.saveToPDF(_:))))
        menu.addItem(.separator())
        menu.addItem(item(id: "file.print", "Print\u{2026}", #selector(TextDocument.printToPDF(_:)), "p"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item(id: "edit.undo", "Undo", Selector(("undo:")), "z"))
        menu.addItem(item(id: "edit.redo", "Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(id: "edit.cut", "Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item(id: "edit.copy", "Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item(id: "edit.paste", "Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item(id: "edit.delete", "Delete", #selector(NSText.delete(_:))))
        // Option-Escape, as in the nib (key equivalent U+001B with the Option mask).
        menu.addItem(item(id: "edit.complete", "Complete", #selector(NSTextView.complete(_:)), "\u{1B}", [.option]))
        menu.addItem(item(id: "edit.selectAll", "Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(submenuItem(findMenu()))
        menu.addItem(submenuItem(spellingMenu()))
        menu.addItem(submenuItem(substitutionsMenu()))
        menu.addItem(submenuItem(transformationsMenu()))
        menu.addItem(submenuItem(speechMenu()))
        return menu
    }

    private static func findMenu() -> NSMenu {
        let menu = NSMenu(title: "Find")
        let finder = #selector(NSTextView.performTextFinderAction(_:))
        menu.addItem(item(id: "find.find", "Find\u{2026}", finder, "f", tag: NSTextFinder.Action.showFindInterface.rawValue))
        menu.addItem(item(id: "find.replace", "Find and Replace\u{2026}", finder, "f", [.command, .option],
                          tag: NSTextFinder.Action.showReplaceInterface.rawValue))
        menu.addItem(item(id: "find.next", "Find Next", finder, "g", tag: NSTextFinder.Action.nextMatch.rawValue))
        menu.addItem(item(id: "find.previous", "Find Previous", finder, "g", [.command, .shift],
                          tag: NSTextFinder.Action.previousMatch.rawValue))
        menu.addItem(item(id: "find.useSelection", "Use Selection for Find", finder, "e", tag: NSTextFinder.Action.setSearchString.rawValue))
        menu.addItem(item(id: "find.jump", "Jump to Selection", #selector(NSTextView.centerSelectionInVisibleArea(_:)), "j"))
        // TextEdit's title has three periods, not an ellipsis (Edit.nib line 641,
        // and macOS 27's TextEdit). The panel is built when first shown.
        let selectLine = item(id: "find.selectLine", "Select Line...", #selector(NSWindowController.showWindow(_:)), "l")
        selectLine.target = LinePanelController.shared
        menu.addItem(selectLine)
        return menu
    }

    private static func spellingMenu() -> NSMenu {
        let menu = NSMenu(title: "Spelling and Grammar")
        menu.addItem(item(id: "spelling.show", "Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"))
        menu.addItem(item(id: "spelling.checkNow", "Check Document Now", #selector(NSText.checkSpelling(_:)), ";"))
        menu.addItem(.separator())
        menu.addItem(item(id: "spelling.whileTyping", "Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))))
        menu.addItem(item(id: "spelling.grammar", "Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:))))
        menu.addItem(item(id: "spelling.correct", "Correct Spelling Automatically",
                          #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))))
        return menu
    }

    private static func substitutionsMenu() -> NSMenu {
        let menu = NSMenu(title: "Substitutions")
        menu.addItem(item(id: "substitutions.show", "Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item(id: "substitutions.smartCopyPaste", "Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:))))
        menu.addItem(item(id: "substitutions.smartQuotes", "Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))))
        menu.addItem(item(id: "substitutions.smartDashes", "Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))))
        // Kept: on a plain TextKit 1 view it marks dates, addresses and phone
        // numbers (NSDataDetection temporary attributes) and writes nothing to
        // the text (EditActionsTests.testDataDetectorsMarksTextWithoutChangingIt).
        menu.addItem(item(id: "substitutions.dataDetectors", "Data Detectors", #selector(NSTextView.toggleAutomaticDataDetection(_:))))
        menu.addItem(item(id: "substitutions.textReplacement", "Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:))))
        return menu
    }

    private static func transformationsMenu() -> NSMenu {
        let menu = NSMenu(title: "Transformations")
        menu.addItem(item(id: "transformations.upper", "Make Upper Case", #selector(NSResponder.uppercaseWord(_:))))
        menu.addItem(item(id: "transformations.lower", "Make Lower Case", #selector(NSResponder.lowercaseWord(_:))))
        menu.addItem(item(id: "transformations.capitalize", "Capitalize", #selector(NSResponder.capitalizeWord(_:))))
        return menu
    }

    private static func speechMenu() -> NSMenu {
        let menu = NSMenu(title: "Speech")
        menu.addItem(item(id: "speech.start", "Start Speaking", #selector(NSTextView.startSpeaking(_:))))
        menu.addItem(item(id: "speech.stop", "Stop Speaking", #selector(NSTextView.stopSpeaking(_:))))
        return menu
    }

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        menu.addItem(item(id: "format.preventEditing", "Prevent Editing", #selector(TextDocument.toggleReadOnly(_:))))
        // The title flips to "Wrap to Window" in TextDocument.validateMenuItem.
        menu.addItem(item(id: "format.wrapToPage", "Wrap to Page", #selector(TextDocument.togglePageBreaks(_:)), "w", [.command, .shift]))
        return menu
    }

    /// Zoom, handled by the window's ScalingScrollView through the responder
    /// chain. Keys (1.2.2, user request): Cmd+= in, Cmd+- out, Cmd+. back
    /// to 100%. Zoom In is "=", not "+": a "+" item fires only with Shift.
    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item(id: "view.actualSize", "Actual Size", #selector(ScalingScrollView.zoomToActualSize(_:)), "."))
        menu.addItem(item(id: "view.zoomIn", "Zoom In", #selector(ScalingScrollView.zoomIn(_:)), "="))
        menu.addItem(item(id: "view.zoomOut", "Zoom Out", #selector(ScalingScrollView.zoomOut(_:)), "-"))
        // The gutter and the map (1.2.0): app-wide settings, shown as a
        // check mark (ViewOptionsCommand).
        menu.addItem(.separator())
        for (id, title, action) in [("view.lineNumbers", "Show Line Numbers", #selector(ViewOptionsCommand.toggleLineNumbers(_:))),
                                    ("view.documentMap", "Show Document Map", #selector(ViewOptionsCommand.toggleDocumentMap(_:)))] {
            let toggle = item(id: id, title, action)
            toggle.target = ViewOptionsCommand.shared
            menu.addItem(toggle)
        }
        // AppKit's own full-screen item has no Ctrl+Cmd+F on macOS 27
        // (measured 2026-10-24), while TextEdit's key works. With this item
        // in the menu AppKit adds no second one.
        menu.addItem(.separator())
        menu.addItem(item(id: "view.fullScreen", "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item(id: "window.minimize", "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item(id: "window.zoom", "Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        // QuickEdit's own tab items, so their keys can change in Settings >
        // Keyboard. NSWindow handles them and turns them off with one tab.
        // AppKit adds Move Tab to New Window and Merge All Windows after them.
        menu.addItem(item(id: "window.previousTab", "Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t",
                          [.control, .shift]))
        menu.addItem(item(id: "window.nextTab", "Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", [.control]))
        menu.addItem(.separator())
        // Tab 1 … Tab 9 on Cmd+1 … Cmd+9 and Last Tab on Cmd+0 (1.2.2, user
        // request; 1.2.0 used Ctrl). The tag is the tab number (lastTabTag:
        // the last tab); TabNumberCommand selects it and turns the item off
        // when there is no such tab.
        for number in [Int](1...9) + [TabNumberCommand.lastTabTag] {
            let last = number == TabNumberCommand.lastTabTag
            let tabItem = item(id: last ? "window.lastTab" : "window.tab\(number)", last ? "Last Tab" : "Tab \(number)",
                               #selector(TabNumberCommand.selectTabByNumber(_:)), last ? "0" : "\(number)", tag: number)
            tabItem.target = TabNumberCommand.shared
            menu.addItem(tabItem)
        }
        menu.addItem(.separator())
        menu.addItem(item(id: "window.bringAllToFront", "Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    // MARK: Helpers

    /// A QuickEdit command. `id` is the stable name its custom shortcut is
    /// saved under (Shortcuts.swift); `name` is the Keyboard tab's name for
    /// it when that is not the title. Never rename an id: saved shortcuts
    /// would be lost.
    private static func item(id: String, _ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0,
                             name: String? = nil, alternateOf: String? = nil) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { menuItem.keyEquivalentModifierMask = modifiers }
        menuItem.tag = tag
        menuItem.representedObject = MenuCommand(id: id, name: name ?? title,
                                                 defaultShortcut: KeyShortcut(key, key.isEmpty ? [] : modifiers),
                                                 alternateOf: alternateOf)
        return menuItem
    }

    private static func submenuItem(_ submenu: NSMenu) -> NSMenuItem {
        let menuItem = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        menuItem.submenu = submenu
        return menuItem
    }
}

/// The File menu's delegate. It also sets Close's title: "Close Tab"
/// while the window Cmd+W would close has two or more tabs (M11).
///
/// File > Share (P73). AppKit inserts the Share submenu into the File menu
/// by itself, built from NSSharingService for the current document's file
/// (NSDocumentController.allowsAutomaticShareMenu). It is turned off here
/// while the front document has never been saved: TextEdit would show a
/// Save panel first, but QuickEdit shares only a file that exists.
@MainActor
final class ShareMenuValidator: NSObject, NSMenuDelegate {
    static let shared = ShareMenuValidator()
    static let shareTitle = "Share"

    /// The Share item AppKit put into `menu`, if any: a submenu that is not
    /// one of QuickEdit's own (Open Recent).
    static func shareItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == shareTitle && $0.submenu != nil }
    }

    /// True when `document` has a file to share.
    static func canShare(_ document: NSDocument?) -> Bool { document?.fileURL != nil }

    /// The window in front, whose document Share would send. AppKit's main
    /// window; tests replace it, because a unit-test host is not the
    /// active app and has no main window (as LinePanelController does).
    var frontWindow: @MainActor () -> NSWindow? = { NSApp.mainWindow }

    /// The front window's document (NSDocumentController.currentDocument
    /// is the main window's document too).
    var frontDocument: NSDocument? {
        frontWindow().flatMap { NSDocumentController.shared.document(for: $0) }
    }

    /// The window Close would close; tests replace it, as `frontWindow`.
    var closeTarget: @MainActor () -> NSWindow? = { TabCommands.closeTarget() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        Self.shareItem(in: menu)?.isEnabled = Self.canShare(frontDocument)
        let close = menu.items.first { ($0.representedObject as? MenuCommand)?.id == "file.close" }
        close?.title = TabCommands.closeTitle(for: closeTarget())
    }
}

/// View > Show Line Numbers and Show Document Map (1.2.0). Each flips its
/// setting (Defaults.showLineNumbersKey, showDocumentMapKey) and every
/// open document window follows at once. The check mark shows the setting.
@MainActor
final class ViewOptionsCommand: NSObject, NSMenuItemValidation {
    static let shared = ViewOptionsCommand()

    @objc func toggleLineNumbers(_ sender: Any?) { flip(Defaults.showLineNumbersKey) }

    @objc func toggleDocumentMap(_ sender: Any?) { flip(Defaults.showDocumentMapKey) }

    private func flip(_ key: String) {
        Defaults.store.set(!Defaults.store.bool(forKey: key), forKey: key)
        Self.updateWindows()
    }

    /// Every document window shows or hides its gutter and map again.
    static func updateWindows() {
        for window in NSApp.windows {
            (window.windowController as? DocumentWindowController)?.updateGutterAndMap()
        }
    }

    /// Every document window sets Writing Tools and predictive text from
    /// Settings again (1.2.1).
    static func updateWritingTools() {
        for window in NSApp.windows {
            (window.windowController as? DocumentWindowController)?.applyWritingTools()
        }
    }

    /// The check mark shows the setting. Both items are off while the
    /// document window in front holds a large file, which never shows the
    /// gutter or the map.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleLineNumbers(_:)):
            menuItem.state = Defaults.store.bool(forKey: Defaults.showLineNumbersKey) ? .on : .off
        case #selector(toggleDocumentMap(_:)):
            menuItem.state = Defaults.store.bool(forKey: Defaults.showDocumentMapKey) ? .on : .off
        default:
            return true
        }
        let front = [NSApp.mainWindow].compactMap { $0 }.first { $0.windowController is DocumentWindowController }
            ?? TabCommands.frontDocumentWindow()
        let document = (front?.windowController as? DocumentWindowController)?.document as? TextDocument
        return document?.isLargeFile != true
    }
}
