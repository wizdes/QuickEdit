import AppKit

/// Window tabs (M11, docs/plans/M11.md): New Tab, the Close title, and
/// the Window and View menus' tab items.
///
/// New Tab is `newWindowForTab:`, the action the tab bar's + button sends
/// too. The + button reaches DocumentWindowController through the
/// window's responder chain; the menu item targets NewTabCommand, which
/// picks the document window. NSDocumentController's own
/// `newWindowForTab:` was tried first (measured 2026-10-26): sent with a
/// document window and no main window it opened a separate untitled
/// window, and with a Save panel in front the menu item reached it and
/// stayed on, because AppKit skips the parent window's responder chain
/// while a sheet is key.
@MainActor
enum TabCommands {
    /// The document window in front, if any (Settings and panels are skipped).
    static func frontDocumentWindow() -> NSWindow? {
        NSApp.orderedWindows.first { window in
            window.windowController is DocumentWindowController && (window.isVisible || window.isMiniaturized)
        }
    }

    /// False while an app-modal panel runs or `window` shows a sheet: an
    /// alert, or a Save panel (which, in the sandbox, is no attached sheet).
    /// No window means a new normal window, which is always allowed then.
    static func canAddTab(to window: NSWindow?) -> Bool {
        guard NSApp.modalWindow == nil else { return false }
        guard let window else { return true }
        let document = (window.windowController as? DocumentWindowController)?.document as? TextDocument
        return window.attachedSheet == nil && document?.isShowingSavePanel != true
    }

    /// The document window File > New Tab adds to: the key window, or the
    /// window a key sheet or panel belongs to, or (Settings in front) the
    /// front document window. Nil when no document window is open.
    static func newTabWindow() -> NSWindow? {
        for window in [NSApp.keyWindow, NSApp.keyWindow?.sheetParent, NSApp.mainWindow] {
            if let window, window.windowController is DocumentWindowController { return window }
        }
        return frontDocumentWindow()
    }

    /// A new untitled document as a tab of `target`, selected; with no
    /// target, a new document in its own window. The new window is added
    /// to the group before it is shown, so no separate window flashes.
    static func openNewTab(in target: NSWindow?) {
        let controller = NSDocumentController.shared
        guard let target else {
            controller.newDocument(nil)
            return
        }
        let document: NSDocument
        do {
            document = try controller.openUntitledDocumentAndDisplay(false)
        } catch {
            NSApp.presentError(error)
            return
        }
        document.makeWindowControllers()
        guard let window = document.windowControllers.first?.window else {
            // makeWindowControllers always makes one; say so if it did not.
            FileHandle.standardError.write(Data("QuickEdit: New Tab made a document without a window\n".utf8))
            document.showWindows()
            return
        }
        // The window is finished before it joins (1.2.0, Kelpi 571ac9f):
        // laid out, with the text view taking keys, so the first frame the
        // user sees is the finished tab.
        window.contentView?.layoutSubtreeIfNeeded()
        if let controller = window.windowController as? DocumentWindowController {
            window.makeFirstResponder(controller.textView)
        }
        // Selected through the tab group, never with makeKeyAndOrderFront,
        // which showed one frame of the old tab before the new one. With
        // one tab the bar is not up yet: it comes up with no animation, or
        // it would show one frame with the old tab selected under it.
        if (target.tabbedWindows?.count ?? 1) <= 1 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            target.addTabbedWindow(window, ordered: .above)
            target.tabGroup?.selectedWindow = window
            NSAnimationContext.endGrouping()
            CATransaction.commit()
        } else {
            target.addTabbedWindow(window, ordered: .above)
            target.tabGroup?.selectedWindow = window
        }
        window.makeKey()
    }

    /// File > Close's title for the window Cmd+W would close.
    static func closeTitle(for window: NSWindow?) -> String {
        (window?.tabbedWindows?.count ?? 1) >= 2 ? "Close Tab" : "Close"
    }

    /// The window that `performClose:` reaches now: the key window, or a
    /// sheet on it.
    static func closeTarget() -> NSWindow? {
        NSApp.target(forAction: #selector(NSWindow.performClose(_:)), to: nil, from: nil) as? NSWindow
    }

    // MARK: The Window and View menus

    /// Actions of AppKit's own tab items that go: QuickEdit has its own
    /// next and previous items (so they get custom shortcuts), and there is
    /// no Show Tab Bar (the bar follows the tab count). Merge All Windows,
    /// Move Tab to New Window and Show All Tabs stay.
    static let removedActions: [Selector] = [
        #selector(NSWindow.selectNextTab(_:)),
        #selector(NSWindow.selectPreviousTab(_:)),
        #selector(NSWindow.toggleTabBar(_:)),
    ]

    /// Removes items QuickEdit did not build whose action is one of
    /// `removedActions`. Matched by action, never by title.
    static func removeForeignTabItems(from menu: NSMenu) {
        for item in menu.items.reversed() where item.representedObject as? MenuCommand == nil {
            if let action = item.action, removedActions.contains(action) {
                menu.removeItem(item)
            }
        }
    }
}

