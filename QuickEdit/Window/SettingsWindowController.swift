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
    NSWindowRestoration, NSFontChanging {
    static let shared = SettingsWindowController()

    /// TextEdit's window identifier (Preferences.m:69).
    static let windowIdentifier = NSUserInterfaceItemIdentifier("Preferences")
    static let restoreIdentifier = NSUserInterfaceItemIdentifier("RestoreAllDefaults")
    static let changeFontIdentifier = NSUserInterfaceItemIdentifier("ChangePlainTextFont")

    // MARK: Strings (macOS 27 TextEdit, Preferences.loctable)

    private static let spellingTip = "Choose Edit > Spelling and Grammar to change this option for individual documents."
    private static let substitutionsTip = "Choose Edit > Substitutions to change this option for individual documents."

    /// The Options checkboxes, two columns of four, top to bottom
    /// (Preferences.nib:867-1290 without "Show ruler" and "Smart links").
    static let optionColumns: [[(DefaultsKey, String)]] = [
        [(.checkSpellingWhileTyping, "Check spelling as you type"),
         (.checkGrammarWithSpelling, "Check grammar with spelling"),
         (.correctSpellingAutomatically, "Correct spelling automatically"),
         (.dataDetectors, "Data detectors")],
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

    /// The value a size field had when editing began; junk puts it back
    /// (Preferences.m:211-220).
    private var originalDimensionValue = 0

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
        let contentHeight = max(newDocument.frame.height, openAndSave.frame.height)

        let tabs = NSTabView(frame: NSRect(x: Layout.tabFrame.minX, y: Layout.tabFrame.minY,
                                           width: Layout.tabFrame.width, height: 523))
        for (label, view) in [("New Document", newDocument), ("Open and Save", openAndSave)] {
            let item = NSTabViewItem(identifier: label)
            item.label = label
            item.view = view
            tabs.addTabViewItem(item)
        }
        // Fit the tab view to the taller tab: its frame minus its content
        // area is the tab strip and border, whatever this macOS draws.
        let chrome = tabs.frame.height - tabs.contentRect.height
        tabs.setFrameSize(NSSize(width: Layout.tabFrame.width, height: contentHeight + chrome))

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
        window.delegate = self
        window.center()

        tabView = tabs
        restoreButton = restore
        self.window = window
        refreshControls()
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged(_:)),
                                               name: UserDefaults.didChangeNotification, object: nil)
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
        popUp.target = self
        popUp.action = #selector(encodingChanged(_:))
        return popUp
    }

    // MARK: Reading the defaults into the controls

    /// The encoding a default names, or nil for Automatic.
    static func encoding(for key: DefaultsKey) -> String.Encoding? {
        let raw = (UserDefaults.standard.object(forKey: key.rawValue) as? NSNumber)?.intValue ?? Defaults.noStringEncoding
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
    }

    /// Selects `encoding` (nil: Automatic). An encoding missing from the
    /// list shows as Automatic, though the default keeps its value.
    private func select(_ encoding: String.Encoding?, in popUp: NSPopUpButton?) {
        guard let popUp else { return }
        let raw = encoding.map { Int($0.rawValue) } ?? Defaults.noStringEncoding
        let index = popUp.itemArray.firstIndex { ($0.representedObject as? NSNumber)?.intValue == raw } ?? 0
        popUp.selectItem(at: index)
    }

    @objc private func defaultsChanged(_ notification: Notification) {
        refreshControls()
    }

    // MARK: Actions: each control writes its default

    @objc func checkboxChanged(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let key = DefaultsKey(rawValue: raw) else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: key.rawValue)
    }

    @objc func sizeFieldChanged(_ sender: NSTextField) {
        guard let raw = sender.identifier?.rawValue, let key = DefaultsKey(rawValue: raw),
              let number = sender.objectValue as? NSNumber else { return }
        UserDefaults.standard.set(number.intValue, forKey: key.rawValue)
    }

    @objc func encodingChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue, let key = DefaultsKey(rawValue: raw),
              let number = sender.selectedItem?.representedObject as? NSNumber else { return }
        UserDefaults.standard.set(number.intValue, forKey: key.rawValue)
    }

    /// Preferences.m:182-199, without the rich-text and HTML parts.
    @objc func restoreAllDefaults(_ sender: Any?) {
        // Finish a half-typed size first, so it cannot land after the reset.
        _ = window?.makeFirstResponder(nil)
        Defaults.restoreAll()
        refreshControls()
    }

    // MARK: The plain text font (Preferences.m:92-124)

    var plainTextFont: NSFont {
        NSFont.userFixedPitchFont(ofSize: 0) ?? .monospacedSystemFont(ofSize: 0, weight: .regular)
    }

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
