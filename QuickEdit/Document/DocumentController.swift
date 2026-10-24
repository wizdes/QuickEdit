import AppKit

/// The app's NSDocumentController. Created in main.swift before anything asks
/// for `NSDocumentController.shared`, so it becomes the shared instance.
final class DocumentController: NSDocumentController {
    override init() {
        super.init()
        // TextEdit binds this to the AutosavingDelay default (DocumentController.m:72-77).
        autosavingDelay = TimeInterval(Defaults.integer(.autosavingDelay))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("DocumentController is built in code") }

    /// QuickEdit writes only plain text.
    override var defaultType: String? { TextDocument.plainTextType }
}
