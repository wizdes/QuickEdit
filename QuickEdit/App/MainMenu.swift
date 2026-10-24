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
        let window = windowMenu()
        mainMenu.addItem(submenuItem(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        mainMenu.addItem(submenuItem(help))
        NSApp.helpMenu = help
        return mainMenu
    }

    // MARK: Menus

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: appName)
        menu.addItem(item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = submenuItem(services)
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New", #selector(NSDocumentController.newDocument(_:)), "n"))
        menu.addItem(item("Open\u{2026}", #selector(NSDocumentController.openDocument(_:)), "o"))
        let recent = NSMenu(title: "Open Recent")
        recent.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        menu.addItem(submenuItem(recent))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Save", #selector(NSDocument.save(_:)), "s"))
        menu.addItem(item("Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]))
        // Hold Option over Duplicate to get Save As…, as in TextEdit on macOS 27.
        let saveAs = item("Save As\u{2026}", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift, .option])
        saveAs.isAlternate = true
        menu.addItem(saveAs)
        menu.addItem(item("Rename\u{2026}", #selector(NSDocument.rename(_:))))
        menu.addItem(item("Move To\u{2026}", #selector(NSDocument.move(_:))))
        // TextEdit 1.9 has Save All (Edit.nib, after Save As…); it stays.
        menu.addItem(item("Save All", #selector(NSDocumentController.saveAllDocuments(_:))))
        // With autosavesInPlace, AppKit turns this item into the "Revert To" submenu.
        menu.addItem(item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        // Option-Escape, as in the nib (key equivalent U+001B with the Option mask).
        menu.addItem(item("Complete", #selector(NSTextView.complete(_:)), "\u{1B}", [.option]))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
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
        menu.addItem(item("Find\u{2026}", finder, "f", tag: NSTextFinder.Action.showFindInterface.rawValue))
        menu.addItem(item("Find and Replace\u{2026}", finder, "f", [.command, .option],
                          tag: NSTextFinder.Action.showReplaceInterface.rawValue))
        menu.addItem(item("Find Next", finder, "g", tag: NSTextFinder.Action.nextMatch.rawValue))
        menu.addItem(item("Find Previous", finder, "g", [.command, .shift],
                          tag: NSTextFinder.Action.previousMatch.rawValue))
        menu.addItem(item("Use Selection for Find", finder, "e", tag: NSTextFinder.Action.setSearchString.rawValue))
        menu.addItem(item("Jump to Selection", #selector(NSTextView.centerSelectionInVisibleArea(_:)), "j"))
        // TextEdit's title has three periods, not an ellipsis (Edit.nib line 641,
        // and macOS 27's TextEdit). The panel is built when first shown.
        let selectLine = item("Select Line...", #selector(NSWindowController.showWindow(_:)), "l")
        selectLine.target = LinePanelController.shared
        menu.addItem(selectLine)
        return menu
    }

    private static func spellingMenu() -> NSMenu {
        let menu = NSMenu(title: "Spelling and Grammar")
        menu.addItem(item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"))
        menu.addItem(item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"))
        menu.addItem(.separator())
        menu.addItem(item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))))
        menu.addItem(item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:))))
        menu.addItem(item("Correct Spelling Automatically",
                          #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))))
        return menu
    }

    private static func substitutionsMenu() -> NSMenu {
        let menu = NSMenu(title: "Substitutions")
        menu.addItem(item("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:))))
        menu.addItem(item("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))))
        menu.addItem(item("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))))
        // Kept: on a plain TextKit 1 view it marks dates, addresses and phone
        // numbers (NSDataDetection temporary attributes) and writes nothing to
        // the text (EditActionsTests.testDataDetectorsMarksTextWithoutChangingIt).
        menu.addItem(item("Data Detectors", #selector(NSTextView.toggleAutomaticDataDetection(_:))))
        menu.addItem(item("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:))))
        return menu
    }

    private static func transformationsMenu() -> NSMenu {
        let menu = NSMenu(title: "Transformations")
        menu.addItem(item("Make Upper Case", #selector(NSResponder.uppercaseWord(_:))))
        menu.addItem(item("Make Lower Case", #selector(NSResponder.lowercaseWord(_:))))
        menu.addItem(item("Capitalize", #selector(NSResponder.capitalizeWord(_:))))
        return menu
    }

    private static func speechMenu() -> NSMenu {
        let menu = NSMenu(title: "Speech")
        menu.addItem(item("Start Speaking", #selector(NSTextView.startSpeaking(_:))))
        menu.addItem(item("Stop Speaking", #selector(NSTextView.stopSpeaking(_:))))
        return menu
    }

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        menu.addItem(item("Prevent Editing", #selector(TextDocument.toggleReadOnly(_:))))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    // MARK: Helpers

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { menuItem.keyEquivalentModifierMask = modifiers }
        menuItem.tag = tag
        return menuItem
    }

    private static func submenuItem(_ submenu: NSMenu) -> NSMenuItem {
        let menuItem = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        menuItem.submenu = submenu
        return menuItem
    }
}
