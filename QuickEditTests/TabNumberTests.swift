import AppKit
import XCTest
@testable import QuickEdit

/// 1.2.0 change 6: Window > Tab 1 … Tab 8 (Ctrl+1 … Ctrl+8) and Last Tab
/// (Ctrl+9) pick a tab of the front document window, as in Safari. They
/// have stable ids (so Settings > Keyboard can change them), select
/// through the tab group, and are off when that tab does not exist or the
/// window has one tab. The text view must not take Ctrl+digit first.
@MainActor
final class TabNumberTests: XCTestCase {
    private var saved: SavedSettings!
    private var before: [NSDocument] = []

    static let ids = (1...8).map { "window.tab\($0)" } + ["window.lastTab"]

    override func setUp() async throws {
        saved = SavedSettings()
        before = NSDocumentController.shared.documents
    }

    override func tearDown() async throws {
        for document in NSDocumentController.shared.documents where !before.contains(where: { $0 === document }) {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        saved.restore()
    }

    private func shownDocument(_ text: String) throws -> NSWindow {
        let document = try XCTUnwrap(try NSDocumentController.shared.openUntitledDocumentAndDisplay(false) as? TextDocument)
        document.makeWindowControllers()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        window.orderFront(nil)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        return window
    }

    /// A window of `count` tabs; the last one made is selected.
    private func tabs(_ count: Int) throws -> (NSWindow, NSWindowTabGroup) {
        let first = try shownDocument("tab 1")
        for _ in 1..<count {
            let controller = try XCTUnwrap(first.tabGroup?.selectedWindow?.windowController as? DocumentWindowController)
            controller.newWindowForTab(nil)
        }
        let group = try XCTUnwrap(first.tabGroup)
        XCTAssertEqual(group.windows.count, count)
        return (first, group)
    }

    private func item(_ id: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(Shortcuts.commandItems(in: menu).first { $0.command.id == id }?.item, "no command \(id)")
    }

    private func isEnabled(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        let target = NSApp.target(forAction: action, to: item.target, from: item)
        return (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? (target != nil)
    }

    private func choose(_ item: NSMenuItem) {
        guard let action = item.action else { return XCTFail("\(item.title) has no action") }
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item), "\(item.title) reached nothing")
    }

    // MARK: The items

    func testWindowMenuHasTabNumberItemsWithControlDigits() throws {
        let bar = MainMenu.build()
        let window = try XCTUnwrap(bar.item(withTitle: "Window")?.submenu)
        for (index, id) in Self.ids.enumerated() {
            let menuItem = try item(id, in: bar)
            XCTAssertEqual(menuItem.title, index == 8 ? "Last Tab" : "Tab \(index + 1)", id)
            XCTAssertEqual(KeyShortcut(of: menuItem), KeyShortcut("\(index + 1)", [.control]), id)
            XCTAssertTrue(menuItem.menu === window, "\(id) is in the Window menu")
            XCTAssertNotNil(menuItem.target, "\(id) has its own target, which finds the document window")
            XCTAssertNil(Shortcuts.refusal(for: KeyShortcut("\(index + 1)", [.control]),
                                           command: try XCTUnwrap(menuItem.representedObject as? MenuCommand), in: bar),
                         "its own key is allowed")
        }
        // In order, after Show Next Tab.
        let titles = window.items.map { $0.isSeparatorItem ? "-" : $0.title }
        let start = try XCTUnwrap(titles.firstIndex(of: "Tab 1"))
        XCTAssertEqual(Array(titles[start..<(start + 9)]), (1...8).map { "Tab \($0)" } + ["Last Tab"])
        XCTAssertLessThan(try XCTUnwrap(titles.firstIndex(of: "Show Next Tab")), start)
    }

    // MARK: Choosing

    func testTabNumberSelectsThatTabAndLastTabTheLast() throws {
        let (_, group) = try tabs(3)
        let live = try XCTUnwrap(NSApp.mainMenu)
        XCTAssertTrue(group.selectedWindow === group.windows[2])
        choose(try item("window.tab1", in: live))
        XCTAssertTrue(group.selectedWindow === group.windows[0], "Tab 1 selects the first tab")
        choose(try item("window.tab2", in: live))
        XCTAssertTrue(group.selectedWindow === group.windows[1], "Tab 2 selects the second tab")
        choose(try item("window.lastTab", in: live))
        XCTAssertTrue(group.selectedWindow === group.windows[2], "Last Tab selects the last tab")

        for id in ["window.tab1", "window.tab2", "window.tab3", "window.lastTab"] {
            XCTAssertTrue(isEnabled(try item(id, in: live)), "\(id) is on with 3 tabs")
        }
        for number in 4...8 {
            XCTAssertFalse(isEnabled(try item("window.tab\(number)", in: live)), "Tab \(number) is off with 3 tabs")
        }
        // Choosing an item that is off does nothing.
        choose(try item("window.tab1", in: live))
        choose(try item("window.tab5", in: live))
        XCTAssertTrue(group.selectedWindow === group.windows[0])
    }

    func testOneTabTurnsThemAllOff() throws {
        let window = try shownDocument("only")
        let live = try XCTUnwrap(NSApp.mainMenu)
        for id in Self.ids {
            XCTAssertFalse(isEnabled(try item(id, in: live)), "\(id) is off with one tab")
        }
        XCTAssertLessThanOrEqual(window.tabGroup?.windows.count ?? 1, 1)
    }

    // MARK: The key

    /// Ctrl+1 goes to the menu: the text view's key equivalent pass does
    /// not take it, and the menu bar selects tab 1.
    func testControlDigitReachesTheMenuNotTheTextView() throws {
        let (_, group) = try tabs(2)
        let selected = try XCTUnwrap(group.selectedWindow)
        let controller = try XCTUnwrap(selected.windowController as? DocumentWindowController)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control],
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: selected.windowNumber, context: nil,
                                                   characters: "1", charactersIgnoringModifiers: "1",
                                                   isARepeat: false, keyCode: 18))
        let length = controller.textView.textStorage?.length
        XCTAssertFalse(controller.textView.performKeyEquivalent(with: event), "the text view took Ctrl+1")
        XCTAssertEqual(controller.textView.textStorage?.length, length)
        XCTAssertTrue(try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: event), "no menu item took Ctrl+1")
        XCTAssertTrue(group.selectedWindow === group.windows[0])
    }
}
