import AppKit

/// The paper sizes Settings > New Document offers (M7, root's choice; no
/// Page Setup, user decision U1). The raw value is what the `PaperSize`
/// default stores.
enum PaperSize: String, CaseIterable, Sendable {
    case letter = "Letter"
    case a4 = "A4"
    case legal = "Legal"

    var title: String { rawValue }

    /// In points, as AppKit names them (NSPrintInfo gives A4 as 595 x 842).
    nonisolated var size: NSSize {
        switch self {
        case .letter: NSSize(width: 612, height: 792)
        case .a4: NSSize(width: 595, height: 842)
        case .legal: NSSize(width: 612, height: 1008)
        }
    }

    /// Letter in the US and Canada, A4 elsewhere. Read from the locale, not
    /// from NSPrintInfo: asking NSPrintInfo for the printer's paper reaches
    /// macOS's print helper.
    nonisolated static func regionDefault(for locale: Locale) -> PaperSize {
        switch locale.region?.identifier {
        case "US", "CA": .letter
        default: .a4
        }
    }

    /// The saved choice, or the region's size when nothing (or junk) is saved.
    nonisolated static var current: PaperSize {
        Defaults.store.string(forKey: Defaults.paperSizeKey).flatMap(PaperSize.init(rawValue:))
            ?? regionDefault(for: .current)
    }
}

/// Paper size and margins for Wrap to Page and PDFs, as plain values.
/// Neither Wrap to Page nor the PDF writer makes or reads an NSPrintInfo:
/// reading a print info's `paperSize`, or running an NSPrintOperation,
/// opens a connection to com.apple.printtool.agent (probe 2026-10-24, one
/// fresh process per call, counted in the system log).
struct PageLayout: Equatable, Sendable {
    /// TextEdit's print margins on every side (reference/apple/Document.m:679-689).
    static let textEditMargin: CGFloat = 72

    var paperSize: NSSize
    var topMargin: CGFloat = textEditMargin
    var leftMargin: CGFloat = textEditMargin
    var bottomMargin: CGFloat = textEditMargin
    var rightMargin: CGFloat = textEditMargin

    init(paperSize: NSSize) {
        self.paperSize = paperSize
    }

    /// The layout of a print info someone handed in. This reads its paper,
    /// so only code that sets a print info (tests) comes here.
    init(printInfo: NSPrintInfo) {
        paperSize = printInfo.paperSize
        topMargin = printInfo.topMargin
        leftMargin = printInfo.leftMargin
        bottomMargin = printInfo.bottomMargin
        rightMargin = printInfo.rightMargin
    }

    /// The paper size Settings names now, with TextEdit's margins. Any
    /// thread: documents are made on background threads too.
    nonisolated static func forNewDocument() -> PageLayout {
        PageLayout(paperSize: PaperSize.current.size)
    }

    /// A print info with this paper and these margins, fit-to-width
    /// pagination and no centering (Document.m:679-689), for NSDocument's
    /// `printInfo` only. Made from a dictionary, so nothing asks the
    /// printer for its paper; reading the result's paper later does.
    func makePrintInfo() -> NSPrintInfo {
        let info = NSPrintInfo(dictionary: [.paperSize: NSValue(size: paperSize)])
        info.topMargin = topMargin
        info.leftMargin = leftMargin
        info.bottomMargin = bottomMargin
        info.rightMargin = rightMargin
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    /// Paper minus margins, plus the line padding on both sides
    /// (MultiplePageView.m:297-302).
    var documentSizeInPage: NSSize {
        NSSize(width: paperSize.width - (leftMargin + rightMargin) + MultiplePageView.textPadding * 2,
               height: paperSize.height - (topMargin + bottomMargin))
    }
}
