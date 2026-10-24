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
        panel.setFrameAutosaveName(Self.frameAutosaveName)

        lineField = field
        window = panel
        return panel
    }

    /// Reopens the panel when the app's saved state is restored
    /// (reference/apple/LinePanelController.m:67-73).
    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                              completionHandler: @escaping (NSWindow?, (any Error)?) -> Void) {
        completionHandler(identifier == panelIdentifier ? shared.loadPanelIfNeeded() : nil, nil)
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

    /// Selects in the main window's first responder when it is a text view,
    /// as TextEdit does; does nothing otherwise.
    func selectLinesInMainWindow(_ description: String) throws {
        guard let textView = NSApp.mainWindow?.firstResponder as? NSTextView else { return }
        try Self.selectLines(description, in: textView)
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
            // Backwards from the current line, with lineRange as TextEdit does.
            guard let end = Self.lineStart(movingBack: from - 1, from: start, in: string),
                  let begin = Self.lineStart(movingBack: lineCount, from: end, in: string) else { return nil }
            return NSRange(location: begin, length: end - begin)
        }
        // Forwards. An absolute entry counts from line 1, a relative one from 0.
        let skip = max(0, relative == 0 ? from - 1 : from)
        guard let begin = LineScanner.skipLines(skip, from: start, in: string),
              let end = LineScanner.skipLines(lineCount, from: begin, in: string) else { return nil }
        return NSRange(location: begin, length: end - begin)
    }

    /// Steps back `count` line starts from `location` (itself a line start).
    private static func lineStart(movingBack count: Int, from location: Int, in string: NSString) -> Int? {
        var location = location
        var remaining = count
        while remaining > 0 {
            if location == 0 { return nil }
            location = string.lineRange(for: NSRange(location: location - 1, length: 0)).location
            remaining -= 1
        }
        return location
    }
}

/// Counts lines forward with one pass over the string's UTF-16 code units,
/// copied out a chunk at a time, instead of one `lineRange(for:)` call per
/// line. Gives the same answers as repeated `NSMaxRange(lineRange(for:))`.
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
}
