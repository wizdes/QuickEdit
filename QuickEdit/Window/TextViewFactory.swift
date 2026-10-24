import AppKit

/// Builds TextKit 1 text views (contract `win-text`, Doc B sections 1 and 3).
/// Always storage -> NSLayoutManager -> NSTextContainer -> NSTextView(frame:textContainer:);
/// never the frame-only NSTextView initializer, which makes a TextKit 2 view.
enum TextViewFactory {
    /// The plain-text font: the user's fixed-pitch font at its default size.
    static func plainFont() -> NSFont {
        NSFont.userFixedPitchFont(ofSize: 0) ?? NSFont.monospacedSystemFont(ofSize: 0, weight: .regular)
    }

    /// Width of one "x" in the plain font, measured with string sizing.
    static func xAdvance(of font: NSFont) -> CGFloat {
        ("x" as NSString).size(withAttributes: [.font: font]).width
    }

    /// ascender - descender + leading, rounded up.
    static func lineHeight(of font: NSFont) -> CGFloat {
        (font.ascender - font.descender + font.leading).rounded(.up)
    }

    /// Tab stops every `TabWidth` x-advances (default 8). Safe off the main thread.
    static func plainParagraphStyle(font: NSFont) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = CGFloat(max(1, UserDefaults.standard.integer(forKey: DefaultsKey.tabWidth.rawValue)))
            * xAdvance(of: font)
        return style
    }

    /// Attributes for every character of a plain document. Safe off the main thread.
    static func plainTextAttributes() -> [NSAttributedString.Key: Any] {
        let font = plainFont()
        // textColor is a dynamic color, so stored text follows light and dark mode.
        return [.font: font, .paragraphStyle: plainParagraphStyle(font: font), .foregroundColor: NSColor.textColor]
    }

    /// Text area size for a new window: WidthInChars x-advances plus padding
    /// on both sides, by HeightInChars lines.
    static func initialContentSize() -> NSSize {
        let font = plainFont()
        let padding = NSTextContainer().lineFragmentPadding
        let columns = CGFloat(max(1, Defaults.integer(.widthInChars)))
        let rows = CGFloat(max(1, Defaults.integer(.heightInChars)))
        return NSSize(width: (columns * xAdvance(of: font) + 2 * padding).rounded(.up),
                      height: rows * lineHeight(of: font))
    }

    @MainActor
    static func makeTextView(storage: NSTextStorage, size: NSSize) -> NSTextView {
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false

        let attributes = plainTextAttributes()
        textView.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        textView.typingAttributes = attributes

        // Spelling and substitutions from Defaults (reference/apple/DocumentWindowController.m:187-198).
        textView.isContinuousSpellCheckingEnabled = Defaults.bool(.checkSpellingWhileTyping)
        textView.isGrammarCheckingEnabled = Defaults.bool(.checkGrammarWithSpelling)
        textView.isAutomaticSpellingCorrectionEnabled = Defaults.bool(.correctSpellingAutomatically)
        textView.smartInsertDeleteEnabled = Defaults.bool(.smartCopyPaste)
        textView.isAutomaticQuoteSubstitutionEnabled = Defaults.bool(.smartQuotes)
        textView.isAutomaticDashSubstitutionEnabled = Defaults.bool(.smartDashes)
        textView.isAutomaticDataDetectionEnabled = Defaults.bool(.dataDetectors)
        textView.isAutomaticTextReplacementEnabled = Defaults.bool(.textReplacement)
        return textView
    }
}
