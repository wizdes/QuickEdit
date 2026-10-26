import AppKit

/// One key equivalent: a key as AppKit menus spell it, plus modifiers.
/// An empty key means "no shortcut".
struct KeyShortcut: Hashable, Sendable {
    /// The modifiers a shortcut can use. Others (Caps Lock, Fn, the
    /// numeric-pad flag) are dropped.
    static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    var key: String
    private var modifierBits: UInt

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierBits) }

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) {
        self.key = key
        self.modifierBits = key.isEmpty ? 0 : modifiers.intersection(Self.modifierMask).rawValue
    }

    /// No shortcut. Not called `none`: with `KeyShortcut?` that name
    /// would mean nil.
    static let empty = KeyShortcut("", [])
    var isNone: Bool { key.isEmpty }

    /// The shortcut a menu item has now.
    @MainActor
    init(of item: NSMenuItem) {
        self.init(item.keyEquivalent, item.keyEquivalentModifierMask)
    }

    // MARK: One spelling per key press

    /// US-keyboard shifted characters and the key they are typed on. AppKit
    /// matches ":" + Cmd and ";" + Shift+Cmd to the same key press, so
    /// comparisons use the base key plus Shift.
    static let shiftedToBase: [Character: Character] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'",
        "<": ",", ">": ".", "?": "/",
    ]

    /// The same key press, spelled as a lower-case base key plus Shift.
    var normalized: KeyShortcut {
        guard key.count == 1, let char = key.first else { return self }
        if let base = Self.shiftedToBase[char] {
            return KeyShortcut(String(base), modifiers.union(.shift))
        }
        let lower = key.lowercased()
        if lower != key, char.isLetter {
            return KeyShortcut(lower, modifiers.union(.shift))
        }
        return self
    }

    /// True when both mean the same key press.
    func matches(_ other: KeyShortcut) -> Bool { normalized == other.normalized }

    // MARK: Kinds of keys

    /// F1 to F35 (NSF1FunctionKey ... NSF35FunctionKey).
    var isFunctionKey: Bool {
        guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first else { return false }
        return (UInt32(NSF1FunctionKey)...UInt32(NSF35FunctionKey)).contains(scalar.value)
    }

    var hasCommandOrControl: Bool { !modifiers.intersection([.command, .control]).isEmpty }

    // MARK: Shown as in the menu bar ("⇧⌘Y", "⌘:", "⌥⎋", "F5")

    private static let keyNames: [UInt32: String] = [
        0x1B: "\u{238B}", 0x09: "\u{21E5}", 0x20: "Space", 0x08: "\u{232B}", 0x7F: "\u{232B}",
        0x0D: "\u{21A9}", 0x03: "\u{2324}",
        UInt32(NSDeleteFunctionKey): "\u{2326}",
        UInt32(NSLeftArrowFunctionKey): "\u{2190}", UInt32(NSRightArrowFunctionKey): "\u{2192}",
        UInt32(NSUpArrowFunctionKey): "\u{2191}", UInt32(NSDownArrowFunctionKey): "\u{2193}",
        UInt32(NSHomeFunctionKey): "\u{2196}", UInt32(NSEndFunctionKey): "\u{2198}",
        UInt32(NSPageUpFunctionKey): "\u{21DE}", UInt32(NSPageDownFunctionKey): "\u{21DF}",
    ]

    private static let baseToShifted: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (shifted, base) in shiftedToBase where !base.isNumber { map[base] = shifted }
        return map
    }()

    /// The modifier symbols, then the key. Shift on a punctuation key
    /// shows the shifted character instead ("⌘:" for Shift+Cmd+;).
    var display: String {
        guard !isNone else { return "" }
        let shortcut = normalized
        var mods = shortcut.modifiers
        var keyText: String
        if mods.contains(.shift), let char = shortcut.key.first, let shifted = Self.baseToShifted[char] {
            keyText = String(shifted)
            mods.remove(.shift)
        } else if let scalar = shortcut.key.unicodeScalars.first, shortcut.key.unicodeScalars.count == 1,
                  let name = Self.keyNames[scalar.value] {
            keyText = name
        } else if shortcut.isFunctionKey, let scalar = shortcut.key.unicodeScalars.first {
            keyText = "F\(Int(scalar.value) - Int(NSF1FunctionKey) + 1)"
        } else {
            keyText = shortcut.key.uppercased()
        }
        var text = ""
        if mods.contains(.control) { text += "\u{2303}" }
        if mods.contains(.option) { text += "\u{2325}" }
        if mods.contains(.shift) { text += "\u{21E7}" }
        if mods.contains(.command) { text += "\u{2318}" }
        return text + keyText
    }

    /// Modifier symbols only, for the keys held while recording.
    static func display(modifiers: NSEvent.ModifierFlags) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "\u{2303}" }
        if modifiers.contains(.option) { text += "\u{2325}" }
        if modifiers.contains(.shift) { text += "\u{21E7}" }
        if modifiers.contains(.command) { text += "\u{2318}" }
        return text
    }

    // MARK: Saved form

    /// `{"key": String, "modifiers": Int}`, a property-list value.
    var storedValue: [String: Any] { ["key": key, "modifiers": Int(modifierBits)] }

    init?(storedValue: Any) {
        guard let dict = storedValue as? [String: Any], let key = dict["key"] as? String,
              let bits = dict["modifiers"] as? Int, bits >= 0 else { return nil }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(bits))
        guard flags.subtracting(Self.modifierMask).isEmpty, key.count <= 1 else { return nil }
        self.init(key, flags)
    }
}

