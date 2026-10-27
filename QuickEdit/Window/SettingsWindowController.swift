import AppKit

/// QuickEdit > Settings… (Cmd+,). A port of TextEdit 1.9's Preferences
/// window (reference/apple/Preferences.m, Base.lproj/Preferences.nib),
/// built in code with the plain-text controls only (docs/codemap.md 1.10, 3).
///
/// Every control reads its user default when the window is shown and writes
/// it back by target/action; no Cocoa Bindings. New windows read the
/// defaults when they are made, so open windows keep their settings.
///
/// The controller is a plain object until the window is first shown
/// (Doc B section 7, rule 3); `loadSettingsWindowIfNeeded()` builds it.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
    NSWindowRestoration, NSFontChanging, NSTabViewDelegate {
    static let shared = SettingsWindowController()

    /// TextEdit's window identifier (Preferences.m:69).
    static let windowIdentifier = NSUserInterfaceItemIdentifier("Preferences")
    static let restoreIdentifier = NSUserInterfaceItemIdentifier("RestoreAllDefaults")
    static let changeFontIdentifier = NSUserInterfaceItemIdentifier("ChangePlainTextFont")

    // MARK: Strings (macOS 27 TextEdit, Preferences.loctable)

    private static let spellingTip = "Choose Edit > Spelling and Grammar to change this option for individual documents."
    private static let substitutionsTip = "Choose Edit > Substitutions to change this option for individual documents."

    /// The Options checkboxes, two columns, top to bottom
    /// (Preferences.nib:867-1290 without "Show ruler" and "Smart links",
    /// and since 1.2.0 without "Data detectors": new windows always start
    /// with them off).
    static let optionColumns: [[(DefaultsKey, String)]] = [
        [(.checkSpellingWhileTyping, "Check spelling as you type"),
         (.checkGrammarWithSpelling, "Check grammar with spelling"),
         (.correctSpellingAutomatically, "Correct spelling automatically")],
        [(.smartCopyPaste, "Smart copy/paste"),
         (.smartQuotes, "Smart quotes"),
         (.smartDashes, "Smart dashes"),
         (.textReplacement, "Text replacement")],
    ]

    // MARK: Controls (nil until the window is built)

    private(set) var tabView: NSTabView?
    private(set) var widthField: NSTextField?
    private(set) var heightField: NSTextField?
    private(set) var fontNameField: NSTextField?
    private(set) var changeFontButton: NSButton?
    private(set) var openEncodingPopUp: EncodingPopUpButton?
    private(set) var saveEncodingPopUp: EncodingPopUpButton?
    private(set) var restoreButton: NSButton?
    /// Every checkbox, by the default it writes.
    private(set) var checkboxes: [DefaultsKey: NSButton] = [:]
    /// Settings > Keyboard (M9 n3).
    private(set) var keyboardTab: KeyboardTabController?
    /// Tab view heights: the two TextEdit tabs share one, Keyboard is taller,
    /// and the window resizes when the tab changes.
    private var textEditTabsHeight: CGFloat = 0
    private var keyboardTabHeight: CGFloat = 0

    /// The value a size field had when editing began; junk puts it back
    /// (Preferences.m:211-220).
    private var originalDimensionValue = 0

    /// The UserDefaults.didChangeNotification observer.
    private var defaultsObserver: NSObjectProtocol?

    init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SettingsWindowController is built in code") }

    /// True once the window exists. Building the menu bar must not build it.
    var isWindowBuilt: Bool { window != nil }

    override func showWindow(_ sender: Any?) {
        loadSettingsWindowIfNeeded()
        refreshControls()
        super.showWindow(sender)
    }

    // MARK: The window (Preferences.nib)

    /// Layout values from reference/apple/Base.lproj/Preferences.nib, measured
    /// from the top of each tab's content (the nib's y flipped); rows of
    /// dropped rich-text controls are taken out and the rows below move up.
    private enum Layout {
        static let windowWidth: CGFloat = 440            // :57
        static let tabFrame = NSRect(x: 13, y: 36, width: 414, height: 0)  // :104, height fitted
        static let tabTopMargin: CGFloat = 16            // 575 - 36 - 523
        static let restoreFrame = NSRect(x: 14, y: 8, width: 164, height: 32)  // :74
        static let bottomMargin: CGFloat = 20
        static let checkboxHeight: CGFloat = 18
        static let rowStep: CGFloat = 18                 // :895, :1072, :1100
        static let leftColumn: CGFloat = 20
        static let rightColumn: CGFloat = 263            // :1128
        static let leftColumnWidth: CGFloat = 240
        static let rightColumnWidth: CGFloat = 116
    }

    @discardableResult
    func loadSettingsWindowIfNeeded() -> NSWindow {
        if let window { return window }
        let newDocument = makeNewDocumentTab()
        let openAndSave = makeOpenAndSaveTab()
        let keyboard = KeyboardTabController()
        let contentHeight = max(newDocument.frame.height, openAndSave.frame.height)

        let tabs = NSTabView(frame: NSRect(x: Layout.tabFrame.minX, y: Layout.tabFrame.minY,
                                           width: Layout.tabFrame.width, height: 523))
        for (label, view) in [("New Document", newDocument), ("Open and Save", openAndSave),
                              (KeyboardTabController.tabLabel, keyboard.view)] {
            let item = NSTabViewItem(identifier: label)
            item.label = label
            item.view = view
            tabs.addTabViewItem(item)
        }
        // Fit the tab view to the taller TextEdit tab: its frame minus its
        // content area is the tab strip and border, whatever this macOS
        // draws. The Keyboard tab gets its own, taller size.
        let chrome = tabs.frame.height - tabs.contentRect.height
        textEditTabsHeight = contentHeight + chrome
        keyboardTabHeight = keyboard.view.frame.height + chrome
        tabs.setFrameSize(NSSize(width: Layout.tabFrame.width, height: textEditTabsHeight))
        tabs.autoresizingMask = [.height]
        keyboardTab = keyboard

        let restore = NSButton(title: "Restore All Defaults", target: self, action: #selector(restoreAllDefaults(_:)))
        restore.frame = Layout.restoreFrame
        restore.bezelStyle = .push
        restore.identifier = Self.restoreIdentifier
        restore.toolTip = "Restore all preferences to their initial settings."

        let height = tabs.frame.maxY + Layout.tabTopMargin
        let content = NSView(frame: NSRect(x: 0, y: 0, width: Layout.windowWidth, height: height))
        content.addSubview(tabs)
        content.addSubview(restore)

        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = "Settings"
        window.contentView = content
        window.isReleasedWhenClosed = false
        // Preferences.m:65-71.
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = true
        window.identifier = Self.windowIdentifier
        window.restorationClass = SettingsWindowController.self
        window.isRestorable = true
        // Settings never takes tabs (M11).
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()

        tabView = tabs
        restoreButton = restore
        linkKeyViews(window)
        tabs.delegate = self
        self.window = window
        refreshControls()
        // UserDefaults posts this on the thread that wrote the default, which
        // can be a background thread; a selector on this main-actor class
        // would trap there (M6 review row 1). The block runs on the main queue.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshControls() }
        }
        return window
    }

    /// "New Document" (Preferences.nib:1299): Format, Window Size, Font, Options.
    private func makeNewDocumentTab() -> NSView {
        let view = FlippedView(frame: .zero)
        // Format (:923, :1028, :119). The Rich/Plain radio is dropped, so
        // "Wrap to page" moves left under the note.
        view.addSubview(header("Format", top: 3))
        view.addSubview(label("Use the Format menu to choose settings for an open document.",
                              frame: NSRect(x: 20, y: 22, width: 360, height: 14)))
        let wrap = checkbox(.showPageBreaks, "Wrap to page",
                            frame: NSRect(x: 20, y: 38, width: 195, height: Layout.checkboxHeight))
        wrap.toolTip = "Select to make text wrap to document margins rather than window boundaries."
        view.addSubview(wrap)
        // The Paper size pop-up that sat on this row went in 1.2.0; Wrap to
        // Page and PDFs keep the stored size (Defaults.paperSizeKey).

        // Window Size (:948, :365-587).
        view.addSubview(header("Window Size", top: 85))
        view.addSubview(label("Width:", frame: NSRect(x: 20, y: 107, width: 43, height: 14)))
        let width = sizeField(.widthInChars, frame: NSRect(x: 68, y: 104, width: 39, height: 19))
        view.addSubview(width)
        view.addSubview(label("characters", frame: NSRect(x: 112, y: 107, width: 59, height: 14)))
        view.addSubview(label("Height:", frame: NSRect(x: 20, y: 132, width: 43, height: 14)))
        let height = sizeField(.heightInChars, frame: NSRect(x: 68, y: 129, width: 39, height: 19))
        view.addSubview(height)
        view.addSubview(label("lines", frame: NSRect(x: 112, y: 132, width: 29, height: 14)))

        // Font (:968, :598, :638, :688). Only the plain text font row.
        view.addSubview(header("Font", top: 159))
        view.addSubview(label("Plain text font:", frame: NSRect(x: 20, y: 181, width: 83, height: 14)))
        let change = NSButton(title: "Change...", target: self, action: #selector(changePlainTextFont(_:)))
        change.frame = NSRect(x: 103, y: 177, width: 77, height: 24)
        change.bezelStyle = .push
        change.controlSize = .small
        change.font = Self.smallFont
        change.identifier = Self.changeFontIdentifier
        change.setAccessibilityLabel("Change plain text font")
        view.addSubview(change)
        let fontName = label("", frame: NSRect(x: 182, y: 181, width: 198, height: 14))
        fontName.lineBreakMode = .byTruncatingTail
        fontName.identifier = NSUserInterfaceItemIdentifier("PlainTextFontName")
        view.addSubview(fontName)

        // Options (:1008 and the checkboxes). The Properties section and the
        // second font row are dropped, so Options moves up under Font.
        let optionsTop: CGFloat = 217
        view.addSubview(header("Options", top: optionsTop))
        var bottom: CGFloat = 0
        for (column, items) in Self.optionColumns.enumerated() {
            for (row, (key, title)) in items.enumerated() {
                let frame = NSRect(x: column == 0 ? Layout.leftColumn : Layout.rightColumn,
                                   y: optionsTop + 19 + CGFloat(row) * Layout.rowStep,
                                   width: column == 0 ? Layout.leftColumnWidth : Layout.rightColumnWidth,
                                   height: Layout.checkboxHeight)
                let box = checkbox(key, title, frame: frame)
                let spelling: Set<DefaultsKey> = [.checkSpellingWhileTyping, .checkGrammarWithSpelling,
                                                  .correctSpellingAutomatically]
                box.toolTip = spelling.contains(key) ? Self.spellingTip : Self.substitutionsTip
                view.addSubview(box)
                bottom = max(bottom, frame.maxY)
            }
        }

        widthField = width
        heightField = height
        changeFontButton = change
        fontNameField = fontName
        view.setFrameSize(NSSize(width: 394, height: bottom + Layout.bottomMargin))
        return view
    }

    /// "Open and Save" (Preferences.nib:1905): the .txt checkbox and the two
    /// encoding pop-ups. "When Opening a File:" held only the dropped RTF and
    /// HTML checkboxes, so it is left out and the rest moves up.
    private func makeOpenAndSaveTab() -> NSView {
        let view = FlippedView(frame: .zero)
        view.addSubview(header("When Saving a File:", top: 3, x: 17, width: 113))
        let addExtension = checkbox(.addExtensionToNewPlainTextFiles, "Add \".txt\" extension to plain text files",
                                    frame: NSRect(x: 17, y: 22, width: 365, height: Layout.checkboxHeight))
        addExtension.toolTip = "Specify the default setting for the save option which automatically adds "
            + "\".txt\" to the supplied file name if the name does not have a known extension."
        view.addSubview(addExtension)

        view.addSubview(header("Plain Text File Encoding", top: 55, x: 17, width: 141))
        view.addSubview(label("Opening files:", frame: NSRect(x: 17, y: 79, width: 89, height: 14)))
        let opening = encodingPopUp(.plainTextEncoding, frame: NSRect(x: 108, y: 76, width: 275, height: 22))
        opening.toolTip = "Choose the default text encoding to use when opening plain text files. "
            + "To let QuickEdit select the best encoding, choose Automatic."
        view.addSubview(opening)
        view.addSubview(label("Saving files:", frame: NSRect(x: 17, y: 105, width: 89, height: 14)))
        let saving = encodingPopUp(.plainTextEncodingForWrite, frame: NSRect(x: 108, y: 102, width: 275, height: 22))
        saving.toolTip = "Choose the default text encoding to use when saving plain text files. "
            + "To retain the encoding used when opened, choose Automatic."
        view.addSubview(saving)

        openEncodingPopUp = opening
        saveEncodingPopUp = saving
        view.setFrameSize(NSSize(width: 394, height: saving.frame.maxY + Layout.bottomMargin))
        return view
    }

    /// Tab order in reading order on each tab, each a closed loop; the
    /// Width field gets focus first (M6 review row 13).
    private func linkKeyViews(_ window: NSWindow) {
        let options = Self.optionColumns.flatMap { $0 }.compactMap { checkboxes[$0.0] }
        let newDocument: [NSView] = [checkboxes[.showPageBreaks], widthField, heightField, changeFontButton]
            .compactMap { $0 } + options
        let openAndSave: [NSView] = [checkboxes[.addExtensionToNewPlainTextFiles], openEncodingPopUp, saveEncodingPopUp]
            .compactMap { $0 }
        let keyboard = keyboardTab?.keyViews ?? []
        tabKeyLoops = [newDocument, openAndSave, keyboard]
        // NSTabView puts the shown tab's loop between itself and its own
        // next view: tab strip, the tab's controls, then Restore All
        // Defaults, which leads back to the tab strip (M9 review row 4).
        // Measured: with the tab's last control leading out of the tab,
        // NSTabView points it back at the tab strip, and Restore All
        // Defaults was never reached.
        if let tabView, let restoreButton {
            tabView.nextKeyView = restoreButton
            restoreButton.nextKeyView = tabView
        }
        for index in tabKeyLoops.indices { closeKeyLoop(throughRestoreButtonOf: index) }
        window.initialFirstResponder = widthField
    }

    /// The tab's loop, by tab index, without Restore All Defaults.
    private var tabKeyLoops: [[NSView]] = []

    /// Links one tab's controls in reading order, the last one to Restore
    /// All Defaults, and names the first for NSTabView.
    private func closeKeyLoop(throughRestoreButtonOf index: Int) {
        guard let restoreButton, index >= 0, index < tabKeyLoops.count,
              let first = tabKeyLoops[index].first else { return }
        // First responder first: NSTabView relinks the loop then, and drops
        // a control it thinks cannot take the focus (measured: Restore
        // Keyboard Defaults); the links below are the final ones.
        tabView?.tabViewItem(at: index).initialFirstResponder = first
        let loop = tabKeyLoops[index]
        for (position, view) in loop.enumerated() {
            view.nextKeyView = position + 1 < loop.count ? loop[position + 1] : restoreButton
        }
    }

    // MARK: Control builders

    private static var smallFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize(for: .small)) }

    private func header(_ text: String, top: CGFloat, x: CGFloat = 20, width: CGFloat = 200) -> NSTextField {
        let field = label(text, frame: NSRect(x: x, y: top, width: width, height: 14))
        field.font = .boldSystemFont(ofSize: NSFont.systemFontSize(for: .small))
        return field
    }

    private func label(_ text: String, frame: NSRect) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = frame
        field.font = Self.smallFont
        field.controlSize = .small
        return field
    }

    private func checkbox(_ key: DefaultsKey, _ title: String, frame: NSRect) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkboxChanged(_:)))
        box.frame = frame
        box.controlSize = .small
        box.font = Self.smallFont
        box.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
        checkboxes[key] = box
        return box
    }

    /// Whole numbers 1 to 10000 (Preferences.nib:405-460).
    private func sizeField(_ key: DefaultsKey, frame: NSRect) -> NSTextField {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = 10000
        let field = NSTextField(frame: frame)
        field.formatter = formatter
        field.controlSize = .small
        field.font = Self.smallFont
        field.alignment = .natural
        field.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
        // The audit (M9 done-test 1) wants a name; the label beside it is
        // not linked to the field.
        field.setAccessibilityLabel(key == .widthInChars ? "Window width in characters" : "Window height in lines")
        field.target = self
        field.action = #selector(sizeFieldChanged(_:))
        field.cell?.sendsActionOnEndEditing = true
        field.delegate = self
        return field
    }

    private func encodingPopUp(_ key: DefaultsKey, frame: NSRect) -> EncodingPopUpButton {
        let popUp = EncodingPopUpButton(selected: Self.encoding(for: key), includeAutomatic: true)
        popUp.frame = frame
        popUp.controlSize = .small
        popUp.font = Self.smallFont
        popUp.identifier = NSUserInterfaceItemIdentifier(key.rawValue)
        popUp.setAccessibilityLabel(key == .plainTextEncoding ? "Encoding for opening files" : "Encoding for saving files")
        popUp.target = self
        popUp.action = #selector(encodingChanged(_:))
        return popUp
    }

    // MARK: Reading the defaults into the controls

    /// The encoding a default names, or nil for Automatic.
    static func encoding(for key: DefaultsKey) -> String.Encoding? {
        let raw = (Defaults.store.object(forKey: key.rawValue) as? NSNumber)?.intValue ?? Defaults.noStringEncoding
        return raw == Defaults.noStringEncoding ? nil : String.Encoding(rawValue: UInt(raw))
    }

    /// The font name as TextEdit shows it: display name and point size
    /// (reference/apple/FontNameTransformer.m).
    static func fontDescription(_ font: NSFont) -> String {
        let size = font.pointSize.rounded() == font.pointSize ? String(Int(font.pointSize)) : String(Double(font.pointSize))
        return "\(font.displayName ?? font.fontName) \(size)"
    }

    /// Puts every default into its control. A size field the user is typing
    /// in keeps its text.
    func refreshControls() {
        guard window != nil else { return }
        for (key, box) in checkboxes { box.state = Defaults.bool(key) ? .on : .off }
        for (field, key) in [(widthField, DefaultsKey.widthInChars), (heightField, .heightInChars)] {
            guard let field, field.currentEditor() == nil else { continue }
            field.integerValue = Defaults.integer(key)
        }
        fontNameField?.stringValue = Self.fontDescription(plainTextFont)
        select(Self.encoding(for: .plainTextEncoding), in: openEncodingPopUp)
        select(Self.encoding(for: .plainTextEncodingForWrite), in: saveEncodingPopUp)
        keyboardTab?.reload()
    }

    // MARK: Tabs

    /// The tab view's height for `item`.
    func tabHeight(for item: NSTabViewItem?) -> CGFloat {
        (item?.identifier as? String) == KeyboardTabController.tabLabel ? keyboardTabHeight : textEditTabsHeight
    }

    /// Each tab gets its own height; the window keeps its top edge. A
    /// shortcut being recorded is dropped when the tab changes.
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        keyboardTab?.endRecording()
        closeKeyLoop(throughRestoreButtonOf: tabViewItem.map(tabView.indexOfTabViewItem) ?? -1)
        guard let window, let content = window.contentView else { return }
        let height = tabHeight(for: tabViewItem) + Layout.tabFrame.minY + Layout.tabTopMargin
        guard abs(content.frame.height - height) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Layout.windowWidth, height: height))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    /// Selects `encoding` (nil: Automatic). An encoding missing from the
    /// list is shown as an extra item at the top (M6 review row 7).
    private func select(_ encoding: String.Encoding?, in popUp: NSPopUpButton?) {
        guard let popUp else { return }
        let raw = encoding.map { Int($0.rawValue) } ?? Defaults.noStringEncoding
        if let index = popUp.itemArray.firstIndex(where: { ($0.representedObject as? NSNumber)?.intValue == raw }) {
            popUp.selectItem(at: index)
        } else {
            EncodingManager.fill(popUp, selected: encoding, includeAutomatic: true)
        }
    }


    // MARK: Actions: each control writes its default

    @objc func checkboxChanged(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let key = DefaultsKey(rawValue: raw) else { return }
        Defaults.store.set(sender.state == .on, forKey: key.rawValue)
    }

    @objc func sizeFieldChanged(_ sender: NSTextField) {
        guard let raw = sender.identifier?.rawValue, let key = DefaultsKey(rawValue: raw) else { return }
        guard let number = sender.objectValue as? NSNumber else {
            // Emptied: show the value again, keep the default (M6 review row 10).
            sender.integerValue = Defaults.integer(key)
            return
        }
        Defaults.store.set(number.intValue, forKey: key.rawValue)
    }

    @objc func encodingChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue, let key = DefaultsKey(rawValue: raw),
              let number = sender.selectedItem?.representedObject as? NSNumber else { return }
        Defaults.store.set(number.intValue, forKey: key.rawValue)
    }

    /// Preferences.m:182-199, without the rich-text and HTML parts.
    @objc func restoreAllDefaults(_ sender: Any?) {
        // Finish a half-typed size first, so it cannot land after the reset.
        _ = window?.makeFirstResponder(nil)
        keyboardTab?.endRecording()
        Defaults.restoreAll()
        // Restore All also drops the custom keyboard shortcuts.
        if let menu = NSApp.mainMenu { Shortcuts.apply(to: menu) }
        // Line numbers and the map are View menu settings that open
        // windows follow at once; they are back on now.
        ViewOptionsCommand.updateWindows()
        refreshControls()
    }

    // MARK: The plain text font (Preferences.m:92-124)

    /// The font new windows use (13 pt until the user picks one).
    var plainTextFont: NSFont { TextViewFactory.plainFont() }

    /// Stored by AppKit in the `NSFixedPitchFont` defaults; new windows read it.
    func setPlainTextFont(_ font: NSFont?) {
        NSFont.setUserFixedPitch(font)
        fontNameField?.stringValue = Self.fontDescription(plainTextFont)
    }

    @objc func changePlainTextFont(_ sender: Any?) {
        // Validate whatever is being edited first.
        guard window?.makeFirstResponder(nil) ?? true else { return }
        let manager = NSFontManager.shared
        manager.setSelectedFont(plainTextFont, isMultiple: false)
        // Send changeFont: here, not up the responder chain: a size field's
        // field editor would take it there (M6 review row 13). Cleared when
        // the window closes.
        manager.target = self
        manager.orderFrontFontPanel(self)
    }

    /// The Font panel sends this up the responder chain; this window
    /// controller follows its window there.
    func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        setPlainTextFont(sender.convert(plainTextFont))
    }

    /// Face, size and collections only: a plain font has no color or effects.
    func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.face, .size, .collection]
    }

    // MARK: Window and field delegate (Preferences.m:203-220)

    /// Commits a typed size when the window closes without Return or Tab.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if NSFontManager.shared.target === self { NSFontManager.shared.target = nil }
        keyboardTab?.endRecording()
    }

    /// A recording ends when the window is no longer key, so keys typed
    /// in another window are never taken as a shortcut.
    func windowDidResignKey(_ notification: Notification) {
        keyboardTab?.endRecording()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        originalDimensionValue = (notification.object as? NSTextField)?.integerValue ?? 0
    }

    /// Junk or an out-of-range size puts back the value from before editing.
    func control(_ control: NSControl, didFailToFormatString string: String, errorDescription error: String?) -> Bool {
        control.integerValue = originalDimensionValue
        return true
    }

    // MARK: Restoration (Preferences.m:73-77)

    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                              completionHandler: @escaping (NSWindow?, (any Error)?) -> Void) {
        guard identifier == windowIdentifier else {
            completionHandler(nil, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [
                NSLocalizedDescriptionKey: "The Settings window cannot restore a window named \u{201C}\(identifier.rawValue)\u{201D}.",
            ]))
            return
        }
        let window = shared.loadSettingsWindowIfNeeded()
        shared.refreshControls()
        completionHandler(window, nil)
    }
}

