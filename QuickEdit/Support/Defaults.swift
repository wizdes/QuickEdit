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
    /// TextEdit's `NoStringEncoding` (EncodingManager.h:54): "Automatic" or "none".
    static let noStringEncoding: Int = 0xFFFF_FFFF

    /// Registered once at launch, before any window.
    @MainActor
    static func register() {
        UserDefaults.standard.register(defaults: registeredValues())
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
            DefaultsKey.checkSpellingWhileTyping.rawValue: true,
            DefaultsKey.checkGrammarWithSpelling.rawValue: false,
            DefaultsKey.correctSpellingAutomatically.rawValue: NSSpellChecker.isAutomaticSpellingCorrectionEnabled,
            DefaultsKey.smartCopyPaste.rawValue: true,
            DefaultsKey.smartQuotes.rawValue: false,
            DefaultsKey.smartDashes.rawValue: false,
            DefaultsKey.dataDetectors.rawValue: false,
            DefaultsKey.textReplacement.rawValue: NSSpellChecker.isAutomaticTextReplacementEnabled,
            DefaultsKey.autosavingDelay.rawValue: 30,
            DefaultsKey.numberPagesWhenPrinting.rawValue: false,
            DefaultsKey.wrapToFitWhenPrinting.rawValue: true,
            // Not a TextEdit key: QuickEdit always opens one untitled window at
            // launch instead of the app-centric Open panel (root's M1 item 7).
            "NSShowAppCentricOpenPanelInsteadOfUntitledFile": false,
        ]
    }

    static func bool(_ key: DefaultsKey) -> Bool { UserDefaults.standard.bool(forKey: key.rawValue) }
    static func integer(_ key: DefaultsKey) -> Int { UserDefaults.standard.integer(forKey: key.rawValue) }
}