/// What QuickEdit knows about one menu command it builds: a stable id
/// (saved with the user's shortcut), the name the Keyboard tab shows, and
/// the default shortcut from MainMenu.swift. Kept in the item's
/// `representedObject`, so it survives any copy AppKit makes of the item.
final class MenuCommand: NSObject, Sendable {
    let id: String
    let name: String
    let defaultShortcut: KeyShortcut
    /// The id of the item this one is the Option-key alternate of.
    let alternateOf: String?

    init(id: String, name: String, defaultShortcut: KeyShortcut, alternateOf: String? = nil) {
        self.id = id
        self.name = name
        self.defaultShortcut = defaultShortcut
        self.alternateOf = alternateOf
    }
}

/// Custom keyboard shortcuts (user decision U2, docs/plans/M9.md n3).
///
/// Only changes are saved: one dictionary under `Defaults.keyboardShortcutsKey`,
/// command id to shortcut (an empty key removes the shortcut). The default
/// set stays in MainMenu.swift. A change is applied to the menu bar at once.
/// Shortcuts set in System Settings > Keyboard > App Shortcuts still win,
/// because AppKit applies them over the item's own key equivalent.
@MainActor
enum Shortcuts {
    /// Keys macOS keeps for itself; QuickEdit never sees them.
    static let systemReserved: [KeyShortcut] = [
        KeyShortcut("\t", [.command]),
        KeyShortcut(" ", [.command]),
        KeyShortcut("\u{1B}", [.command, .option]),
    ]

