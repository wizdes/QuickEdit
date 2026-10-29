import AppKit
import XCTest
@testable import QuickEdit

/// M11 (docs/plans/M11.md): window tabs. New Tab (Cmd+T), Close Tab
/// (Cmd+W), Show Next Tab (Ctrl+Tab) and Show Previous Tab
/// (Ctrl+Shift+Tab); the tab bar shows at 2 or more tabs and hides at 1.
/// Every test uses its own settings suite (SavedSettings) and closes the
/// documents it made.
@MainActor
final class TabTests: XCTestCase {
    private var saved: SavedSettings!
    private var before: [NSDocument] = []
    private var settingsControllers: [SettingsWindowController] = []
    private var savedCloseTarget: (@MainActor () -> NSWindow?)?

    override func setUp() async throws {
        saved = SavedSettings()
        before = NSDocumentController.shared.documents
        savedCloseTarget = ShareMenuValidator.shared.closeTarget
    }

    override func tearDown() async throws {
        if let savedCloseTarget { ShareMenuValidator.shared.closeTarget = savedCloseTarget }
        for controller in settingsControllers { controller.window?.close() }
        settingsControllers = []
        for document in NSDocumentController.shared.documents where !before.contains(where: { $0 === document }) {
            for controller in document.windowControllers {
                if let window = controller.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
            }
            document.close()
        }
        saved.restore()
    }

    // MARK: Helpers

    /// A new untitled document with its window ordered in, holding `text`.
    private func shownDocument(_ text: String = "") throws -> (TextDocument, NSWindow) {
        let document = try XCTUnwrap(try NSDocumentController.shared.openUntitledDocumentAndDisplay(false) as? TextDocument)
        document.makeWindowControllers()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        window.orderFront(nil)
        if !text.isEmpty {
            document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        }
        return (document, window)
    }

    private func controller(_ window: NSWindow) throws -> DocumentWindowController {
        try XCTUnwrap(window.windowController as? DocumentWindowController)
    }

    private func text(_ window: NSWindow) -> String {
        ((window.windowController as? DocumentWindowController)?.document as? TextDocument)?.textStorage.string ?? ""
    }

