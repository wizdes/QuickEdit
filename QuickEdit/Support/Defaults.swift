import AppKit

/// Every user default QuickEdit keeps from TextEdit (docs/codemap.md section 3),
/// with the values from Doc B section 5.
enum DefaultsKey: String, CaseIterable {
    case showPageBreaks = "ShowPageBreaks"
    case addExtensionToNewPlainTextFiles = "AddExtensionToNewPlainTextFiles"
    case widthInChars = "WidthInChars"
    case heightInChars = "HeightInChars"
    case plainTextEncoding = "PlainTextEncoding"
    case plainTextEncodingForWrite = "PlainTextEncodingForWrite"
    case tabWidth = "TabWidth"
    case checkSpellingWhileTyping = "CheckSpellingWhileTyping"
    case checkGrammarWithSpelling = "CheckGrammarWithSpelling"
    case correctSpellingAutomatically = "CorrectSpellingAutomatically"
    case smartCopyPaste = "SmartCopyPaste"
    case smartQuotes = "SmartQuotes"
    case smartDashes = "SmartDashes"
    case dataDetectors = "DataDetectors"
    case textReplacement = "TextReplacement"
    case autosavingDelay = "AutosavingDelay"
    case numberPagesWhenPrinting = "NumberPagesWhenPrinting"
    case wrapToFitWhenPrinting = "WrapToFitWhenPrinting"
    /// Array of encoding numbers. Read and written by the encodings list in M3;
    /// it has no registered value, as in TextEdit.
    case encodings = "Encodings"
}

enum Defaults {
    /// Where QuickEdit reads and writes its settings: `.standard` in the app.
    /// Tests put a suite of their own here, so they never write the user's
    /// real settings (M6 review row 14). Set only on the main thread, before
    /// the code under test runs; read from any thread.
    nonisolated(unsafe) static var store: UserDefaults = launchStore(arguments: ProcessInfo.processInfo.arguments)

    /// `.standard`, except in a Debug build launched with
    /// `-QETestDefaultsSuite <name>`: then that suite, so a UI test can
    /// change settings and relaunch without touching the user's real
    /// settings. `-QETestDefaultsSuiteReset YES` empties the suite first.
    static func launchStore(arguments: [String]) -> UserDefaults {
        #if DEBUG
        if let index = arguments.firstIndex(of: "-QETestDefaultsSuite"), index + 1 < arguments.count {
            let name = arguments[index + 1]
            guard let suite = UserDefaults(suiteName: name) else {
                FileHandle.standardError.write(Data("QuickEdit: -QETestDefaultsSuite \(name) cannot be opened; using the standard settings\n".utf8))
                return .standard
            }
            if let reset = arguments.firstIndex(of: "-QETestDefaultsSuiteReset"), reset + 1 < arguments.count,
               arguments[reset + 1] == "YES" {
                suite.removePersistentDomain(forName: name)
            }
            return suite
        }
        #endif
        return .standard
    }

    /// Settings > Keyboard (M9, user decision U2): the user's changed
    /// shortcuts only, command id to `KeyShortcut.storedValue`. Not
    /// registered: the default set lives in MainMenu.swift.
    static let keyboardShortcutsKey = "KeyboardShortcuts"

    /// The paper size for Wrap to Page and PDFs (M7): a `PaperSize` raw
    /// value. Its Settings pop-up went in 1.2.0; the stored value (the
    /// region's size unless set before) is still used. Not a TextEdit key
    /// (TextEdit took the size from Page Setup), so it is kept out of
    /// `DefaultsKey`. It is registered, so Restore All Defaults puts the
    /// region's size back.
    static let paperSizeKey = "PaperSize"

    /// View > Show Line Numbers (1.2.0): the gutter on the left of every
    /// document window. Not a TextEdit key, so kept out of `DefaultsKey`.
    static let showLineNumbersKey = "ShowLineNumbers"

    /// View > Show Document Map (1.2.0): the map on the right of every
    /// document window. Not a TextEdit key.
    static let showDocumentMapKey = "ShowDocumentMap"

    /// TextEdit's `NoStringEncoding` (EncodingManager.h:54): "Automatic" or "none".
    static let noStringEncoding: Int = 0xFFFF_FFFF

    /// Registered once at launch, before any window.
    @MainActor
    static func register() {
        store.register(defaults: registeredValues())
    }

    @MainActor
    static func registeredValues() -> [String: Any] {
        [
            DefaultsKey.showPageBreaks.rawValue: false,
            DefaultsKey.addExtensionToNewPlainTextFiles.rawValue: true,
            DefaultsKey.widthInChars.rawValue: 90,
            DefaultsKey.heightInChars.rawValue: 30,
            DefaultsKey.plainTextEncoding.rawValue: noStringEncoding,
            DefaultsKey.plainTextEncodingForWrite.rawValue: noStringEncoding,
            DefaultsKey.tabWidth.rawValue: 8,
            // Off, as in Sublime Text (1.2.0); TextEdit has them on.
            DefaultsKey.checkSpellingWhileTyping.rawValue: false,
            DefaultsKey.checkGrammarWithSpelling.rawValue: false,
            DefaultsKey.correctSpellingAutomatically.rawValue: false,
            DefaultsKey.smartCopyPaste.rawValue: true,
            DefaultsKey.smartQuotes.rawValue: false,
            DefaultsKey.smartDashes.rawValue: false,
            // No longer read (new windows always start with data detectors
            // off, 1.2.0); kept registered so Restore All Defaults clears it.
            DefaultsKey.dataDetectors.rawValue: false,
            DefaultsKey.textReplacement.rawValue: NSSpellChecker.isAutomaticTextReplacementEnabled,
            DefaultsKey.autosavingDelay.rawValue: 30,
            DefaultsKey.numberPagesWhenPrinting.rawValue: false,
            DefaultsKey.wrapToFitWhenPrinting.rawValue: true,
            paperSizeKey: PaperSize.regionDefault(for: .current).rawValue,
            showLineNumbersKey: true,
            showDocumentMapKey: true,
            // Not a TextEdit key: QuickEdit always opens one untitled window at
            // launch instead of the app-centric Open panel (root's M1 item 7).
            "NSShowAppCentricOpenPanelInsteadOfUntitledFile": false,
        ]
    }

    /// Settings > "Restore All Defaults" (reference/apple/Preferences.m:182-199):
    /// every registered key goes back to its registered value, every custom
    /// keyboard shortcut goes, and the plain
    /// font goes back to the system's fixed-pitch font at 13 pt
    /// (TextViewFactory.plainFont). `Encodings` has no
    /// registered value, so the encodings list stays, as in TextEdit.
    @MainActor
    static func restoreAll() {
        let defaults = store
        for key in registeredValues().keys { defaults.removeObject(forKey: key) }
        // The Keyboard tab is part of Settings, so its changes go too; the
        // caller re-applies the menu bar's shortcuts.
        defaults.removeObject(forKey: keyboardShortcutsKey)
        NSFont.setUserFixedPitch(nil)
    }

    static func bool(_ key: DefaultsKey) -> Bool { store.bool(forKey: key.rawValue) }
    static func integer(_ key: DefaultsKey) -> Int { store.integer(forKey: key.rawValue) }
}