    /// Standard text-editing keys (macOS's StandardKeyBinding.dict and
    /// NSTextView's own Cmd and Option keys): a menu shortcut on one of
    /// them would stop that editing action in every text field. Each with
    /// the editing action it does, named as in the Cocoa text system.
    static let textEditingKeys: [(shortcut: KeyShortcut, action: String)] = {
        func key(_ value: Int) -> String { String(Character(UnicodeScalar(UInt32(value))!)) }
        let left = key(NSLeftArrowFunctionKey), right = key(NSRightArrowFunctionKey)
        let up = key(NSUpArrowFunctionKey), down = key(NSDownArrowFunctionKey)
        let delete = "\u{08}"
        var keys: [(KeyShortcut, String)] = [
            (KeyShortcut("a", [.control]), "Move to Beginning of Line"),
            (KeyShortcut("e", [.control]), "Move to End of Line"),
            (KeyShortcut("b", [.control]), "Move Backward"),
            (KeyShortcut("f", [.control]), "Move Forward"),
            (KeyShortcut("n", [.control]), "Move Down"),
            (KeyShortcut("p", [.control]), "Move Up"),
            (KeyShortcut("k", [.control]), "Delete to End of Line"),
            (KeyShortcut("y", [.control]), "Yank"),
            (KeyShortcut("d", [.control]), "Delete Forward"),
            (KeyShortcut("h", [.control]), "Delete Backward"),
            (KeyShortcut("t", [.control]), "Transpose"),
            (KeyShortcut("o", [.control]), "Insert Line Break"),
            (KeyShortcut("l", [.control]), "Center Selection in Visible Area"),
            (KeyShortcut("v", [.control]), "Page Down"),
            (KeyShortcut(left, [.command]), "Move to Beginning of Line"),
            (KeyShortcut(right, [.command]), "Move to End of Line"),
            (KeyShortcut(up, [.command]), "Move to Beginning of Document"),
            (KeyShortcut(down, [.command]), "Move to End of Document"),
            (KeyShortcut(left, [.option]), "Move Word Left"),
            (KeyShortcut(right, [.option]), "Move Word Right"),
            (KeyShortcut(up, [.option]), "Move to Beginning of Paragraph"),
            (KeyShortcut(down, [.option]), "Move to End of Paragraph"),
            (KeyShortcut(delete, [.command]), "Delete to Beginning of Line"),
            (KeyShortcut(delete, [.option]), "Delete Word Backward"),
        ]
        // Shift with each arrow key extends the selection the same way.
        for (shortcut, action) in keys where [left, right, up, down].contains(shortcut.key) {
            keys.append((KeyShortcut(shortcut.key, shortcut.modifiers.union(.shift)),
                         action.replacingOccurrences(of: "Move", with: "Select")))
        }
        return keys
    }()

    /// The editing action `shortcut` does in text, if any. Delete is
    /// spelled two ways ("\u{08}" when recorded, "\u{7F}" in menus).
    static func textEditingAction(for shortcut: KeyShortcut) -> String? {
        var pressed = shortcut.normalized
        if pressed.key == "\u{7F}" { pressed = KeyShortcut("\u{08}", pressed.modifiers) }
        return textEditingKeys.first { $0.shortcut.matches(pressed) }?.action
    }

    // MARK: The saved changes

    /// The saved changes, by command id. A malformed entry is reported on
    /// stderr and left out (the default shortcut then applies).
    static func overrides(in store: UserDefaults = Defaults.store) -> [String: KeyShortcut] {
        guard let raw = store.object(forKey: Defaults.keyboardShortcutsKey) else { return [:] }
        guard let dict = raw as? [String: Any] else {
            FileHandle.standardError.write(Data("QuickEdit: \(Defaults.keyboardShortcutsKey) is not a dictionary; keyboard shortcuts are the defaults\n".utf8))
            return [:]
        }
        var result: [String: KeyShortcut] = [:]
        for (id, value) in dict {
            if let shortcut = KeyShortcut(storedValue: value) {
                result[id] = shortcut
            } else {
                FileHandle.standardError.write(Data("QuickEdit: saved keyboard shortcut for \(id) is malformed; using its default\n".utf8))
            }
        }
        return result
    }

    /// Saves `shortcut` for `command`, or removes the change when it equals
    /// the default (or `shortcut` is nil). Then applies it to the menu bar.
    static func set(_ shortcut: KeyShortcut?, for command: MenuCommand, store: UserDefaults = Defaults.store,
                    applyingTo menu: NSMenu? = NSApp.mainMenu) {
        var dict = (store.dictionary(forKey: Defaults.keyboardShortcutsKey)) ?? [:]
        if let shortcut, !(shortcut.matches(command.defaultShortcut)
                            && shortcut.isNone == command.defaultShortcut.isNone) {
            dict[command.id] = shortcut.normalized.storedValue
        } else {
            dict.removeValue(forKey: command.id)
        }
        if dict.isEmpty {
            store.removeObject(forKey: Defaults.keyboardShortcutsKey)
        } else {
            store.set(dict, forKey: Defaults.keyboardShortcutsKey)
        }
        if let menu { apply(to: menu, store: store) }
    }

