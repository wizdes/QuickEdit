import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `-QEOpenPath <path>`: open this file at launch. For tests only (Doc B
    /// section 8). Read from the launch arguments only, never from saved user
    /// defaults, so a stray `defaults write` cannot change how the app starts.
    let testOpenPath = AppDelegate.testOpenPath(in: ProcessInfo.processInfo.arguments)

    /// The value after `-QEOpenPath` in `arguments`, if any.
    static func testOpenPath(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "-QEOpenPath"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        testOpenPath == nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        TestHooks.start(arguments: ProcessInfo.processInfo.arguments)
        #endif
        // Clones of large files left by a QuickEdit that crashed or was
        // killed (M8 review row 14); off the main thread, after launch.
        DispatchQueue.global(qos: .utility).async { LargeFileOriginal.removeStaleFolders() }
        guard let testOpenPath else { return }
        let url = URL(fileURLWithPath: (testOpenPath as NSString).expandingTildeInPath)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                FileHandle.standardError.write(Data("QuickEdit: -QEOpenPath \(url.path) failed: \(error)\n".utf8))
                NSApp.presentError(error)
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Quit (1.2.0): blank untitled documents close without a question
    /// and leave no autosaved copy. DocumentController's review does this
    /// first; this catches a quit that keeps windows, where AppKit may
    /// skip the review.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        TextDocument.discardBlankUntitledDocuments()
        return .terminateNow
    }
}
