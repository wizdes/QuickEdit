import AppKit

/// Edit > Find > Select Line... (Cmd+L). A port of TextEdit 1.9's
/// LinePanelController (reference/apple/LinePanelController.m), built in code
/// from reference/apple/Base.lproj/SelectLinePanel.nib.
///
/// The controller is a plain object until the panel is first shown; the
/// panel itself is built by `loadPanelIfNeeded()` on first use (Doc B
/// section 7, rule 3). A controller made with `init(window: nil)` counts as
/// loaded, so AppKit never calls `loadWindow()`; hence the explicit call. The panel keeps its frame through window restoration, like
/// TextEdit's panel (identifier "Line", autosave name "SelectLine").
@MainActor
final class LinePanelController: NSWindowController, NSWindowRestoration {
    static let shared = LinePanelController()

    /// TextEdit's error domain and codes (reference/apple/TextEditErrors.h:50-59),
    /// under QuickEdit's bundle ID.
    static let errorDomain = "dev.yili.QuickEdit"
    enum ErrorCode: Int {
        case invalidLineSpecification = 200
        case outOfRangeLineSpecification = 201
    }

    static let panelIdentifier = NSUserInterfaceItemIdentifier("Line")
    static let frameAutosaveName = "SelectLine"

    private(set) var lineField: NSTextField?

    /// The window Select Line acts on. AppKit's main window; tests replace it,
    /// because a unit-test host has no main window while the screen is locked.
    var mainWindow: @MainActor () -> NSWindow? = { NSApp.mainWindow }

    init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("LinePanelController is built in code") }

    /// True once the panel exists. Building the menu bar must not build it.
    var isPanelBuilt: Bool { window != nil }

    override func showWindow(_ sender: Any?) {
        loadPanelIfNeeded()
        super.showWindow(sender)
    }

    // MARK: The panel (SelectLinePanel.nib)

    @discardableResult
    func loadPanelIfNeeded() -> NSWindow {
        if let window { return window }
        // Sizes and strings from reference/apple/Base.lproj/SelectLinePanel.nib
        // and the English SelectLinePanel.loctable in macOS 27's TextEdit.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 253, height: 62),
                            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.title = "Select Line"
        panel.contentMinSize = NSSize(width: 213, height: 30)
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false

        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 138, height: 22))
        field.placeholderString = "Line number"
        field.toolTip = "Type a line number (e.g., 5), line number range (e.g., 10-20), "
            + "or relative line number (e.g., -5)."
        field.setAccessibilityLabel("line number")
        field.setAccessibilityIdentifier("QELineField")
        field.target = self
        field.action = #selector(lineFieldChanged(_:))

        let button = NSButton(title: "Select", target: self, action: #selector(selectClicked(_:)))
        button.frame = NSRect(x: 162, y: 13, width: 77, height: 32)
        button.bezelStyle = .push
        button.keyEquivalent = "\r"

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 253, height: 62))
        content.addSubview(field)
        content.addSubview(button)
        panel.contentView = content
        panel.initialFirstResponder = field

        panel.identifier = Self.panelIdentifier
        panel.restorationClass = LinePanelController.self
        panel.isRestorable = true
        // A saved frame puts the panel back where it was; otherwise it opens
        // centered, not at the content rect's (0,0).
        if !panel.setFrameUsingName(Self.frameAutosaveName) {
            panel.center()
        }
        panel.setFrameAutosaveName(Self.frameAutosaveName)

        lineField = field
        window = panel
        return panel
    }

    /// Reopens the panel when the app's saved state is restored
    /// (reference/apple/LinePanelController.m:67-73).
    /// Any other identifier is not this class's window: AppKit gets an error.
    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                              completionHandler: @escaping (NSWindow?, (any Error)?) -> Void) {
        guard identifier == panelIdentifier else {
            completionHandler(nil, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [
                NSLocalizedDescriptionKey: "The Select Line panel cannot restore a window named \u{201C}\(identifier.rawValue)\u{201D}.",
            ]))
            return
        }
        completionHandler(shared.loadPanelIfNeeded(), nil)
    }

    // MARK: Actions

    /// Return in the field: select, and close the panel on success
    /// (reference/apple/LinePanelController.m:162-172).
    @objc func lineFieldChanged(_ sender: Any?) {
        guard let field = sender as? NSTextField ?? lineField else { return }
        if field.stringValue.isEmpty { return }
        do {
            try selectLinesInMainWindow(field.stringValue)
            window?.orderOut(nil)
        } catch {
            report(error)
        }
    }

    /// The Select button: select, and leave the panel open
    /// (reference/apple/LinePanelController.m:176-182).
    @objc func selectClicked(_ sender: Any?) {
        guard let field = lineField, !field.stringValue.isEmpty else { return }
        do {
            try selectLinesInMainWindow(field.stringValue)
        } catch {
            report(error)
        }
    }

    /// TextEdit shows the error on the panel; the M4 plan also asks for a beep.
    private func report(_ error: Error) {
        NSSound.beep()
        guard let window else { return }
        window.presentError(error)
        window.makeKeyAndOrderFront(nil)
    }

    /// Selects in the main window's text, as TextEdit does; does nothing
    /// when the main window has no text view.
    func selectLinesInMainWindow(_ description: String) throws {
        guard let textView = Self.documentTextView(in: mainWindow()) else { return }
        try Self.selectLines(description, in: textView)
    }

    /// The window's first responder when it is a text view, as in TextEdit.
    /// A field editor (the find bar's field, for one) is skipped for the
    /// window's document text view.
    static func documentTextView(in window: NSWindow?) -> NSTextView? {
        guard let window else { return nil }
        if let textView = window.firstResponder as? NSTextView, !textView.isFieldEditor {
            return textView
        }
        return (window.windowController as? DocumentWindowController)?.textView
    }

    /// Parses `description`, selects those lines in `textView` and scrolls to them.
    /// Throws TextEdit's "Invalid line specification" error otherwise.
    static func selectLines(_ description: String, in textView: NSTextView) throws {
        guard let spec = LineSpec.parse(description) else {
            throw lineError(.invalidLineSpecification, description)
        }
        guard let range = spec.range(in: textView.string as NSString, selection: textView.selectedRange()) else {
            throw lineError(.outOfRangeLineSpecification, description)
        }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    static func lineError(_ code: ErrorCode, _ description: String) -> NSError {
        NSError(domain: errorDomain, code: code.rawValue, userInfo: [
            NSLocalizedDescriptionKey: "Invalid line specification \u{201C}\(truncated(description, 100))\u{201D}.",
            NSLocalizedRecoverySuggestionErrorKey: "Enter a line number or a range of line numbers to select.",
        ])
    }

    /// TextEdit's truncatedString (reference/apple/Document.m:1328-1332).
    static func truncated(_ string: String, _ limit: Int) -> String {
        let ns = string as NSString
        if ns.length < limit { return string }
        return ns.substring(to: limit - 10) + "\u{2026}"
    }
}

