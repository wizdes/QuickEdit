import AppKit
import ObjectiveC

/// Makes the Save panel's "If no extension is provided, use ".txt"." checkbox
/// do what it says.
///
/// With the checkbox on, the panel allows plain text and other types
/// (Document.m:1288-1290). On macOS 27 a name typed with no extension then
/// saves with none: "allow other types" lets "no extension" through. The
/// first UI test run (2026-10-24) saved "plain" instead of "plain.txt".
/// AppKit asks this delegate for the final name before it adds a required
/// extension and before it asks about replacing a file, so a name changed
/// here still gets the usual "replace?" question.
@MainActor
final class PlainTextExtensionPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    private static var key: UInt8 = 0

    /// Sets a delegate on `panel` that lives as long as the panel. NSDocument
    /// sets no delegate of its own (measured 2026-10-24: nil in
    /// prepareSavePanel), so none is replaced; if one is there it stays.
    static func install(on panel: NSSavePanel) {
        guard panel.delegate == nil else {
            FileHandle.standardError.write(Data("QuickEdit: the Save panel already has a delegate; \".txt\" is not added to bare names\n".utf8))
            return
        }
        let delegate = PlainTextExtensionPanelDelegate()
        objc_setAssociatedObject(panel, &key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        panel.delegate = delegate
    }

    /// "name" becomes "name.txt" when `addsTxt` and the name has no
    /// extension; any other name is kept as typed.
    nonisolated static func filename(_ name: String, addsTxt: Bool) -> String {
        guard addsTxt, !name.isEmpty, (name as NSString).pathExtension.isEmpty else { return name }
        return name + ".txt"
    }

    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed okFlag: Bool) -> String? {
        guard okFlag, let panel = sender as? NSSavePanel else { return filename }
        // The checkbox on means plain text is an allowed type
        // (TextDocument.applyExtensionChoice); off means no types.
        let addsTxt = !panel.allowedContentTypes.isEmpty
        let name = Self.filename(filename, addsTxt: addsTxt)
        // M9: the sandboxed Save panel runs in another process and ignores
        // the name returned here (measured 2026-10-25: "plain" saved as
        // "plain"). With other types off for this one confirm, the panel adds
        // ".txt" itself. A typed extension such as "x.md" keeps other types on.
        if addsTxt { panel.allowsOtherFileTypes = name == filename }
        return name
    }
}