/// File > New Tab's target. The item has its own target because, while a
/// Save panel is key, AppKit sends a nil-targeted action past the
/// document window to NSDocumentController.
@MainActor
final class NewTabCommand: NSObject, NSMenuItemValidation {
    static let shared = NewTabCommand()

    @objc func newWindowForTab(_ sender: Any?) {
        let window = TabCommands.newTabWindow()
        guard TabCommands.canAddTab(to: window) else { return }
        TabCommands.openNewTab(in: window)
    }

    /// Off while that window shows a sheet or a Save panel, or an
    /// app-modal panel runs. Read-only and large documents still take a tab.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        TabCommands.canAddTab(to: TabCommands.newTabWindow())
    }
}

/// Window > Tab 1 … Tab 9 and Last Tab (Cmd+1 … Cmd+9 and Cmd+0 since
/// 1.2.2). The item's tag is the tab number; lastTabTag means the last tab. The
/// items have this target, which picks the document window the way New
/// Tab does (the key window, or with Settings in front the front document
/// window), and select through the tab group.
@MainActor
final class TabNumberCommand: NSObject, NSMenuItemValidation {
    static let shared = TabNumberCommand()
    /// The tag of Last Tab.
    static let lastTabTag = 10

    /// The tab `tag` picks in `group`'s order; nil when that tab does not
    /// exist or the group has one tab (nothing to switch to).
    static func tab(for tag: Int, in group: NSWindowTabGroup?) -> NSWindow? {
        guard let windows = group?.windows, windows.count >= 2, tag >= 1 else { return nil }
        if tag == lastTabTag { return windows.last }
        return tag <= windows.count ? windows[tag - 1] : nil
    }

    private static func target(for item: NSMenuItem) -> NSWindow? {
        tab(for: item.tag, in: TabCommands.newTabWindow()?.tabGroup)
    }

    @objc func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let window = Self.target(for: item) else { return }
        window.tabGroup?.selectedWindow = window
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        Self.target(for: menuItem) != nil
    }
}

/// The Window and View menus' delegate: AppKit's duplicate tab items and
/// Show Tab Bar go on the next run loop turn after AppKit adds them, and
/// at once when the menu is about to show.
@MainActor
final class TabMenuCleaner: NSObject, NSMenuDelegate {
    static let shared = TabMenuCleaner()

    private var observer: NSObjectProtocol?
    private var scheduled: [NSMenu] = []

    func install(on menus: [NSMenu]) {
        for menu in menus { menu.delegate = self }
        guard observer == nil else { return }
        // Posted on the main thread, by the menu that changed.
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil,
                                                          queue: nil) { [weak self] note in
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                guard let self, let menu, menu.delegate === self else { return }
                self.schedule(menu)
            }
        }
    }

    /// Removing during AppKit's insertion could upset its indexes, so the
    /// clean-up waits for the next turn of the run loop.
    private func schedule(_ menu: NSMenu) {
        guard !scheduled.contains(where: { $0 === menu }) else { return }
        scheduled.append(menu)
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let menus = self.scheduled
                self.scheduled = []
                for menu in menus { TabCommands.removeForeignTabItems(from: menu) }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        TabCommands.removeForeignTabItems(from: menu)
    }
}