/// A parsed Select Line entry: `N`, `N-M`, `+N`, `-N`, `+N-M` or `-N-M`
/// (reference/apple/LinePanelController.m:77-87). `relative` is 1 for "+",
/// -1 for "-", 0 for an absolute line number (the first line is 1).
struct LineSpec: Equatable, Sendable {
    var from: Int
    var to: Int
    var relative: Int

    /// A port of parseLineDescription:. Spaces are skipped; anything left over is an error.
    static func parse(_ description: String) -> LineSpec? {
        let scanner = Scanner(string: description)
        scanner.locale = Locale.current
        let relative = scanner.scanString("+") != nil ? 1 : (scanner.scanString("-") != nil ? -1 : 0)
        guard let from = scanner.scanInt() else { return nil }
        var to = from
        if scanner.scanString("-") != nil {
            guard let end = scanner.scanInt(), end >= from else { return nil }
            to = end
        }
        return scanner.isAtEnd ? LineSpec(from: from, to: to, relative: relative) : nil
    }

    /// The characters to select, or nil when the lines are not in the text.
    /// A port of getRange:inTextView:fromLineSpec:toLineSpec:relative:
    /// (reference/apple/LinePanelController.m:94-137). Lines end where
    /// `NSString.lineRange(for:)` ends them: LF, CR, CRLF, U+0085, U+2028, U+2029.
    func range(in string: NSString, selection: NSRange) -> NSRange? {
        // Number of lines in from...to, without overflow on huge entries.
        let (span, overflow) = to.subtractingReportingOverflow(from)
        guard !overflow, span < Int.max else { return nil }
        let lineCount = span + 1

        var start = 0
        if relative != 0 {
            var location = selection.location
            if relative > 0 { location = NSMaxRange(selection) - (selection.length > 0 ? 1 : 0) }
            var lineStart = 0
            string.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: location, length: 0))
            start = lineStart
        } else if from == 0 {
            return nil // "0" is not a line number
        }

        if relative < 0 {
            // Backwards from the current line. TextEdit steps back from - 1
            // lines, none for 0 or less; clamping first keeps Int.min from overflowing.
            let back = from > 0 ? from - 1 : 0
            guard let end = LineScanner.skipLinesBack(back, from: start, in: string),
                  let begin = LineScanner.skipLinesBack(lineCount, from: end, in: string) else { return nil }
            return NSRange(location: begin, length: end - begin)
        }
        // Forwards. An absolute entry counts from line 1, a relative one from 0.
        let skip = max(0, relative == 0 ? from - 1 : from)
        guard let begin = LineScanner.skipLines(skip, from: start, in: string),
              let end = LineScanner.skipLines(lineCount, from: begin, in: string) else { return nil }
        return NSRange(location: begin, length: end - begin)
    }
}