    /// Lets queued main-thread work run (the tab bar rule's pass, the menu
    /// clean-up), a few turns of the run loop.
    private func drain() {
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// Runs the run loop until `condition` holds or `timeout` passes.
    private func wait(_ timeout: TimeInterval = 2, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func command(_ id: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(Shortcuts.commandItems(in: menu).first { $0.command.id == id }?.item, "no command \(id)")
    }

    private func items(_ action: Selector, in menu: NSMenu) -> [NSMenuItem] {
        var found: [NSMenuItem] = []
        for item in menu.items {
            if item.action == action { found.append(item) }
            if let submenu = item.submenu { found += items(action, in: submenu) }
        }
        return found
    }

    private func menu(_ title: String, in bar: NSMenu) throws -> NSMenu {
        try XCTUnwrap(bar.item(withTitle: title)?.submenu, "no \(title) menu")
    }

    private func newTabItem() -> NSMenuItem {
        NSMenuItem(title: "New Tab", action: #selector(NSResponder.newWindowForTab(_:)), keyEquivalent: "t")
    }

    // MARK: 1. The commands

    /// File > New Tab (Cmd+T) after New, targeting NewTabCommand; Window >
    /// Show Previous Tab (Ctrl+Shift+Tab) and Show Next Tab (Ctrl+Tab) with
    /// a nil target, so the key window handles them.
    func testTabCommandsAreMenuItemsWithTheirKeys() throws {
        let bar = MainMenu.build()
        let file = try menu("File", in: bar)
        let newTab = try command("file.newTab", in: bar)
        XCTAssertEqual(newTab.title, "New Tab")
        XCTAssertEqual(newTab.action, #selector(NSResponder.newWindowForTab(_:)))
        XCTAssertEqual(KeyShortcut(of: newTab), KeyShortcut("t", [.command]))
        XCTAssertTrue(newTab.target === NewTabCommand.shared)
        XCTAssertEqual(file.index(of: newTab), file.indexOfItem(withTitle: "New") + 1, "New Tab comes right after New")

        let previous = try command("window.previousTab", in: bar)
        XCTAssertEqual(previous.title, "Show Previous Tab")
        XCTAssertEqual(previous.action, #selector(NSWindow.selectPreviousTab(_:)))
        XCTAssertEqual(KeyShortcut(of: previous), KeyShortcut("\t", [.control, .shift]))
        XCTAssertNil(previous.target)
        let next = try command("window.nextTab", in: bar)
        XCTAssertEqual(next.title, "Show Next Tab")
        XCTAssertEqual(next.action, #selector(NSWindow.selectNextTab(_:)))
        XCTAssertEqual(KeyShortcut(of: next), KeyShortcut("\t", [.control]))
        XCTAssertNil(next.target)

        let window = try menu("Window", in: bar)
        // AppKit lists the open windows after Bring All to Front.
        // 1.2.0 added Tab 1 … Tab 8 and Last Tab, 1.2.2 Tab 9 (TabNumberTests).
        XCTAssertEqual(window.items.prefix(18).map { $0.isSeparatorItem ? "-" : $0.title },
                       ["Minimize", "Zoom", "-", "Show Previous Tab", "Show Next Tab", "-"]
                        + (1...9).map { "Tab \($0)" } + ["Last Tab", "-", "Bring All to Front"])
        // Close stays the one Cmd+W command.
        let close = try command("file.close", in: bar)
        XCTAssertEqual(close.action, #selector(NSWindow.performClose(_:)))
        XCTAssertEqual(KeyShortcut(of: close), KeyShortcut("w"))
    }

    // MARK: 2. One item per tab action, no Show Tab Bar

    /// AppKit adds its own tab items to the Window and View menus. The ones
    /// QuickEdit has (next, previous) and Show Tab Bar go, matched by
    /// action; Merge All Windows, Move Tab to New Window and Show All Tabs
    /// stay. Removed on the next run loop turn after AppKit adds them, and
    /// at once when the menu is about to show.
    func testAppKitsDuplicateTabItemsAndShowTabBarAreRemoved() throws {
        let bar = MainMenu.build()
        let window = try menu("Window", in: bar)
        let view = try menu("View", in: bar)
        func foreign(_ title: String, _ action: Selector, _ key: String = "",
                     _ modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        window.insertItem(foreign("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", [.control, .shift]), at: 3)
        window.insertItem(foreign("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", [.control]), at: 4)
        window.insertItem(foreign("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:))), at: 5)
        window.insertItem(foreign("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:))), at: 6)
        view.addItem(foreign("Show Tab Bar", #selector(NSWindow.toggleTabBar(_:))))
        view.addItem(foreign("Show All Tabs", #selector(NSWindow.toggleTabOverview(_:))))
        drain()

        for action in [#selector(NSWindow.selectNextTab(_:)), #selector(NSWindow.selectPreviousTab(_:))] {
            let found = items(action, in: bar)
            XCTAssertEqual(found.count, 1, NSStringFromSelector(action))
            XCTAssertTrue(found.first?.representedObject is MenuCommand, "QuickEdit's own item stays")
        }
        XCTAssertEqual(items(#selector(NSWindow.toggleTabBar(_:)), in: bar).count, 0)
        XCTAssertEqual(items(#selector(NSWindow.toggleTabOverview(_:)), in: bar).count, 1)
        XCTAssertEqual(items(#selector(NSWindow.mergeAllWindows(_:)), in: bar).count, 1)
        XCTAssertEqual(items(#selector(NSWindow.moveTabToNewWindow(_:)), in: bar).count, 1)

        // Added and shown in the same turn: the menu cleans itself first.
        view.addItem(foreign("Hide Tab Bar", #selector(NSWindow.toggleTabBar(_:))))
        view.delegate?.menuNeedsUpdate?(view)
        XCTAssertEqual(items(#selector(NSWindow.toggleTabBar(_:)), in: view).count, 0)
        window.addItem(foreign("Show Next Tab", #selector(NSWindow.selectNextTab(_:))))
        window.delegate?.menuNeedsUpdate?(window)
        XCTAssertEqual(items(#selector(NSWindow.selectNextTab(_:)), in: window).count, 1)
    }

    /// The app's live menu bar, once a window has two tabs and AppKit has
    /// filled its menus: still one item per tab action, no Show Tab Bar.
    func testLiveMenuBarHasOneItemPerTabAction() throws {
        let (_, first) = try shownDocument("one")
        try controller(first).newWindowForTab(nil)
        drain()
        let live = try XCTUnwrap(NSApp.mainMenu)
        for title in ["Window", "View"] {
            let submenu = try menu(title, in: live)
            submenu.delegate?.menuNeedsUpdate?(submenu)
            submenu.update()
        }
        XCTAssertEqual(items(#selector(NSWindow.selectNextTab(_:)), in: live).count, 1)
        XCTAssertEqual(items(#selector(NSWindow.selectPreviousTab(_:)), in: live).count, 1)
        XCTAssertEqual(items(#selector(NSResponder.newWindowForTab(_:)), in: live).count, 1)
        XCTAssertEqual(items(#selector(NSWindow.toggleTabBar(_:)), in: live).count, 0)
    }

    // MARK: 3. New Tab

    /// New Tab adds a new untitled document as a tab of the window it was
    /// sent to, selects it, and leaves the first tab's text alone. Three
    /// tabs have three different Untitled names.
    func testNewTabAddsAnUntitledTabToTheWindow() throws {
        let (firstDocument, first) = try shownDocument("one")
        let count = NSDocumentController.shared.documents.count
        try controller(first).newWindowForTab(nil)
        XCTAssertEqual(NSDocumentController.shared.documents.count, count + 1)
        let group = try XCTUnwrap(first.tabGroup)
        XCTAssertEqual(group.windows.count, 2)
        let second = try XCTUnwrap(group.windows.last)
        XCTAssertFalse(second === first)
        XCTAssertTrue(group.selectedWindow === second, "the new tab is selected")
        let secondDocument = try XCTUnwrap((second.windowController as? DocumentWindowController)?.document as? TextDocument)
        XCTAssertNil(secondDocument.fileURL)
        XCTAssertEqual(secondDocument.textStorage.length, 0)
        XCTAssertFalse(secondDocument === firstDocument)
        XCTAssertEqual(firstDocument.textStorage.string, "one")

        try controller(second).newWindowForTab(nil)
        XCTAssertEqual(group.windows.count, 3)
        let names = group.windows.compactMap { ($0.windowController as? DocumentWindowController)?.document?.displayName }
        XCTAssertEqual(Set(names).count, 3, "\(names)")
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("Untitled") }, "\(names)")
        wait { group.isTabBarVisible }
        XCTAssertTrue(group.isTabBarVisible, "three tabs show the tab bar")
    }

    /// 1.2.0 change 5: New Tab shows no frame of the old tab. Each change
    /// of the tab group during New Tab is recorded: the new window's text
    /// view must already take keys when it joins;
    /// with one tab (no bar yet) the join and the selection happen with
    /// animations off (CATransaction actions off, NSAnimationContext
    /// duration 0), so the bar comes up with the new tab already selected;
    /// and the new tab ends selected. (Kelpi 571ac9f.)
    func testNewTabJoinsFinishedAndWithoutAnimationFromOneTab() throws {
        func record(from first: NSWindow) throws -> ([NewTabRecorder.Step], NSWindow?) {
            let recorder = NewTabRecorder(group: try XCTUnwrap(first.tabGroup))
            TabCommands.openNewTab(in: first)
            return (recorder.finish(), recorder.added)
        }

        let (_, first) = try shownDocument("one")
        drain()
        let (steps, added) = try record(from: first)
        let summary = steps.map { "\($0.kind) actionsOff=\($0.actionsOff) duration=\($0.duration) finished=\($0.finished)" }
        print("NEWTAB-STEPS one tab: \(summary)")
        XCTAssertFalse(steps.isEmpty, "the tab group reported no change")
        let newTab = try XCTUnwrap(added, "no new tab")
        XCTAssertTrue(first.tabGroup?.selectedWindow === newTab, "the new tab is selected")
        for (index, step) in steps.enumerated() {
            XCTAssertTrue(step.actionsOff, "one tab: change \(index) (\(step.kind)) ran with animations on: \(summary)")
            XCTAssertEqual(step.duration, 0, "one tab: change \(index) (\(step.kind)) had an animation time: \(summary)")
            XCTAssertTrue(step.finished, "change \(index) (\(step.kind)): the new window joined unfinished: \(summary)")
        }

        // From two tabs the bar is up: the tab's own animation may run,
        // but the new window still joins finished and ends selected.
        drain()
        let (moreSteps, third) = try record(from: newTab)
        let moreSummary = moreSteps.map { "\($0.kind) finished=\($0.finished)" }
        print("NEWTAB-STEPS two tabs: \(moreSummary)")
        let thirdTab = try XCTUnwrap(third, "no third tab")
        XCTAssertTrue(first.tabGroup?.selectedWindow === thirdTab)
        XCTAssertEqual(first.tabGroup?.windows.count, 3)
        for step in moreSteps { XCTAssertTrue(step.finished, "two tabs: the new window joined unfinished: \(moreSummary)") }
    }

    /// A read-only document still takes a new tab; the new document gets
    /// fresh settings, not the read-only state.
    func testReadOnlyDocumentStillTakesANewTab() throws {
        let (document, first) = try shownDocument("locked")
        document.toggleReadOnly(nil)
        XCTAssertTrue(document.preventsEditing)
        XCTAssertTrue(TabCommands.canAddTab(to: first))
        try controller(first).newWindowForTab(nil)
        let second = try XCTUnwrap(first.tabGroup?.windows.last)
        let secondDocument = try XCTUnwrap((second.windowController as? DocumentWindowController)?.document as? TextDocument)
        XCTAssertFalse(secondDocument.preventsEditing)
    }

    /// New Tab is off while the window shows a sheet, and the + button's
    /// action adds nothing then.
    func testNewTabIsOffWhileASheetIsOpen() throws {
        let (_, first) = try shownDocument()
        first.orderFront(nil)
        let item = newTabItem()
        XCTAssertTrue(TabCommands.newTabWindow() === first)
        XCTAssertTrue(NewTabCommand.shared.validateMenuItem(item))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: true)
        first.beginSheet(sheet)
        XCTAssertNotNil(first.attachedSheet)
        XCTAssertFalse(NewTabCommand.shared.validateMenuItem(item), "New Tab must be off under a sheet")
        try controller(first).newWindowForTab(nil)
        XCTAssertNil(first.tabbedWindows, "the + button's action added a tab under a sheet")
        first.endSheet(sheet)
        XCTAssertTrue(NewTabCommand.shared.validateMenuItem(item))
    }

    /// A Save panel runs in another process in the sandbox, so the window
    /// has no attached sheet under it; the document says the panel is open,
    /// and New Tab is off until the panel ends.
    func testNewTabIsOffWhileASavePanelIsOpen() throws {
        let (document, first) = try shownDocument("unsaved")
        first.orderFront(nil)
        let item = newTabItem()
        XCTAssertFalse(document.isShowingSavePanel)
        document.beginSavePanelSession()
        _ = document.prepareSavePanel(NSSavePanel())
        XCTAssertTrue(document.isShowingSavePanel)
        XCTAssertNil(first.attachedSheet)
        XCTAssertFalse(TabCommands.canAddTab(to: first))
        XCTAssertFalse(NewTabCommand.shared.validateMenuItem(item), "New Tab must be off under a Save panel")
        NewTabCommand.shared.newWindowForTab(nil)
        XCTAssertNil(first.tabbedWindows, "New Tab added a tab under a Save panel")
        document.endSavePanelSession()
        XCTAssertFalse(document.isShowingSavePanel)
        XCTAssertTrue(NewTabCommand.shared.validateMenuItem(item))
    }

    /// From Settings, New Tab goes to the front document window; Settings
    /// itself never takes tabs.
    func testNewTabFromSettingsGoesToTheFrontDocumentWindow() throws {
        let (_, first) = try shownDocument("front")
        first.orderFront(nil)
        let settings = SettingsWindowController()
        settingsControllers.append(settings)
        let settingsWindow = settings.loadSettingsWindowIfNeeded()
        XCTAssertEqual(settingsWindow.tabbingMode, .disallowed)
        settingsWindow.orderFront(nil)
        XCTAssertTrue(TabCommands.frontDocumentWindow() === first)
        XCTAssertTrue(TabCommands.newTabWindow() === first)
        XCTAssertTrue(NewTabCommand.shared.validateMenuItem(newTabItem()))
        NewTabCommand.shared.newWindowForTab(nil)
        XCTAssertEqual(first.tabGroup?.windows.count, 2)
        XCTAssertNil(settingsWindow.tabbedWindows, "Settings has no tabs")

        // A sheet on that document window turns it off from Settings too.
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: true)
        let front = try XCTUnwrap(TabCommands.frontDocumentWindow())
        front.beginSheet(sheet)
        XCTAssertFalse(NewTabCommand.shared.validateMenuItem(newTabItem()))
        front.endSheet(sheet)
    }

    /// With no document window to add to, New Tab makes a normal window.
    func testNewTabWithNoWindowMakesANormalWindow() throws {
        let count = NSDocumentController.shared.documents.count
        TabCommands.openNewTab(in: nil)
        XCTAssertEqual(NSDocumentController.shared.documents.count, count + 1)
        let document = try XCTUnwrap(NSDocumentController.shared.documents.last)
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertLessThanOrEqual(window.tabGroup?.windows.count ?? 1, 1)
    }

    /// Design item 7: a large file's title note stays in the window title
    /// and in its tab once the window is a tab of another window.
    func testLargeFileTitleNoteShowsInATab() throws {
        let savedThreshold = TextDocument.largeFileThreshold
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qe-tab-large-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            TextDocument.largeFileThreshold = savedThreshold
            try? FileManager.default.removeItem(at: folder)
        }
        TextDocument.largeFileThreshold = 1_000
        let url = folder.appendingPathComponent("big.txt")
        try Data(String(repeating: "large file line\n", count: 100).utf8).write(to: url)
        let large = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        NSDocumentController.shared.addDocument(large)
        large.makeWindowControllers()
        XCTAssertTrue(large.isLargeFile)
        let largeWindow = try XCTUnwrap(large.windowControllers.first?.window)

        let (_, first) = try shownDocument("small")
        first.addTabbedWindow(largeWindow, ordered: .above)
        largeWindow.tabGroup?.selectedWindow = largeWindow
        wait { first.tabGroup?.windows.count == 2 }
        XCTAssertEqual(first.tabGroup?.windows.count, 2)
        XCTAssertTrue(first.tabGroup === largeWindow.tabGroup)

        let expected = "big.txt \u{2014} " + DocumentWindowController.largeFileTitleNote
        XCTAssertEqual(largeWindow.title, expected)
        XCTAssertEqual(largeWindow.tab.title, expected, "the tab shows the note too")
        XCTAssertTrue(largeWindow.tab.title.contains(DocumentWindowController.largeFileTitleNote))
    }

    // MARK: 4. Close Tab

    /// File > Close says "Close Tab" while the window it would close has
    /// two or more tabs, and "Close" otherwise (Settings, one tab, none).
    func testCloseTitleFollowsTheTargetWindowsTabs() throws {
        let (_, first) = try shownDocument()
        XCTAssertEqual(TabCommands.closeTitle(for: first), "Close")
        XCTAssertEqual(TabCommands.closeTitle(for: nil), "Close")
        try controller(first).newWindowForTab(nil)
        XCTAssertEqual(TabCommands.closeTitle(for: first), "Close Tab")

        let live = try XCTUnwrap(NSApp.mainMenu)
        let file = try menu("File", in: live)
        let close = try command("file.close", in: live)
        ShareMenuValidator.shared.closeTarget = { first }
        file.delegate?.menuNeedsUpdate?(file)
        XCTAssertEqual(close.title, "Close Tab")

        let settings = SettingsWindowController()
        settingsControllers.append(settings)
        let settingsWindow = settings.loadSettingsWindowIfNeeded()
        ShareMenuValidator.shared.closeTarget = { settingsWindow }
        file.delegate?.menuNeedsUpdate?(file)
        XCTAssertEqual(close.title, "Close")
        // The Keyboard tab keeps the command's own name.
        XCTAssertEqual((close.representedObject as? MenuCommand)?.name, "Close")
    }

    /// Closing a tab leaves the others; at one tab the bar hides.
    func testClosingATabKeepsTheOthersAndHidesTheBarAtOne() throws {
        let (_, first) = try shownDocument("one")
        try controller(first).newWindowForTab(nil)
        let second = try XCTUnwrap(first.tabGroup?.windows.last)
        wait { first.tabGroup?.isTabBarVisible == true }
        XCTAssertEqual(first.tabGroup?.isTabBarVisible, true)
        second.performClose(nil)
        wait { first.tabGroup?.windows.count == 1 && first.tabGroup?.isTabBarVisible == false }
        XCTAssertFalse(second.isVisible)
        XCTAssertTrue(first.isVisible)
        XCTAssertEqual(first.tabGroup?.windows.count, 1)
        XCTAssertEqual(first.tabGroup?.isTabBarVisible, false, "one tab: no tab bar")
        XCTAssertEqual(text(first), "one")
    }

    // MARK: 5. Next and previous tab

    /// Show Next Tab and Show Previous Tab are off with one tab and in
    /// Settings (NSWindow's own validation). Moving through the tabs and
    /// wrapping around needs an active app with a key window, so it is in
    /// TabUITests: in this inactive test host NSWindow turns both items off
    /// even with three tabs (measured 2026-10-26).
    func testNextAndPreviousTabAreOffWithOneTabAndInSettings() throws {
        let next = NSMenuItem(title: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "\t")
        let previous = NSMenuItem(title: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)),
                                  keyEquivalent: "\t")
        let (_, first) = try shownDocument("one")
        XCTAssertFalse(first.validateMenuItem(next), "one tab: Show Next Tab is off")
        XCTAssertFalse(first.validateMenuItem(previous))
        let settings = SettingsWindowController()
        settingsControllers.append(settings)
        let settingsWindow = settings.loadSettingsWindowIfNeeded()
        XCTAssertFalse(settingsWindow.validateMenuItem(next), "Settings: Show Next Tab is off")
        XCTAssertFalse(settingsWindow.validateMenuItem(previous))
    }

    // MARK: 6. The tab bar rule

    /// Shown at 2 or more tabs, hidden at 1, whatever state AppKit left.
    func testTabBarRuleCorrectsAMismatch() throws {
        let (_, first) = try shownDocument()
        drain()
        let single = try XCTUnwrap(first.tabGroup)
        if !single.isTabBarVisible { first.toggleTabBar(nil) }
        XCTAssertTrue(single.isTabBarVisible)
        TabBarRule.shared.refresh()
        wait { !single.isTabBarVisible }
        XCTAssertFalse(single.isTabBarVisible, "one tab: the rule hides the bar")

        try controller(first).newWindowForTab(nil)
        let group = try XCTUnwrap(first.tabGroup)
        wait { group.isTabBarVisible }
        // Hidden by hand at two tabs, it comes back (the hide may not even
        // stick for one run loop turn, so only the end state is checked).
        first.toggleTabBar(nil)
        TabBarRule.shared.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        wait { group.isTabBarVisible }
        XCTAssertTrue(group.isTabBarVisible, "two tabs: the bar shows")
    }

    /// Move Tab to New Window leaves two windows of one tab, neither with a bar.
    func testMoveTabToNewWindowLeavesNoBars() throws {
        let (_, first) = try shownDocument("one")
        try controller(first).newWindowForTab(nil)
        let second = try XCTUnwrap(first.tabGroup?.windows.last)
        drain()
        second.moveTabToNewWindow(nil)
        wait { first.tabGroup?.isTabBarVisible == false && second.tabGroup?.isTabBarVisible == false }
        XCTAssertEqual(first.tabGroup?.windows.count, 1)
        XCTAssertEqual(second.tabGroup?.windows.count, 1)
        XCTAssertFalse(first.tabGroup === second.tabGroup)
        XCTAssertEqual(first.tabGroup?.isTabBarVisible, false)
        XCTAssertEqual(second.tabGroup?.isTabBarVisible, false)

        // Back together (as Merge All Windows does, without merging the
        // test host's other windows), with the bar.
        first.addTabbedWindow(second, ordered: .above)
        wait { first.tabGroup?.isTabBarVisible == true }
        XCTAssertEqual(first.tabGroup?.windows.count, 2)
        XCTAssertEqual(first.tabGroup?.isTabBarVisible, true)
    }
}

/// Records each change of a tab group's windows and selection while New
/// Tab runs (TabTests, 1.2.0 change 5).
@MainActor
final class NewTabRecorder {
    struct Step { var kind: String; var actionsOff: Bool; var duration: TimeInterval; var finished: Bool }

    private let group: NSWindowTabGroup
    private let known: Set<ObjectIdentifier>
    private var observations: [NSKeyValueObservation] = []
    private(set) var steps: [Step] = []

    init(group: NSWindowTabGroup) {
        self.group = group
        known = Set(group.windows.map(ObjectIdentifier.init))
        observations.append(group.observe(\.windows) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.step("windows") }
        })
        observations.append(group.observe(\.selectedWindow) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.step("selected") }
        })
    }

    /// The window that joined the group since init, if any.
    var added: NSWindow? { group.windows.first { !known.contains(ObjectIdentifier($0)) } }

    private func step(_ kind: String) {
        let finished = added.map { window -> Bool in
            let controller = window.windowController as? DocumentWindowController
            // Its layout is not checked: AppKit marks the window for
            // layout itself while it joins (measured 2026-10-26).
            return window.firstResponder === controller?.textView
        } ?? false
        steps.append(Step(kind: kind, actionsOff: CATransaction.disableActions(),
                          duration: NSAnimationContext.current.duration, finished: finished))
    }

    func finish() -> [Step] {
        for observation in observations { observation.invalidate() }
        observations = []
        return steps
    }
}