/// A view laid out from the top, so nib rows can be placed by their
/// distance from the top of the tab.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Settings > Keyboard (M9 n3, user decisions U2 and U4)

/// The Keyboard tab: mockup A of docs/mockups/M9-keyboard.html. One flat
/// table of every QuickEdit command with a header row per menu and per
/// Edit submenu, each command's shortcut (click it, or select the row and
/// press Return or Space, to record a new one), a reset button on each
/// changed row (or Delete on the selected row), a message line under the
/// table that VoiceOver announces, the App Shortcuts note, and Restore
/// Keyboard Defaults.
@MainActor
final class KeyboardTabController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    // MARK: Strings (docs/mockups/M9-keyboard.html, U4)

    static let tabLabel = "Keyboard"
    static let leadText = "Click a shortcut, then press the new keys."
    static let hintText = "Press Esc to cancel, or Delete to remove the shortcut."
    static let noteText = "Shortcuts set for QuickEdit in System Settings > Keyboard > Keyboard Shortcuts "
        + "> App Shortcuts win over the ones here."
    static let restoreTitle = "Restore Keyboard Defaults"
    static let typeShortcutText = "Type shortcut"
    static let changedSuffix = " (changed)"

    static let tableIdentifier = NSUserInterfaceItemIdentifier("KeyboardShortcutsTable")
    static let messageIdentifier = NSUserInterfaceItemIdentifier("KeyboardShortcutMessage")
    static let restoreIdentifier = NSUserInterfaceItemIdentifier("RestoreKeyboardDefaults")
    static func shortcutButtonIdentifier(_ id: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("Shortcut-" + id)
    }
    static func resetButtonIdentifier(_ id: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("ResetShortcut-" + id)
    }

    /// Mockup A at 1 pt per CSS pixel: 11 pt type, 18 pt rows, a 132 pt
    /// Shortcut column (110 pt key, 22 pt reset), a 30 pt message line.
    private enum Layout {
        static let width: CGFloat = 394
        /// 452 before 1.2.0, plus `bottomSpace`.
        static let height: CGFloat = 464
        /// Space under Restore Keyboard Defaults (1.2.0): it sat on the
        /// tab's bottom edge before.
        static let bottomSpace: CGFloat = 12
        static let side: CGFloat = 2
        static let leadTop: CGFloat = 0
        static let tableTop: CGFloat = 20
        static let messageHeight: CGFloat = 30
        /// The note on two full-width lines, then the button under it: the
        /// longer U4 title leaves the note too narrow beside it.
        static let noteHeight: CGFloat = 30
        /// The note, the button and the space under it.
        static let footHeight: CGFloat = 56 + bottomSpace
        static let rowHeight: CGFloat = 18
        static let shortcutColumn: CGFloat = 132
        static let keyWidth: CGFloat = 110
        static let resetSize: CGFloat = 18
        static let nameInset: CGFloat = 8
        static let subInset: CGFloat = 18
    }

    private static var smallFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize(for: .small)) }
    private static var smallBoldFont: NSFont { .boldSystemFont(ofSize: NSFont.systemFontSize(for: .small)) }

    /// The warning text color of the mockup (#b3261e) in light mode; it
    /// passes 4.5:1 contrast on the window background in both modes.
    static let warningColor = NSColor(name: "QuickEditShortcutWarning") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.54, blue: 0.47, alpha: 1)
            : NSColor(srgbRed: 0.70, green: 0.15, blue: 0.12, alpha: 1)
    }

    /// Dim text (the note, the hint, "(changed)", submenu rows): darker
    /// than secondaryLabelColor, which is 3.9:1 on a light window, so 11 pt
    /// text passes 4.5:1 (mockup A's 62% black header text).
    static let dimTextColor = NSColor(name: "QuickEditShortcutDimText") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.62)
            : NSColor(white: 0, alpha: 0.62)
    }

    /// Menu header rows. A group row swaps labelColor for
    /// secondaryLabelColor, 3.9:1 on a light row (ContrastTests, U8); a
    /// color of its own is kept: 85% black or white.
    static let headerTextColor = NSColor(name: "QuickEditShortcutHeaderText") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.85)
            : NSColor(white: 0, alpha: 0.85)
    }

    // MARK: State

    /// The menu bar whose commands the tab lists and changes.
    private let menuBar: () -> NSMenu?
    private(set) var rows: [Shortcuts.Row] = []
    /// The command being recorded, if any.
    private(set) var recordingID: String?
    private var heldModifiers: NSEvent.ModifierFlags = []
    /// Why the last key pressed while recording was refused.
    private(set) var refusal: Shortcuts.Refusal?
    private var recorder: ShortcutRecorder!

    // MARK: Views

    let view: NSView
    let tableView: KeyboardTableView
    let messageField: NSTextField
    let restoreButton: NSButton

    init(menuBar: @escaping () -> NSMenu? = { NSApp.mainMenu }) {
        self.menuBar = menuBar
        view = KeyboardFlippedView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height))
        tableView = KeyboardTableView(frame: .zero)
        messageField = NSTextField(wrappingLabelWithString: "")
        restoreButton = NSButton(title: Self.restoreTitle, target: nil, action: nil)
        super.init()
        recorder = ShortcutRecorder(handler: { [weak self] outcome in self?.handle(outcome) },
                                    onClick: { [weak self] in self?.endRecording() })
        build()
        reload()
    }

    var isRecording: Bool { recordingID != nil }

    private func build() {
        let innerWidth = Layout.width - 2 * Layout.side
        let lead = NSTextField(labelWithString: Self.leadText)
        lead.font = Self.smallFont
        lead.frame = NSRect(x: Layout.side, y: Layout.leadTop, width: innerWidth, height: 14)
        view.addSubview(lead)

        let footTop = Layout.height - Layout.footHeight
        let messageTop = footTop - Layout.messageHeight
        let scroll = NSScrollView(frame: NSRect(x: Layout.side, y: Layout.tableTop, width: innerWidth,
                                                height: messageTop - Layout.tableTop))
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.autohidesScrollers = true

        tableView.identifier = Self.tableIdentifier
        tableView.setAccessibilityIdentifier(Self.tableIdentifier.rawValue)
        tableView.style = .plain
        tableView.rowHeight = Layout.rowHeight
        tableView.intercellSpacing = .zero
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.focusRingType = .default
        tableView.setAccessibilityLabel("Keyboard shortcuts")
        tableView.keyboardController = self
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Command"))
        nameColumn.title = "Command"
        nameColumn.width = innerWidth - Layout.shortcutColumn - 4
        nameColumn.resizingMask = .autoresizingMask
        let keyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Shortcut"))
        keyColumn.title = "Shortcut"
        keyColumn.width = Layout.shortcutColumn
        keyColumn.minWidth = Layout.shortcutColumn
        keyColumn.maxWidth = Layout.shortcutColumn
        keyColumn.resizingMask = []
        for column in [nameColumn, keyColumn] {
            column.headerCell.font = Self.smallFont
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(recordSelectedRow(_:))
        scroll.documentView = tableView
        view.addSubview(scroll)

        messageField.identifier = Self.messageIdentifier
        messageField.setAccessibilityIdentifier(Self.messageIdentifier.rawValue)
        messageField.setAccessibilityLabel("Shortcut message")
        messageField.font = Self.smallFont
        messageField.frame = NSRect(x: Layout.side, y: messageTop + 2, width: innerWidth, height: Layout.messageHeight - 4)
        messageField.maximumNumberOfLines = 2
        messageField.isSelectable = false
        messageField.setAccessibilityRole(.staticText)
        view.addSubview(messageField)

        restoreButton.target = self
        restoreButton.action = #selector(restoreKeyboardDefaults(_:))
        restoreButton.controlSize = .small
        restoreButton.font = Self.smallFont
        restoreButton.bezelStyle = .push
        restoreButton.identifier = Self.restoreIdentifier
        restoreButton.setAccessibilityIdentifier(Self.restoreIdentifier.rawValue)
        restoreButton.sizeToFit()
        let buttonWidth = restoreButton.frame.width
        let note = NSTextField(wrappingLabelWithString: Self.noteText)
        note.font = Self.smallFont
        note.textColor = Self.dimTextColor
        note.isSelectable = false
        note.frame = NSRect(x: Layout.side, y: footTop, width: innerWidth, height: Layout.noteHeight)
        view.addSubview(note)

        let buttonHeight = restoreButton.frame.height
        restoreButton.frame = NSRect(x: Layout.width - Layout.side - buttonWidth, y: Layout.height - Layout.bottomSpace - buttonHeight,
                                     width: buttonWidth, height: buttonHeight)
        view.addSubview(restoreButton)
    }

    /// The first and last views of the tab's keyboard loop.
    var keyViews: [NSView] { [tableView, restoreButton] }

    // MARK: Data

    /// Rebuilds the rows from the menu bar and redraws them.
    func reload() {
        rows = menuBar().map(Shortcuts.rows(for:)) ?? []
        let selected = recordingID.flatMap(row(of:)) ?? tableView.selectedRow
        tableView.reloadData()
        if selected >= 0, selected < rows.count {
            tableView.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
        updateMessage()
    }

    func command(at row: Int) -> MenuCommand? {
        guard row >= 0, row < rows.count, case let .command(command, _) = rows[row] else { return nil }
        return command
    }

    func row(of id: String) -> Int? {
        rows.firstIndex { if case let .command(command, _) = $0 { command.id == id } else { false } }
    }

    private func currentShortcut(_ command: MenuCommand) -> KeyShortcut {
        Shortcuts.shortcut(for: command, overrides: Shortcuts.overrides())
    }

    /// Saved as a change, or left without its default key because another
    /// command took that key first (M11 upgrade rule): either way the row
    /// says "(changed)" and has a reset button.
    func isChanged(_ command: MenuCommand) -> Bool {
        let overrides = Shortcuts.overrides()
        return overrides[command.id] != nil || Shortcuts.shortcut(for: command, overrides: overrides) != command.defaultShortcut
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .menu = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        command(at: row) != nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .menu(title):
            return label(title, font: Self.smallBoldFont, color: Self.headerTextColor, inset: Layout.nameInset)
        case let .submenu(title):
            guard tableColumn?.identifier.rawValue == "Command" else { return nil }
            return label(title, font: Self.smallBoldFont, color: Self.dimTextColor, inset: Layout.subInset)
        case let .command(command, indented):
            if tableColumn?.identifier.rawValue == "Command" {
                return nameCell(command, inset: indented ? Layout.subInset : Layout.nameInset)
            }
            return shortcutCell(command)
        }
    }

    private func label(_ text: String, font: NSFont, color: NSColor, inset: CGFloat) -> NSView {
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 100, height: Layout.rowHeight))
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: inset),
            field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func nameCell(_ command: MenuCommand, inset: CGFloat) -> NSView {
        let cell = label(command.name, font: Self.smallFont, color: .labelColor, inset: inset)
        if isChanged(command), let field = (cell as? NSTableCellView)?.textField {
            let text = NSMutableAttributedString(string: command.name,
                                                 attributes: [.font: Self.smallFont, .foregroundColor: NSColor.labelColor])
            text.append(NSAttributedString(string: Self.changedSuffix, attributes: [
                .font: Self.smallFont, .foregroundColor: Self.dimTextColor]))
            field.attributedStringValue = text
        }
        return cell
    }

    private func shortcutCell(_ command: MenuCommand) -> NSView {
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: Layout.shortcutColumn, height: Layout.rowHeight))
        let shortcut = currentShortcut(command)
        if recordingID == command.id {
            let field = NSTextField(labelWithString: heldModifiers.isEmpty
                                    ? Self.typeShortcutText : KeyShortcut.display(modifiers: heldModifiers))
            field.font = Self.smallFont
            field.textColor = heldModifiers.isEmpty ? Self.dimTextColor : .labelColor
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            field.wantsLayer = true
            field.layer?.cornerRadius = 3
            field.layer?.borderWidth = 2
            field.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
            field.frame = NSRect(x: 5, y: 1, width: Layout.keyWidth - 6, height: Layout.rowHeight - 2)
            field.setAccessibilityLabel("Recording a new shortcut for \(command.name)")
            field.identifier = Self.shortcutButtonIdentifier(command.id)
            field.setAccessibilityIdentifier(field.identifier?.rawValue)
            cell.addSubview(field)
        } else {
            let button = NSButton(title: shortcut.display, target: self, action: #selector(recordClicked(_:)))
            button.isBordered = false
            button.font = Self.smallFont
            button.alignment = .left
            button.contentTintColor = .labelColor
            button.frame = NSRect(x: 4, y: 0, width: Layout.keyWidth - 4, height: Layout.rowHeight)
            button.identifier = Self.shortcutButtonIdentifier(command.id)
            button.setAccessibilityIdentifier(button.identifier?.rawValue)
            button.setAccessibilityLabel("Shortcut for \(command.name)")
            button.setAccessibilityValue(shortcut.isNone ? "none" : shortcut.display)
            button.setAccessibilityHelp("Records a new shortcut for \(command.name).")
            button.toolTip = "Click, then press the new keys for \(command.name)."
            cell.addSubview(button)
        }
        if isChanged(command) {
            let image = NSImage(systemSymbolName: "arrow.counterclockwise",
                                accessibilityDescription: "Reset \(command.name) to its default shortcut")
            let reset = NSButton(image: image ?? NSImage(), target: self, action: #selector(resetClicked(_:)))
            reset.isBordered = false
            reset.imageScaling = .scaleProportionallyDown
            reset.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            reset.contentTintColor = Self.dimTextColor
            reset.frame = NSRect(x: Layout.keyWidth + (Layout.shortcutColumn - Layout.keyWidth - Layout.resetSize) / 2,
                                 y: 0, width: Layout.resetSize, height: Layout.rowHeight)
            reset.identifier = Self.resetButtonIdentifier(command.id)
            reset.setAccessibilityIdentifier(reset.identifier?.rawValue)
            reset.setAccessibilityLabel("Reset \(command.name) to its default shortcut")
            reset.toolTip = "Reset to default"
            cell.addSubview(reset)
        }
        return cell
    }

    // MARK: Recording

    @objc private func recordClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("Shortcut-") else { return }
        startRecording(String(raw.dropFirst("Shortcut-".count)))
    }

    @objc func recordSelectedRow(_ sender: Any?) {
        guard let command = command(at: tableView.selectedRow) else { return }
        startRecording(command.id)
    }

    /// Starts recording a new shortcut for the command `id`.
    func startRecording(_ id: String) {
        guard let index = row(of: id) else { return }
        recorder.stop()
        recordingID = id
        heldModifiers = []
        refusal = nil
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        tableView.window?.makeFirstResponder(tableView)
        recorder.start()
        reloadRow(index)
        updateMessage()
        if let command = command(at: index) {
            announce("Recording a new shortcut for \(command.name). " + Self.hintText)
        }
    }

    /// Ends recording with no change.
    func endRecording() {
        recorder.stop()
        let index = recordingID.flatMap(row(of:))
        recordingID = nil
        heldModifiers = []
        refusal = nil
        if let index { reloadRow(index) }
        updateMessage()
    }

    /// One key event's meaning while recording (from ShortcutRecorder, or a test).
    func handle(_ outcome: ShortcutRecorder.Outcome) {
        guard let id = recordingID, let index = row(of: id), let command = command(at: index) else { return }
        switch outcome {
        case .cancel:
            endRecording()
        case .remove:
            Shortcuts.set(.empty, for: command, applyingTo: menuBar())
            endRecording()
            reload()
            announce("\(command.name) has no shortcut now.")
        case let .modifiers(flags):
            heldModifiers = flags
            reloadRow(index)
        case let .candidate(shortcut):
            heldModifiers = []
            if let refused = Shortcuts.refusal(for: shortcut, command: command, in: menuBar()) {
                refusal = refused
                reloadRow(index)
                updateMessage()
                announce(refused.message)
                return
            }
            Shortcuts.set(shortcut, for: command, applyingTo: menuBar())
            endRecording()
            reload()
            announce("The shortcut for \(command.name) is now \(currentShortcut(command).display).")
        }
    }

    @objc private func resetClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("ResetShortcut-"),
              let index = row(of: String(raw.dropFirst("ResetShortcut-".count))) else { return }
        resetRow(index)
    }

    /// Puts the command on `row` back to its default shortcut, unless
    /// another command has that key now: then the reset is refused with
    /// the clash message, and both keys stay (M9 review row 1).
    func resetRow(_ row: Int) {
        guard let command = command(at: row), isChanged(command) else { return }
        if recordingID != nil { endRecording() }
        if let refused = Shortcuts.resetRefusal(for: command, in: menuBar()) {
            refusal = refused
            updateMessage()
            announce(refused.message)
            return
        }
        refusal = nil
        Shortcuts.set(nil, for: command, applyingTo: menuBar())
        reload()
        announce("\(command.name) is back to its default shortcut \(command.defaultShortcut.display).")
    }

    @objc func restoreKeyboardDefaults(_ sender: Any?) {
        if recordingID != nil { endRecording() }
        refusal = nil
        Shortcuts.restoreDefaults(applyingTo: menuBar())
        reload()
        announce("Every keyboard shortcut is back to its default.")
    }

    private func reloadRow(_ row: Int) {
        guard row >= 0, row < rows.count else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<2))
    }

    /// The line under the table: the refusal (of a recorded key or of a
    /// reset), or the hint while recording.
    private func updateMessage() {
        guard let refusal else {
            guard isRecording else {
                messageField.stringValue = ""
                return
            }
            messageField.attributedStringValue = NSAttributedString(string: Self.hintText, attributes: [
                .font: Self.smallFont, .foregroundColor: Self.dimTextColor])
            return
        }
        let text = NSMutableAttributedString()
        let config = NSImage.SymbolConfiguration(paletteColors: [.black, .systemYellow])
        if let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")?
            .withSymbolConfiguration(config) {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            attachment.bounds = NSRect(x: 0, y: -2, width: 12, height: 11)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " "))
        }
        let message = refusal.message
        let plain: [NSAttributedString.Key: Any] = [.font: Self.smallFont, .foregroundColor: Self.warningColor]
        let body = NSMutableAttributedString(string: message, attributes: plain)
        if let keys = refusal.keysText, message.hasPrefix(keys) {
            body.addAttribute(.font, value: Self.smallBoldFont, range: NSRange(location: 0, length: (keys as NSString).length))
        }
        text.append(body)
        messageField.attributedStringValue = text
        messageField.setAccessibilityValue(message)
    }

    /// Spoken by VoiceOver without moving the focus (U4).
    private func announce(_ text: String) {
        NSAccessibility.post(element: messageField, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

/// The Keyboard tab's table: Return or Space records the selected row's
/// shortcut, Delete puts it back to its default (U4: both from the keyboard).
final class KeyboardTableView: NSTableView {
    weak var keyboardController: KeyboardTabController?

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection(KeyShortcut.modifierMask).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76, 49:   // Return, Enter, Space
            keyboardController?.recordSelectedRow(self)
        case 51, 117:      // Delete, Forward Delete
            if selectedRow >= 0 { keyboardController?.resetRow(selectedRow) }
        default:
            super.keyDown(with: event)
        }
    }
}

private final class KeyboardFlippedView: NSView {
    override var isFlipped: Bool { true }
}
