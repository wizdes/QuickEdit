import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `-QEOpenPath <path>`: open this file at launch. For tests only (Doc B section 8).
    private let testOpenPath = UserDefaults.standard.string(forKey: "QEOpenPath")

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        testOpenPath == nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
}
