import AppKit

/// TextEdit's two print options, "Print header and footer" and "Rewrap
/// contents to fit page", as the accessory of the PDF Save panel. QuickEdit
/// has no Print panel (user decision U1), so there are no summary items.
/// Port of reference/apple/PrintPanelAccessoryController.m (the apple copy:
/// each panel reads the defaults once and keeps its own values; a change
/// writes the default, so the choice sticks) and
/// Base.lproj/PrintPanelAccessory.nib (frames below).
@MainActor
final class PrintPanelAccessoryController: NSViewController {
    /// Shown only in Wrap to Window: Wrap to Page pages are fixed (Document.m:665).
    let showsWrappingToFit: Bool

    /// "Print header and footer" (`NumberPagesWhenPrinting`).
    private(set) var pageNumbering: Bool
    /// "Rewrap contents to fit page" (`WrapToFitWhenPrinting`).
    private(set) var wrappingToFit: Bool

    private(set) lazy var headerCheckbox: NSButton = {
        let box = makeCheckbox("Print header and footer", frame: NSRect(x: 105, y: 26, width: 196, height: 18),
                               action: #selector(changePageNumbering(_:)))
        box.state = pageNumbering ? .on : .off
        return box
    }()

    private(set) lazy var rewrapCheckbox: NSButton = {
        let box = makeCheckbox("Rewrap contents to fit page", frame: NSRect(x: 105, y: 6, width: 196, height: 18),
                               action: #selector(changeWrappingToFit(_:)))
        box.state = wrappingToFit ? .on : .off
        // The nib binds hidden to !showsWrappingToFit.
        box.isHidden = !showsWrappingToFit
        return box
    }()

    /// The choices, for the print operation.
    var options: TextDocument.PDFOptions {
        .init(headerAndFooter: pageNumbering, wrappingToFit: wrappingToFit)
    }

    init(showsWrappingToFit: Bool) {
        self.showsWrappingToFit = showsWrappingToFit
        // Read once (setRepresentedObject:, :65-72): a change in another
        // panel does not reach this one.
        pageNumbering = Defaults.bool(.numberPagesWhenPrinting)
        wrappingToFit = Defaults.bool(.wrapToFitWhenPrinting)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PrintPanelAccessoryController is built in code") }

    /// The nib's 406 x 49 view, built in code.
    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 406, height: 49))
        view.addSubview(headerCheckbox)
        view.addSubview(rewrapCheckbox)
        headerCheckbox.nextKeyView = rewrapCheckbox
        self.view = view
    }

    private func makeCheckbox(_ title: String, frame: NSRect, action: Selector) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: self, action: action)
        box.frame = frame
        // The nib's 13 pt system font (.LucidaGrandeUI 13).
        box.font = .systemFont(ofSize: 13)
        return box
    }

    // MARK: Changes write the defaults (:84-92)

    @objc func changePageNumbering(_ sender: NSButton) {
        pageNumbering = sender.state == .on
        Defaults.store.set(pageNumbering, forKey: DefaultsKey.numberPagesWhenPrinting.rawValue)
    }

    @objc func changeWrappingToFit(_ sender: NSButton) {
        wrappingToFit = sender.state == .on
        Defaults.store.set(wrappingToFit, forKey: DefaultsKey.wrapToFitWhenPrinting.rawValue)
    }
}
