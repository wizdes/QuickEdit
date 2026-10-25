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
        style.defaultTabInterval = CGFloat(max(1, Defaults.store.integer(forKey: DefaultsKey.tabWidth.rawValue)))
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

    /// The one layout manager a window shares between its text views
    /// (one in Wrap to Window, one per page in Wrap to Page).
    @MainActor
    static func makeLayoutManager() -> NSLayoutManager {
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        return layoutManager
    }

    /// A text view for tests and for one-view use: its own layout manager on `storage`.
    @MainActor
    static func makeTextView(storage: NSTextStorage, size: NSSize) -> NSTextView {
        let layoutManager = makeLayoutManager()
        let (textView, container) = makeWindowModeTextView(size: size)
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        configureSharedState(textView)
        configureTypingAttributes(textView)
        return textView
    }

    /// Wrap to Window: a container as wide as the view and endlessly tall;
    /// the view grows down and follows the window's width
    /// (reference/apple/DocumentWindowController.m:566-589). The caller adds
    /// the container to a layout manager, which then owns it: in TextKit 1 a
    /// text view does not keep its container alive.
    @MainActor
    static func makeWindowModeTextView(size: NSSize) -> (NSTextView, NSTextContainer) {
        let container = NSTextContainer(size: NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        let textView = NSTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        return (textView, container)
    }

    /// Wrap to Page: a fixed-size view and container for one page
    /// (DocumentWindowController.m:459-495). The caller adds the container
    /// to the layout manager, which then owns it.
    @MainActor
    static func makePageTextView(frame: NSRect) -> (NSTextView, NSTextContainer) {
        let container = NSTextContainer(size: frame.size)
        container.widthTracksTextView = true
        container.heightTracksTextView = true
        let textView = NSTextView(frame: frame, textContainer: container)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        // Draw only inside the page's text area, so the frame line around it shows.
        textView.clipsToBounds = true
        return (textView, container)
    }

    /// Settings every text view on one layout manager shares (AppKit keeps
    /// them once per layout manager), set on the first view
    /// (DocumentWindowController.m:174-201).
    @MainActor
    static func configureSharedState(_ textView: NSTextView) {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticLinkDetectionEnabled = false

        // Spelling and substitutions from Defaults (reference/apple/DocumentWindowController.m:187-198).
        textView.isContinuousSpellCheckingEnabled = Defaults.bool(.checkSpellingWhileTyping)
        textView.isGrammarCheckingEnabled = Defaults.bool(.checkGrammarWithSpelling)
        textView.isAutomaticSpellingCorrectionEnabled = Defaults.bool(.correctSpellingAutomatically)
        textView.smartInsertDeleteEnabled = Defaults.bool(.smartCopyPaste)
        textView.isAutomaticQuoteSubstitutionEnabled = Defaults.bool(.smartQuotes)
        textView.isAutomaticDashSubstitutionEnabled = Defaults.bool(.smartDashes)
        textView.isAutomaticDataDetectionEnabled = Defaults.bool(.dataDetectors)
        textView.isAutomaticTextReplacementEnabled = Defaults.bool(.textReplacement)
    }

    /// Large-file mode (M8 n2): every check that works on the text while
    /// it is typed, off for this layout manager's views. Settings stay as
    /// they are.
    @MainActor
    static func turnOffChecks(_ textView: NSTextView) {
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
    }

    /// The checks `turnOffChecks` turns off, as one window has them, so
    /// they can be put back when the file is no longer large (M8 review row 2).
    struct TypingChecks: Equatable {
        var spelling, grammar, correction, quotes, dashes, dataDetection, replacement: Bool

        @MainActor
        init(of textView: NSTextView) {
            spelling = textView.isContinuousSpellCheckingEnabled
            grammar = textView.isGrammarCheckingEnabled
            correction = textView.isAutomaticSpellingCorrectionEnabled
            quotes = textView.isAutomaticQuoteSubstitutionEnabled
            dashes = textView.isAutomaticDashSubstitutionEnabled
            dataDetection = textView.isAutomaticDataDetectionEnabled
            replacement = textView.isAutomaticTextReplacementEnabled
        }

        @MainActor
        func apply(to textView: NSTextView) {
            textView.isContinuousSpellCheckingEnabled = spelling
            textView.isGrammarCheckingEnabled = grammar
            textView.isAutomaticSpellingCorrectionEnabled = correction
            textView.isAutomaticQuoteSubstitutionEnabled = quotes
            textView.isAutomaticDashSubstitutionEnabled = dashes
            textView.isAutomaticDataDetectionEnabled = dataDetection
            textView.isAutomaticTextReplacementEnabled = replacement
        }
    }

    /// Plain font and tab stops for each new view
    /// (DocumentWindowController.m:404-412).
    @MainActor
    static func configureTypingAttributes(_ textView: NSTextView) {
        let attributes = plainTextAttributes()
        textView.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        textView.typingAttributes = attributes
    }
}
