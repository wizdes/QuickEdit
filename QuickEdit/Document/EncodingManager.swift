import AppKit

/// The list of encodings shown in every encoding pop-up, the pop-up builder,
/// and the "Customize Encodings List" panel. Port of
/// reference/apple/EncodingManager.m (docs/codemap.md section 1.11).
/// The shared instance and its panel are made on first use only.
@MainActor
final class EncodingManager: NSObject {
    static let shared = EncodingManager()

    /// Posted when the enabled list changes; every encoding pop-up refills.
    nonisolated static let listChanged = Notification.Name("EncodingsListChanged")
    /// Tag of the "Automatic" item (TextEdit's WantsAutomaticTag).
    nonisolated static let automaticTag = -1
    nonisolated static let customizeTitle = "Customize Encodings List\u{2026}"

    // MARK: The lists (safe on any thread: they read only user defaults)

    nonisolated static func fromCF(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    /// TextEdit's first-run list (EncodingManager.m:229-231), plus the
    /// system's default C-string encoding when it is missing (:235-246).
    nonisolated static func defaultEncodings() -> [String.Encoding] {
        var list: [String.Encoding] = [
            .utf16, .utf8, .macOSRoman, .windowsCP1252, fromCF(.macJapanese), fromCF(.shiftJIS),
            fromCF(.macChineseTrad), fromCF(.macKorean), fromCF(.macChineseSimp), fromCF(.GB_18030_2000),
        ]
        let system = String.defaultCStringEncoding
        if !list.contains(system) { list.append(system) }
        return list
    }

    /// The `Encodings` default, or the first-run list when it is not set.
    nonisolated static func enabledEncodings() -> [String.Encoding] {
        guard let numbers = UserDefaults.standard.array(forKey: DefaultsKey.encodings.rawValue) else {
            return defaultEncodings()
        }
        return numbers.compactMap { ($0 as? NSNumber).map { String.Encoding(rawValue: $0.uintValue) } }
    }

    /// Every encoding with a name, Unicode first, then by the closest Mac
    /// encoding, then by number (EncodingManager.m:125-159).
    nonisolated static let allAvailableEncodings: [String.Encoding] = {
        var cfList: [CFStringEncoding] = []
        if var pointer = CFStringGetListOfAvailableEncodings() {
            while pointer.pointee != kCFStringEncodingInvalidId {
                cfList.append(pointer.pointee)
                pointer += 1
            }
        }
        let unicode = CFStringEncoding(CFStringBuiltInEncodings.unicode.rawValue)
        cfList.sort { first, second in
            let macFirst = CFStringGetMostCompatibleMacStringEncoding(first)
            let macSecond = CFStringGetMostCompatibleMacStringEncoding(second)
            if macFirst == unicode || macSecond == unicode {
                if macFirst == macSecond { return first < second }
                return macFirst == unicode
            }
            return macFirst != macSecond ? macFirst < macSecond : first < second
        }
        return cfList.compactMap { cf in
            let ns = CFStringConvertEncodingToNSStringEncoding(cf)
            guard ns != 0, !String.localizedName(of: String.Encoding(rawValue: ns)).isEmpty else { return nil }
            return String.Encoding(rawValue: ns)
        }
    }()

    /// The "Automatic" choice, or an encoding, from a pop-up item.
    static func encoding(of item: NSMenuItem?) -> String.Encoding? {
        guard let number = item?.representedObject as? NSNumber, number.intValue != Defaults.noStringEncoding else {
            return nil
        }
        return String.Encoding(rawValue: number.uintValue)
    }

    // MARK: Changing the list

    /// Saves a new list and tells every pop-up (EncodingManager.m:255-267).
    func setEnabled(_ encodings: [String.Encoding]) {
        UserDefaults.standard.set(encodings.map { NSNumber(value: $0.rawValue) }, forKey: DefaultsKey.encodings.rawValue)
        listDidChange()
    }

    /// Removes the saved list, so the first-run list applies again (:319-325).
    func revertToDefault() {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.encodings.rawValue)
        listDidChange()
    }

    private func listDidChange() {
        tableView?.reloadData()
        NotificationCenter.default.post(name: Self.listChanged, object: nil)
    }

    // MARK: Pop-ups