/// The tab bar shows when a window's tab group has 2 or more windows and
/// hides at 1. AppKit already shows it at 2; this only corrects a
/// mismatch, once per group on the next run loop turn after a change.
@MainActor
final class TabBarRule {
    static let shared = TabBarRule()

    /// Document windows, held weakly.
    private let windows = NSHashTable<NSWindow>.weakObjects()
    /// One `windows` observation per tab group a tracked window is in.
    private var groups: [ObjectIdentifier: (group: NSWindowTabGroup, observation: NSKeyValueObservation)] = [:]
    private var pending: [NSWindowTabGroup] = []
    private var isApplying = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, let window, self.windows.contains(window) else { return }
                    self.refresh()
                }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                            queue: nil) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, self.windows.contains(window) else { return }
                // Its group loses it during the close; look again after.
                nonisolated(unsafe) let group = window.tabGroup
                self.windows.remove(window)
                RunLoop.main.perform { [weak self] in
                    MainActor.assumeIsolated {
                        self?.refresh()
                        if let group { self?.schedule(group) }
                    }
                }
            }
        })
    }

    /// Starts following `window`'s tab group.
    func track(_ window: NSWindow) {
        windows.add(window)
        refresh()
    }

    /// Binds to every tracked window's current group (a window changes
    /// group when it is dragged out or in, moved to a new window, merged,
    /// or restored), drops groups no tracked window is in, and schedules
    /// a pass for each group.
    func refresh() {
        var current: [ObjectIdentifier: NSWindowTabGroup] = [:]
        for window in windows.allObjects {
            guard let group = window.tabGroup else { continue }
            current[ObjectIdentifier(group)] = group
        }
        for key in groups.keys where current[key] == nil {
            groups[key]?.observation.invalidate()
            groups[key] = nil
        }
        for (key, group) in current {
            if groups[key] == nil {
                let observation = group.observe(\.windows) { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        // A window left or joined: it may be in another group now.
                        self?.refresh()
                    }
                }
                groups[key] = (group, observation)
            }
            schedule(group)
        }
    }

    private func schedule(_ group: NSWindowTabGroup) {
        let first = pending.isEmpty
        if !pending.contains(where: { $0 === group }) { pending.append(group) }
        guard first else { return }
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated { self?.applyPending() }
        }
    }

    private func applyPending() {
        let groups = pending
        pending = []
        for group in groups { apply(group) }
    }

    /// Shows or hides `group`'s bar when it does not match the count.
    /// AppKit can ignore a toggle while the bar is still animating in or
    /// out (seen in the unit-test host, 2026-10-26), so a toggle that did
    /// not take is tried again a little later, at most `maxAttempts` times.
    private func apply(_ group: NSWindowTabGroup, attempt: Int = 1) {
        guard !isApplying else { return }
        let windows = group.windows
        guard windows.contains(where: { $0.isVisible || $0.isMiniaturized }),
              let window = group.selectedWindow ?? windows.first else { return }
        let wanted = windows.count >= 2
        guard group.isTabBarVisible != wanted else { return }
        isApplying = true
        window.toggleTabBar(nil)
        isApplying = false
        guard group.isTabBarVisible != wanted else { return }
        guard attempt < Self.maxAttempts else {
            FileHandle.standardError.write(Data("QuickEdit: the tab bar did not \(wanted ? "show" : "hide") after \(attempt) tries\n".utf8))
            return
        }
        nonisolated(unsafe) let retried = group
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            MainActor.assumeIsolated { self?.apply(retried, attempt: attempt + 1) }
        }
    }

    static let maxAttempts = 5
    static let retryDelay: TimeInterval = 0.25
}
