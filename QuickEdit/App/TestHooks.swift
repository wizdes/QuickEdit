import AppKit

#if DEBUG
/// Launch-argument hooks for UI tests only; compiled out of Release builds.
///
/// The UI test runner is sandboxed and cannot write the fixture files, so it
/// cannot play "another app changed the file". With
/// `-QETestExternalWrite <path> -QETestExternalWriteText <text>
/// -QETestExternalWriteDelay <seconds>` the app starts a separate `/bin/sh`
/// process after `<seconds>`, and that process (not QuickEdit) writes
/// `<text>` to `<path>` without file coordination, as another editor would.
///
/// Every value follows its own `-flag`: AppKit opens any bare launch
/// argument as a document, and the first UI test run (2026-10-24) showed
/// "The document "after" could not be opened" in a modal alert that stopped
/// the reload. `<text>` is read like printf's `%b`, so a newline is written
/// as the two characters `\n`: a real newline in the launch argument did
/// not survive the UI-test launch in that run ("after\n" was written as "after").
///
/// With `-QETestExternalWriteAfterCaretAtEnd YES` too, the `<seconds>`
/// count from the moment a document window for `<path>` is open and its
/// caret is at the end of the text, not from launch. The test moves the
/// caret (Cmd+Down) once it has read the opened text, so the write comes
/// after the test saw the old text, however slow the Open panel is (31 s
/// once in a loaded run). It gives up after 180 s.
///
/// `-QETestReadOnlyLimitBytes <n>` lowers the read-only limit
/// (`TextDocument.readOnlyThreshold`, 512 MiB) to `<n>` bytes, so a UI test
/// can use the read-only large-file paths (Save As copies the clone) with a
/// small file. `<n>` must be a whole number from 1 up to the default.
///
/// `-QETestExposeSelection YES` copies the selected text of a document's
/// text view into that view's accessibility label ("selection:<text>"),
/// which XCUITest reads as `label`, on every selection change. A UI test can
/// then read the selection without pressing keys (Cmd+E acts on the find
/// field while it has the focus). Field editors are left alone.
@MainActor
enum TestHooks {
    static let exposeSelectionFlag = "-QETestExposeSelection"
    static let selectionLabelPrefix = "selection:"
    private static var selectionObserver: NSObjectProtocol?

    static func start(arguments: [String]) {
        if let index = arguments.firstIndex(of: exposeSelectionFlag), index + 1 < arguments.count,
           arguments[index + 1] == "YES" {
            startExposingSelection()
        }
        startExternalWrite(arguments: arguments)
        applyReadOnlyLimit(arguments: arguments)
    }

    static let readOnlyLimitFlag = "-QETestReadOnlyLimitBytes"

    /// Sets `TextDocument.readOnlyThreshold` from `-QETestReadOnlyLimitBytes`.
    /// A bad value is reported and changes nothing.
    static func applyReadOnlyLimit(arguments: [String]) {
        guard let index = arguments.firstIndex(of: readOnlyLimitFlag) else { return }
        guard index + 1 < arguments.count, let bytes = Int(arguments[index + 1]),
              bytes >= 1, bytes <= TextDocument.defaultReadOnlyThreshold else {
            FileHandle.standardError.write(Data(("QuickEdit: \(readOnlyLimitFlag) wants a whole number of bytes from 1 to "
                + "\(TextDocument.defaultReadOnlyThreshold); the read-only limit stays \(TextDocument.readOnlyThreshold)\n").utf8))
            return
        }
        TextDocument.readOnlyThreshold = bytes
        FileHandle.standardError.write(Data("QuickEdit: test read-only limit is \(bytes) bytes\n".utf8))
    }

    /// Starts copying each text view's selection into its accessibility label.
    static func startExposingSelection() {
        guard selectionObserver == nil else { return }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { note in
            // queue: .main runs this block on the main thread.
            nonisolated(unsafe) let textView = note.object as? NSTextView
            MainActor.assumeIsolated {
                if let textView { exposeSelection(of: textView) }
            }
        }
    }

    static func stopExposingSelection() {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil
    }

    static func exposeSelection(of textView: NSTextView) {
        guard !textView.isFieldEditor else { return }
        let text = textView.string as NSString
        let range = textView.selectedRange()
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else {
            FileHandle.standardError.write(Data("QuickEdit: -QETestExposeSelection: selection \(range) is outside the text\n".utf8))
            return
        }
        textView.setAccessibilityLabel(selectionLabelPrefix + text.substring(with: range))
    }

    static func startExternalWrite(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let path = value(after: "-QETestExternalWrite") else { return }
        guard let text = value(after: "-QETestExternalWriteText"),
              let delay = value(after: "-QETestExternalWriteDelay").flatMap(Double.init) else {
            FileHandle.standardError.write(Data(("QuickEdit: -QETestExternalWrite wants -QETestExternalWriteText <text> "
                + "and -QETestExternalWriteDelay <seconds>\n").utf8))
            return
        }
        if value(after: "-QETestExternalWriteAfterCaretAtEnd") == "YES" {
            waitForCaretAtEnd(of: path, deadline: Date().addingTimeInterval(180)) {
                write(text, to: path, after: delay)
            }
        } else {
            write(text, to: path, after: delay)
        }
    }

    /// True when `path` has a document window on screen whose caret is at
    /// the end of a text that is not empty.
    static func hasCaretAtEnd(for path: String) -> Bool {
        let wanted = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return NSDocumentController.shared.documents.contains { document in
            guard document.fileURL?.resolvingSymlinksInPath().path == wanted else { return false }
            return document.windowControllers.contains { controller in
                guard controller.window?.isVisible == true,
                      let textView = (controller as? DocumentWindowController)?.textView else { return false }
                let length = (textView.string as NSString).length
                return length > 0 && textView.selectedRange() == NSRange(location: length, length: 0)
            }
        }
    }

    /// Checks every 0.1 s on the main thread until `path` has its caret at the end.
    private static func waitForCaretAtEnd(of path: String, deadline: Date, then run: @escaping @MainActor () -> Void) {
        if hasCaretAtEnd(for: path) { return run() }
        guard Date() < deadline else {
            FileHandle.standardError.write(Data("QuickEdit: -QETestExternalWriteAfterCaretAtEnd: \(path) never had its caret at the end; no test write\n".utf8))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated { waitForCaretAtEnd(of: path, deadline: deadline, then: run) }
        }
    }

    private static func write(_ text: String, to path: String, after delay: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%b' \"$1\" > \"$2\"", "sh", text, path]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    FileHandle.standardError.write(Data("QuickEdit: test write to \(path) exited \(process.terminationStatus)\n".utf8))
                }
            } catch {
                FileHandle.standardError.write(Data("QuickEdit: test write to \(path) failed: \(error)\n".utf8))
            }
        }
    }
}
#endif