    /// Fills `popUp` (EncodingManager.m:185-223): "Automatic" first when
    /// asked, the enabled encodings (plus `selected` when it is missing and
    /// there is no Automatic item), a separator, "Customize Encodings List…".
    /// Every encoding item carries its number as `representedObject`;
    /// Automatic carries `Defaults.noStringEncoding`.
    static func fill(_ popUp: NSPopUpButton, selected: String.Encoding?, includeAutomatic: Bool) {
        popUp.removeAllItems()
        let menu = popUp.menu ?? NSMenu()
        if includeAutomatic {
            let automatic = NSMenuItem(title: "Automatic", action: nil, keyEquivalent: "")
            automatic.representedObject = NSNumber(value: Defaults.noStringEncoding)
            automatic.tag = automaticTag
            menu.addItem(automatic)
        }
        var encodings = enabledEncodings()
        if !includeAutomatic, let selected, !encodings.contains(selected) { encodings.append(selected) }
        var selectIndex = 0
        for encoding in encodings {
            let item = NSMenuItem(title: String.localizedName(of: encoding), action: nil, keyEquivalent: "")
            item.representedObject = NSNumber(value: encoding.rawValue)
            item.isEnabled = true
            menu.addItem(item)
            if encoding == selected { selectIndex = menu.numberOfItems - 1 }
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        let customize = NSMenuItem(title: customizeTitle, action: #selector(showPanel(_:)), keyEquivalent: "")
        customize.target = shared
        menu.addItem(customize)
        popUp.selectItem(at: selectIndex)
    }

    // MARK: The Customize Encodings List panel

    private var panel: NSPanel?
    private var tableView: NSTableView?
    private static let rowIdentifier = NSUserInterfaceItemIdentifier("encodingCheckbox")

    /// The panel works while the Open or Save panel is up (EncodingManager.m:271-290).
    @objc func showPanel(_ sender: Any?) {
        makePanel().makeKeyAndOrderFront(nil)
    }

    /// Built in code from TextEdit's SelectEncodingsPanel.nib frames.
    func makePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 336, height: 187),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        panel.title = "Customize Encodings List"
        panel.worksWhenModal = true
        panel.level = .modalPanel
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("customizeEncodingsPanel")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 336, height: 187))

        let label = NSTextField(labelWithString: "Select the encodings you want to appear in text encoding menus.")
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.frame = NSRect(x: 6, y: 166, width: 322, height: 13)
        label.autoresizingMask = [.width, .minYMargin]
        content.addSubview(label)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("encoding"))
        column.width = 300
        let table = NSTableView()
        table.addTableColumn(column)
        table.headerView = nil
        table.rowSizeStyle = .small
        table.dataSource = self
        table.delegate = self
        table.identifier = NSUserInterfaceItemIdentifier("encodingsTable")
        let scroll = NSScrollView(frame: NSRect(x: 6, y: 41, width: 324, height: 124))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        scroll.autoresizingMask = [.width, .height]
        content.addSubview(scroll)

        let buttons: [(String, Selector, NSRect, NSView.AutoresizingMask)] = [
            ("Select all", #selector(selectAll(_:)), NSRect(x: 1, y: 9, width: 73, height: 28), [.maxXMargin]),
            ("Clear all", #selector(clearAll(_:)), NSRect(x: 72, y: 9, width: 70, height: 28), [.maxXMargin]),
            ("Revert to default", #selector(revertToDefault(_:)), NSRect(x: 220, y: 9, width: 115, height: 28), [.minXMargin]),
        ]
        for (title, action, frame, mask) in buttons {
            let button = NSButton(title: title, target: self, action: action)
            button.frame = frame
            button.autoresizingMask = mask
            content.addSubview(button)
        }
        panel.contentView = content
        panel.center()
        self.panel = panel
        self.tableView = table
        return panel
    }

    @objc private func selectAll(_ sender: Any?) { setEnabled(Self.allAvailableEncodings) }
    @objc private func clearAll(_ sender: Any?) { setEnabled([]) }
    @objc private func revertToDefault(_ sender: Any?) { revertToDefault() }

    /// A checkbox click: the new list keeps the panel's order (:292-305).
    @objc private func checkboxChanged(_ sender: NSButton) {
        guard let table = tableView else { return }
        let row = table.row(for: sender)
        guard row >= 0 else { return }
        let encoding = Self.allAvailableEncodings[row]
        var enabled = Set(Self.enabledEncodings().map(\.rawValue))
        if sender.state == .on { enabled.insert(encoding.rawValue) } else { enabled.remove(encoding.rawValue) }
        setEnabled(Self.allAvailableEncodings.filter { enabled.contains($0.rawValue) })
    }
}

extension EncodingManager: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { Self.allAvailableEncodings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let checkbox = (tableView.makeView(withIdentifier: Self.rowIdentifier, owner: self) as? NSButton)
            ?? {
                let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxChanged(_:)))
                button.identifier = Self.rowIdentifier
                button.controlSize = .small
                button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                return button
            }()
        let encoding = Self.allAvailableEncodings[row]
        checkbox.title = String.localizedName(of: encoding)
        checkbox.state = Self.enabledEncodings().contains(encoding) ? .on : .off
        return checkbox
    }
}

/// A pop-up of encodings that refills itself when the list changes and never
/// keeps the separator or "Customize Encodings List…" selected
/// (EncodingManager.m:62-93).
final class EncodingPopUpButton: NSPopUpButton {
    private let includesAutomatic: Bool

    init(selected: String.Encoding?, includeAutomatic: Bool) {
        includesAutomatic = includeAutomatic
        super.init(frame: .zero, pullsDown: false)
        cell = EncodingPopUpButtonCell(textCell: "", pullsDown: false)
        autoenablesItems = false
        EncodingManager.fill(self, selected: selected, includeAutomatic: includeAutomatic)
        NotificationCenter.default.addObserver(self, selector: #selector(listChanged(_:)),
                                               name: EncodingManager.listChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("EncodingPopUpButton is built in code") }

    /// The chosen encoding, or nil for Automatic.
    var selectedEncoding: String.Encoding? { EncodingManager.encoding(of: selectedItem) }

    @objc private func listChanged(_ notification: Notification) {
        let selected = selectedEncoding
        let disabled = Set(itemArray.filter { !$0.isEnabled }.compactMap { EncodingManager.encoding(of: $0)?.rawValue })
        EncodingManager.fill(self, selected: selected, includeAutomatic: includesAutomatic)
        for item in itemArray where EncodingManager.encoding(of: item).map({ disabled.contains($0.rawValue) }) == true {
            item.isEnabled = false
        }
    }
}

final class EncodingPopUpButtonCell: NSPopUpButtonCell {
    override func selectItem(at index: Int) {
        if index >= 0, index < numberOfItems, let item = item(at: index),
           item.isSeparatorItem || item.title == EncodingManager.customizeTitle {
            return
        }
        super.selectItem(at: index)
    }
}
