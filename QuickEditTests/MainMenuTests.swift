import AppKit
import XCTest
@testable import QuickEdit

/// The menu bar from MainMenu.build(): titles, keys and actions (contract `app-menu`).
@MainActor
final class MainMenuTests: XCTestCase {
    private func menu(_ title: String, in bar: NSMenu) throws -> NSMenu {
        try XCTUnwrap(bar.item(withTitle: title)?.submenu, "no \(title) menu")
    }

    private func check(_ menu: NSMenu, _ title: String, _ action: String, _ key: String = "",
                       _ modifiers: NSEvent.ModifierFlags = [.command], tag: Int? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
        guard let item = menu.item(withTitle: title) else {
            XCTFail("no item \"\(title)\" in \(menu.title)", file: file, line: line)
            return
        }
        XCTAssertEqual(item.action.map(NSStringFromSelector), action, title, file: file, line: line)
        XCTAssertEqual(item.keyEquivalent, key, title, file: file, line: line)
        if !key.isEmpty {
            XCTAssertEqual(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), modifiers,
                           title, file: file, line: line)
        }
        if let tag { XCTAssertEqual(item.tag, tag, title, file: file, line: line) }
    }

    func testMenuBar() throws {
        let bar = MainMenu.build()
        XCTAssertEqual(bar.items.map(\.title), ["QuickEdit", "File", "Edit", "Format", "View", "Window", "Help"])

        let app = try menu("QuickEdit", in: bar)
        check(app, "About QuickEdit", "orderFrontStandardAboutPanel:")
        check(app, "Hide QuickEdit", "hide:", "h")
        check(app, "Hide Others", "hideOtherApplications:", "h", [.command, .option])
        check(app, "Show All", "unhideAllApplications:")
        check(app, "Quit QuickEdit", "terminate:", "q")
        XCTAssertNotNil(app.item(withTitle: "Services")?.submenu)

        let file = try menu("File", in: bar)
        check(file, "New", "newDocument:", "n")
        check(file, "Open\u{2026}", "openDocument:", "o")
        XCTAssertEqual(file.item(withTitle: "Open Recent")?.submenu?.items.last?.action,
                       #selector(NSDocumentController.clearRecentDocuments(_:)))
        check(file, "Close", "performClose:", "w")
        check(file, "Save", "saveDocument:", "s")
        check(file, "Duplicate", "duplicateDocument:", "s", [.command, .shift])
        check(file, "Rename\u{2026}", "renameDocument:")
        check(file, "Move To\u{2026}", "moveDocument:")
        check(file, "Revert to Saved", "revertDocumentToSaved:")

        let edit = try menu("Edit", in: bar)
        check(edit, "Undo", "undo:", "z")
        check(edit, "Redo", "redo:", "z", [.command, .shift])
        check(edit, "Cut", "cut:", "x")
        check(edit, "Copy", "copy:", "c")
        check(edit, "Paste", "paste:", "v")
        check(edit, "Delete", "delete:")
        check(edit, "Select All", "selectAll:", "a")

        let find = try menu("Find", in: edit)
        check(find, "Find\u{2026}", "performTextFinderAction:", "f", tag: 1)
        check(find, "Find and Replace\u{2026}", "performTextFinderAction:", "f", [.command, .option], tag: 12)
        check(find, "Find Next", "performTextFinderAction:", "g", tag: 2)
        check(find, "Find Previous", "performTextFinderAction:", "g", [.command, .shift], tag: 3)
        check(find, "Use Selection for Find", "performTextFinderAction:", "e", tag: 7)
        check(find, "Jump to Selection", "centerSelectionInVisibleArea:", "j")

        let spelling = try menu("Spelling and Grammar", in: edit)
        check(spelling, "Show Spelling and Grammar", "showGuessPanel:", ":")
        check(spelling, "Check Document Now", "checkSpelling:", ";")
        check(spelling, "Check Spelling While Typing", "toggleContinuousSpellChecking:")
        check(spelling, "Check Grammar With Spelling", "toggleGrammarChecking:")
        check(spelling, "Correct Spelling Automatically", "toggleAutomaticSpellingCorrection:")

        let substitutions = try menu("Substitutions", in: edit)
        check(substitutions, "Show Substitutions", "orderFrontSubstitutionsPanel:")
        check(substitutions, "Smart Copy/Paste", "toggleSmartInsertDelete:")
        check(substitutions, "Smart Quotes", "toggleAutomaticQuoteSubstitution:")
        check(substitutions, "Smart Dashes", "toggleAutomaticDashSubstitution:")
        check(substitutions, "Text Replacement", "toggleAutomaticTextReplacement:")

        let transformations = try menu("Transformations", in: edit)
        check(transformations, "Make Upper Case", "uppercaseWord:")
        check(transformations, "Make Lower Case", "lowercaseWord:")
        check(transformations, "Capitalize", "capitalizeWord:")

        let speech = try menu("Speech", in: edit)
        check(speech, "Start Speaking", "startSpeaking:")
        check(speech, "Stop Speaking", "stopSpeaking:")

        check(try menu("Format", in: bar), "Prevent Editing", "toggleReadOnly:")

        let window = try menu("Window", in: bar)
        check(window, "Minimize", "performMiniaturize:", "m")
        check(window, "Zoom", "performZoom:")
        check(window, "Bring All to Front", "arrangeInFront:")

        let tree = Self.describe(bar, depth: 0)
        let attachment = XCTAttachment(string: tree)
        attachment.name = "menu-tree"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Every menu item with its key, for reading the menus without a screenshot.
    static func describe(_ menu: NSMenu, depth: Int) -> String {
        var out = ""
        for item in menu.items {
            let indent = String(repeating: "    ", count: depth)
            if item.isSeparatorItem { out += indent + "----\n"; continue }
            var key = ""
            if !item.keyEquivalent.isEmpty {
                let m = item.keyEquivalentModifierMask
                key = (m.contains(.control) ? "Ctrl+" : "") + (m.contains(.option) ? "Opt+" : "")
                    + (m.contains(.shift) ? "Shift+" : "") + (m.contains(.command) ? "Cmd+" : "")
                    + item.keyEquivalent.uppercased()
            }
            let action = item.action.map(NSStringFromSelector) ?? ""
            out += "\(indent)\(item.title)\(key.isEmpty ? "" : "  [\(key)]")\(action.isEmpty ? "" : "  -> \(action)")\n"
            if let submenu = item.submenu { out += describe(submenu, depth: depth + 1) }
        }
        return out
    }

    /// Draws the untitled window's content offscreen. Needs no screen access,
    /// so it works where screencapture and XCUITest cannot.
    func testRenderUntitledWindow() throws {
        let document = TextDocument()
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        // Inserted the way typing inserts: with the text view's typing attributes.
        let sample = "QuickEdit M1 render check\n\tone tab\n" + String(repeating: "x", count: 90) + "|\n"
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0),
                                               with: NSAttributedString(string: sample,
                                                                        attributes: controller.textView.typingAttributes))
        content.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "untitled-window-content"
        attachment.lifetime = .keepAlways
        add(attachment)
        let size = window.contentRect(forFrameRect: window.frame).size
        let info = XCTAttachment(string: "window content size: \(size.width) x \(size.height)\n"
            + "text view frame: \(controller.textView.frame)\n"
            + "font: \(TextViewFactory.plainFont())\n"
            + "x advance: \(TextViewFactory.xAdvance(of: TextViewFactory.plainFont()))\n"
            + "line height: \(TextViewFactory.lineHeight(of: TextViewFactory.plainFont()))\n")
        info.name = "untitled-window-geometry"
        info.lifetime = .keepAlways
        add(info)
        let expected = TextViewFactory.initialContentSize()
        XCTAssertEqual(controller.textView.frame.width, expected.width, accuracy: 0.5)
        controller.close()
    }
    // MARK: M2 n1: the File menu for document life

    /// Every File item in order: title, key, action, and whether it is an
    /// Option-key alternate. Save All stays: TextEdit 1.9 has it
    /// (reference/apple/Base.lproj/Edit.nib/designable.nib, item "Save All").
    func testFileMenuItemsInOrder() throws {
        let file = try menu("File", in: MainMenu.build())
        let rows = file.items.map { item -> String in
            if item.isSeparatorItem { return "----" }
            let m = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            let key = item.keyEquivalent.isEmpty ? "" : (m.contains(.option) ? "Opt+" : "")
                + (m.contains(.shift) ? "Shift+" : "") + (m.contains(.command) ? "Cmd+" : "") + item.keyEquivalent
            let action = item.submenu != nil ? "submenu" : (item.action.map(NSStringFromSelector) ?? "")
            return "\(item.title)|\(key)|\(action)\(item.isAlternate ? "|alternate" : "")"
        }
        XCTAssertEqual(rows, [
            "New|Cmd+n|newDocument:",
            "Open\u{2026}|Cmd+o|openDocument:",
            "Open Recent||submenu",
            "----",
            "Close|Cmd+w|performClose:",
            "Save|Cmd+s|saveDocument:",
            "Duplicate|Shift+Cmd+s|duplicateDocument:",
            "Save As\u{2026}|Opt+Shift+Cmd+s|saveDocumentAs:|alternate",
            "Rename\u{2026}||renameDocument:",
            "Move To\u{2026}||moveDocument:",
            "Save All||saveAllDocuments:",
            "Revert to Saved||revertDocumentToSaved:",
        ])
    }

    // MARK: M4 n1: the Edit and Format menus

    /// One row per item, nested items indented four spaces:
    /// "Title|Key|action" plus "|tag N" for a nonzero tag. Keys read like
    /// docs/codemap.md section 2 ("Shift+Cmd+Z", "Opt+Esc").
    static func rows(_ menu: NSMenu, depth: Int = 0) -> [String] {
        var out: [String] = []
        let indent = String(repeating: "    ", count: depth)
        for item in menu.items {
            if item.isSeparatorItem { out.append(indent + "----"); continue }
            var key = ""
            if !item.keyEquivalent.isEmpty {
                let m = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                let name = item.keyEquivalent == "\u{1B}" ? "Esc" : item.keyEquivalent.uppercased()
                key = (m.contains(.control) ? "Ctrl+" : "") + (m.contains(.option) ? "Opt+" : "")
                    + (m.contains(.shift) ? "Shift+" : "") + (m.contains(.command) ? "Cmd+" : "") + name
            }
            let action = item.submenu != nil ? "submenu" : (item.action.map(NSStringFromSelector) ?? "")
            out.append(indent + "\(item.title)|\(key)|\(action)" + (item.tag != 0 ? "|tag \(item.tag)" : ""))
            if let submenu = item.submenu { out += rows(submenu, depth: depth + 1) }
        }
        return out
    }

    /// The whole Edit menu, in order, against docs/codemap.md section 2: every
    /// KEEP row, Data Detectors (CHANGE row, kept after the test in
    /// EditActionsTests), and the nib's separators once the DROP rows are gone
    /// (Paste and Match Style, Insert, Attach Files..., Link..., Smart Links).
    func testEditMenuTreeMatchesCodemap() throws {
        let edit = try menu("Edit", in: MainMenu.build())
        XCTAssertEqual(Self.rows(edit), [
            "Undo|Cmd+Z|undo:",
            "Redo|Shift+Cmd+Z|redo:",
            "----",
            "Cut|Cmd+X|cut:",
            "Copy|Cmd+C|copy:",
            "Paste|Cmd+V|paste:",
            "Delete||delete:",
            "Complete|Opt+Esc|complete:",
            "Select All|Cmd+A|selectAll:",
            "----",
            "Find||submenu",
            "    Find\u{2026}|Cmd+F|performTextFinderAction:|tag 1",
            "    Find and Replace\u{2026}|Opt+Cmd+F|performTextFinderAction:|tag 12",
            "    Find Next|Cmd+G|performTextFinderAction:|tag 2",
            "    Find Previous|Shift+Cmd+G|performTextFinderAction:|tag 3",
            "    Use Selection for Find|Cmd+E|performTextFinderAction:|tag 7",
            "    Jump to Selection|Cmd+J|centerSelectionInVisibleArea:",
            "    Select Line...|Cmd+L|showWindow:",
            "Spelling and Grammar||submenu",
            "    Show Spelling and Grammar|Cmd+:|showGuessPanel:",
            "    Check Document Now|Cmd+;|checkSpelling:",
            "    ----",
            "    Check Spelling While Typing||toggleContinuousSpellChecking:",
            "    Check Grammar With Spelling||toggleGrammarChecking:",
            "    Correct Spelling Automatically||toggleAutomaticSpellingCorrection:",
            "Substitutions||submenu",
            "    Show Substitutions||orderFrontSubstitutionsPanel:",
            "    ----",
            "    Smart Copy/Paste||toggleSmartInsertDelete:",
            "    Smart Quotes||toggleAutomaticQuoteSubstitution:",
            "    Smart Dashes||toggleAutomaticDashSubstitution:",
            "    Data Detectors||toggleAutomaticDataDetection:",
            "    Text Replacement||toggleAutomaticTextReplacement:",
            "Transformations||submenu",
            "    Make Upper Case||uppercaseWord:",
            "    Make Lower Case||lowercaseWord:",
            "    Capitalize||capitalizeWord:",
            "Speech||submenu",
            "    Start Speaking||startSpeaking:",
            "    Stop Speaking||stopSpeaking:",
        ])
    }

    /// Select Line... goes to the one line panel controller (TextEdit:
    /// `showWindow:` -> LinePanelController); every other Edit item goes to
    /// the first responder (no target).
    func testEditMenuTargets() throws {
        let edit = try menu("Edit", in: MainMenu.build())
        let selectLine = try XCTUnwrap(edit.item(withTitle: "Find")?.submenu?.item(withTitle: "Select Line..."))
        XCTAssertTrue(selectLine.target === LinePanelController.shared)
        func leaves(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { $0.submenu.map(leaves) ?? ($0.isSeparatorItem ? [] : [$0]) }
        }
        for item in leaves(edit) where item !== selectLine {
            XCTAssertNil(item.target, "\(item.title) has a fixed target")
        }
    }

    /// Format keeps Prevent Editing and, since M5, Wrap to Page (Edit.nib order).
    func testFormatMenuTree() throws {
        XCTAssertEqual(Self.rows(try menu("Format", in: MainMenu.build())),
                       ["Prevent Editing||toggleReadOnly:", "Wrap to Page|Shift+Cmd+W|togglePageBreaks:"])
    }

    /// The app's real File menu has one Open Recent item. AppKit adds its own
    /// Open Recent after Open… unless it recognises the one the menu already
    /// has; the first UI test run (2026-10-24) found two.
    func testRealFileMenuHasOneOpenRecent() throws {
        let file = try menu("File", in: try XCTUnwrap(NSApp.mainMenu))
        file.update()
        let titles = file.items.map(\.title)
        XCTAssertEqual(titles.filter { $0 == "Open Recent" }.count, 1, "File menu: \(titles)")
    }

    /// AppKit fills Open Recent in the app's real menu bar.
    func testOpenRecentFillsFromRecentDocuments() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recent-\(UUID().uuidString).txt")
        try Data("r".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = NSDocumentController.shared
        let saved = controller.recentDocumentURLs
        controller.noteNewRecentDocumentURL(url)
        defer {
            controller.clearRecentDocuments(nil)
            for old in saved.reversed() { controller.noteNewRecentDocumentURL(old) }
        }
        let bar = try XCTUnwrap(NSApp.mainMenu)
        let recent = try XCTUnwrap(bar.item(withTitle: "File")?.submenu?.item(withTitle: "Open Recent")?.submenu)
        // AppKit attaches its own delegate to the menu it recognises as Open
        // Recent, and fills it in the private updateMenu:withEvent:withFlags:
        // when the menu opens. Call that the way menu tracking does. If a
        // macOS update renames it, this test fails loudly (not silently);
        // OpenRecentUITests checks the same thing through the real menu.
        let delegate = try XCTUnwrap(recent.delegate as? NSObject, "AppKit did not take over Open Recent")
        let update = NSSelectorFromString("updateMenu:withEvent:withFlags:")
        XCTAssertTrue(delegate.responds(to: update), "AppKit's Open Recent delegate changed: \(type(of: delegate))")
        typealias UpdateFn = @convention(c) (AnyObject, Selector, NSMenu, NSEvent?, UInt) -> Void
        let fn = unsafeBitCast(delegate.method(for: update), to: UpdateFn.self)
        fn(delegate, update, recent, nil, 0)
        let titles = recent.items.map(\.title)
        XCTAssertTrue(titles.contains(url.lastPathComponent), "Open Recent items: \(titles)")
        XCTAssertEqual(recent.items.last?.action, #selector(NSDocumentController.clearRecentDocuments(_:)))
    }
}
