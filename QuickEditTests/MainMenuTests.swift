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
        XCTAssertEqual(bar.items.map(\.title), ["QuickEdit", "File", "Edit", "Format", "Window", "Help"])

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
}