    /// Restore Keyboard Defaults: every change goes.
    static func restoreDefaults(store: UserDefaults = Defaults.store, applyingTo menu: NSMenu? = NSApp.mainMenu) {
        store.removeObject(forKey: Defaults.keyboardShortcutsKey)
        if let menu { apply(to: menu, store: store) }
    }

    /// The shortcut `command` has with these changes. A default key the
    /// user already gave another command stays with that command, and this
    /// one gets none (M11: a version that adds Cmd+T for New Tab must not
    /// take it from a command the user set it on).
    static func shortcut(for command: MenuCommand, overrides: [String: KeyShortcut]) -> KeyShortcut {
        if let own = overrides[command.id] { return own }
        let fallback = command.defaultShortcut
        if !fallback.isNone, overrides.contains(where: { $0.key != command.id && $0.value.matches(fallback) }) {
            return .empty
        }
        return fallback
    }

    // MARK: The menu bar

    /// Every QuickEdit command item in `menu` and its submenus, in menu order.
    static func commandItems(in menu: NSMenu) -> [(item: NSMenuItem, command: MenuCommand)] {
        var result: [(NSMenuItem, MenuCommand)] = []
        for item in menu.items {
            if let command = item.representedObject as? MenuCommand { result.append((item, command)) }
            if let submenu = item.submenu { result += commandItems(in: submenu) }
        }
        return result
    }

    /// Puts each command's shortcut (its change, else its default) on its
    /// item. An Option-key alternate stays an alternate only while its key
    /// still pairs with its main item's; otherwise it shows as its own item.
    static func apply(to menu: NSMenu, store: UserDefaults = Defaults.store) {
        apply(to: menu, overrides: overrides(in: store))
    }

    static func apply(to menu: NSMenu, overrides: [String: KeyShortcut]) {
        let items = commandItems(in: menu)
        var byID: [String: NSMenuItem] = [:]
        for (item, command) in items {
            let shortcut = shortcut(for: command, overrides: overrides)
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.isNone ? [] : shortcut.modifiers
            byID[command.id] = item
        }
        for (item, command) in items {
            guard let primaryID = command.alternateOf, let primary = byID[primaryID] else { continue }
            let main = KeyShortcut(of: primary).normalized
            let alt = KeyShortcut(of: item).normalized
            item.isAlternate = !main.isNone && main.key == alt.key
                && alt.modifiers == main.modifiers.union(.option) && !main.modifiers.contains(.option)
        }
    }

    // MARK: Checking a new shortcut

    /// Why a new shortcut is refused.
    enum Refusal: Equatable {
        /// Another menu item has it: its name and menu path ("Edit > Find").
        case clash(KeyShortcut, name: String, menuPath: String)
        /// macOS keeps it (Cmd+Tab, Cmd+Space, Cmd+Option+Esc).
        case system(KeyShortcut)
        /// A standard text-editing key; the action it does in text.
        case textEditing(KeyShortcut, action: String)
        /// Needs Cmd or Ctrl, unless it is a function key.
        case needsModifier

        /// The message under the table (wording from docs/mockups/M9-keyboard.html).
        var message: String {
            switch self {
            case let .clash(shortcut, name, path):
                "\(shortcut.display) is already used by \u{201C}\(name)\u{201D} in the \(path) menu."
            case let .system(shortcut):
                "\(shortcut.display) is kept by macOS."
            case let .textEditing(shortcut, action):
                "\(shortcut.display) is the text-editing key for \u{201C}\(action)\u{201D}."
            case .needsModifier:
                "A shortcut needs \u{2318} or \u{2303}, unless it is a function key."
            }
        }

        /// The part shown in bold: the keys.
        var keysText: String? {
            switch self {
            case let .clash(shortcut, _, _), let .system(shortcut), let .textEditing(shortcut, _): shortcut.display
            case .needsModifier: nil
            }
        }
    }