/// Counts lines with one pass over the string's UTF-16 code units, copied
/// out a chunk at a time, instead of one `lineRange(for:)` call per line.
/// Forward it gives the same answers as repeated `NSMaxRange(lineRange(for:))`;
/// backward, as repeated `lineRange(for: location - 1).location`.
enum LineScanner {
    private static let chunkLength = 1 << 15

    /// The location after moving forward `count` lines from `start` (a line
    /// start), or nil when the text ends first. Each step needs a line to
    /// move over: like TextEdit, a step that starts at the end of the text fails.
    static func skipLines(_ count: Int, from start: Int, in string: NSString) -> Int? {
        if count <= 0 { return start }
        let length = string.length
        var remaining = count
        var location = start
        let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: chunkLength)
        defer { buffer.deallocate() }
        var chunkStart = start
        var skipFirst = false // the LF of a CRLF split across two chunks
        while chunkStart < length {
            let n = min(chunkLength, length - chunkStart)
            string.getCharacters(buffer, range: NSRange(location: chunkStart, length: n))
            var i = skipFirst ? 1 : 0
            skipFirst = false
            while i < n {
                let c = buffer[i]
                // Fast path: most characters are above CR and are not NEL, LS or PS.
                if c > 0x0D && c != 0x85 && (c & 0xFFFE) != 0x2028 { i += 1; continue }
                if c != 0x0A && c != 0x0D && c != 0x85 && c != 0x2028 && c != 0x2029 { i += 1; continue }
                var end = chunkStart + i + 1
                if c == 0x0D && end < length {
                    let next = i + 1 < n ? buffer[i + 1] : string.character(at: end)
                    if next == 0x0A {
                        end += 1
                        if i + 1 < n { i += 1 } else { skipFirst = true }
                    }
                }
                location = end
                remaining -= 1
                if remaining == 0 { return location }
                i += 1
            }
            chunkStart += n
        }
        // The last line has no line end: one more step reaches the end of the text.
        if location < length {
            remaining -= 1
            location = length
        }
        return remaining == 0 ? location : nil
    }

    /// The line start reached by moving back `count` lines from `location`,
    /// or nil when the text starts first. Each step goes to the start of the
    /// line before: the nearest line start below the current location.
    /// Line starts are 0 and the index after each line end (after the LF of
    /// a CRLF, never between its CR and LF).
    static func skipLinesBack(_ count: Int, from location: Int, in string: NSString) -> Int? {
        if count <= 0 { return location }
        // Each line start below `location` is a different index, so there are
        // at most `location` of them: a bigger count fails without a scan.
        if count > location { return nil }
        var remaining = count
        let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: chunkLength)
        defer { buffer.deallocate() }
        // A line end at location - 1 makes the line start at `location`
        // itself, which does not count; the scan starts below it.
        var chunkEnd = location - 1
        var above = string.character(at: location - 1) // the unit just above the chunk
        while chunkEnd > 0 {
            let chunkStart = max(0, chunkEnd - chunkLength)
            let n = chunkEnd - chunkStart
            string.getCharacters(buffer, range: NSRange(location: chunkStart, length: n))
            var i = n - 1
            while i >= 0 {
                let c = buffer[i]
                // Fast path: most characters are above CR and are not NEL, LS or PS.
                if c > 0x0D && c != 0x85 && (c & 0xFFFE) != 0x2028 { i -= 1; continue }
                if c != 0x0A && c != 0x0D && c != 0x85 && c != 0x2028 && c != 0x2029 { i -= 1; continue }
                // The CR of a CRLF: the line starts after the LF, counted already.
                if c == 0x0D && (i + 1 < n ? buffer[i + 1] : above) == 0x0A { i -= 1; continue }
                remaining -= 1
                if remaining == 0 { return chunkStart + i + 1 }
                i -= 1
            }
            above = buffer[0]
            chunkEnd = chunkStart
        }
        // The first line starts at 0.
        return remaining == 1 ? 0 : nil
    }
}