    /// Nil when `shortcut` may be given to `command`; else why not. Every
    /// item in `menu` with a key counts, including the ones AppKit adds
    /// (Close All, Emoji & Symbols), so a clash names the real item.
    static func refusal(for shortcut: KeyShortcut, command: MenuCommand, in menu: NSMenu?) -> Refusal? {
        if Self.systemReserved.contains(where: { $0.matches(shortcut) }) { return .system(shortcut.normalized) }
        if let action = textEditingAction(for: shortcut) { return .textEditing(shortcut.normalized, action: action) }
        if !shortcut.hasCommandOrControl && !shortcut.isFunctionKey { return .needsModifier }
        return clash(for: shortcut, command: command, in: menu)
    }

    /// Nil when `command` may go back to its default shortcut; else the
    /// clash with the item that has that key now (M9 review row 1). Only a
    /// clash counts: a default key is never refused for its own kind.
    static func resetRefusal(for command: MenuCommand, in menu: NSMenu?) -> Refusal? {
        guard !command.defaultShortcut.isNone else { return nil }
        return clash(for: command.defaultShortcut, command: command, in: menu)
    }

    private static func clash(for shortcut: KeyShortcut, command: MenuCommand, in menu: NSMenu?) -> Refusal? {
        guard let menu else { return nil }
        if let (item, path) = itemUsing(shortcut, in: menu, path: [], skipping: command.id) {
            let name = (item.representedObject as? MenuCommand)?.name.components(separatedBy: " \u{203A} ").last
                ?? item.title
            return .clash(shortcut.normalized, name: name, menuPath: path.joined(separator: " > "))
        }
        return nil
    }

    private static func itemUsing(_ shortcut: KeyShortcut, in menu: NSMenu, path: [String],
                                  skipping id: String) -> (NSMenuItem, [String])? {
        for item in menu.items where !item.isSeparatorItem {
            if let submenu = item.submenu {
                if let found = itemUsing(shortcut, in: submenu, path: path + [item.title], skipping: id) {
                    return found
                }
                continue
            }
            if (item.representedObject as? MenuCommand)?.id == id { continue }
            // Fn-key items (Emoji & Symbols' Fn+E) never match a recorded key.
            if item.keyEquivalent.isEmpty || item.keyEquivalentModifierMask.contains(.function) { continue }
            if KeyShortcut(of: item).matches(shortcut), !path.isEmpty { return (item, path) }
        }
        return nil
    }

    // MARK: The Keyboard tab's rows

    enum Row: Equatable {
        /// A top-level menu ("File").
        case menu(String)
        /// A submenu with more than one command ("Find").
        case submenu(String)
        /// A command; `indented` when it is under a submenu row.
        case command(MenuCommand, indented: Bool)
    }

    /// Every command in `menuBar`, with a header row per menu and per
    /// submenu of more than one command (one level: Edit > Find, never
    /// deeper). A submenu of one command would show it in a row of its
    /// own; none has one now (Open Recent's Clear Menu is AppKit's item,
    /// not a command, so it has no row).
    static func rows(for menuBar: NSMenu) -> [Row] {
        var rows: [Row] = []
        // AppKit keeps a hidden copy of some items (Enter Full Screen); the
        // copy shares the command and gets the same shortcut, but one row.
        var seen: Set<String> = []
        for top in menuBar.items {
            guard let menu = top.submenu else { continue }
            var menuRows: [Row] = []
            for item in menu.items {
                if let command = item.representedObject as? MenuCommand {
                    guard seen.insert(command.id).inserted else { continue }
                    menuRows.append(.command(command, indented: false))
                } else if let submenu = item.submenu {
                    let commands = commandItems(in: submenu).map(\.command).filter { seen.insert($0.id).inserted }
                    if commands.count > 1 {
                        menuRows.append(.submenu(item.title))
                        menuRows += commands.map { .command($0, indented: true) }
                    } else if let only = commands.first {
                        menuRows.append(.command(only, indented: false))
                    }
                }
            }
            if !menuRows.isEmpty { rows += [.menu(top.title)] + menuRows }
        }
        return rows
    }
}
