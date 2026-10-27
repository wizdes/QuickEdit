import AppKit
import XCTest
@testable import QuickEdit

/// M6 n2: Settings apply to the next new window only. Open windows keep
/// their size, font and spelling and substitution flags (docs/codemap.md
/// section 3 note; reference/apple/DocumentWindowController.m:187-198, :660-670).
@MainActor
final class SettingsApplyTests: XCTestCase {
    private var saved: SavedSettings!
    private var documents: [NSDocument] = []
    private var settings: SettingsWindowController!

    override func setUp() async throws {
        saved = SavedSettings()
        Defaults.restoreAll()
        settings = SettingsWindowController()
        settings.loadSettingsWindowIfNeeded()
    }

    override func tearDown() async throws {
        for document in documents { document.close() }
        documents = []
        settings.window?.close()
        settings = nil
        saved.restore()
    }

    private func newWindow() throws -> (TextDocument, DocumentWindowController) {
        let document = try XCTUnwrap(
            try NSDocumentController.shared.makeUntitledDocument(ofType: TextDocument.plainTextType) as? TextDocument)
        document.makeWindowControllers()
        documents.append(document)
        return (document, try XCTUnwrap(document.windowControllers.first as? DocumentWindowController))
    }

    /// The typing font's name and size.
    private func font(of controller: DocumentWindowController) -> String? {
        (controller.textView.typingAttributes[.font] as? NSFont).map { "\($0.fontName) \($0.pointSize)" }
    }

    private func name(_ font: NSFont) -> String { "\(font.fontName) \(font.pointSize)" }

    private func expectedWidth(columns: Int, font: NSFont) -> CGFloat {
        (CGFloat(columns) * TextViewFactory.xAdvance(of: font) + 2 * NSTextContainer().lineFragmentPadding).rounded(.up)
    }

    func testWidthAndFontApplyToTheNextWindowOnly() throws {
        let oldFont = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 12))
        settings.setPlainTextFont(oldFont)
        let (_, windowA) = try newWindow()
        let sizeA = windowA.scrollView.contentSize
        XCTAssertEqual(sizeA.width, expectedWidth(columns: 90, font: oldFont), accuracy: 0.5)

        // Width 60 and a bigger font, through the Settings controls.
        let width = try XCTUnwrap(settings.widthField)
        width.integerValue = 60
        XCTAssertTrue(width.sendAction(width.action, to: width.target))
        let newFont = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 16))
        settings.setPlainTextFont(newFont)

        let (_, windowB) = try newWindow()
        XCTAssertEqual(windowB.scrollView.contentSize.width, expectedWidth(columns: 60, font: newFont), accuracy: 0.5)
        XCTAssertEqual(windowB.scrollView.contentSize.height, 30 * TextViewFactory.lineHeight(of: newFont), accuracy: 0.5)
        XCTAssertEqual(font(of: windowB), name(newFont))

        // Window A keeps its size and font.
        XCTAssertEqual(windowA.scrollView.contentSize, sizeA)
        XCTAssertEqual(font(of: windowA), name(oldFont))
    }

    func testHeightAppliesToTheNextWindowOnly() throws {
        let (_, windowA) = try newWindow()
        let sizeA = windowA.scrollView.contentSize
        let height = try XCTUnwrap(settings.heightField)
        height.integerValue = 12
        XCTAssertTrue(height.sendAction(height.action, to: height.target))

        let (_, windowB) = try newWindow()
        XCTAssertEqual(windowB.scrollView.contentSize.height,
                       12 * TextViewFactory.lineHeight(of: TextViewFactory.plainFont()), accuracy: 0.5)
        XCTAssertEqual(windowA.scrollView.contentSize, sizeA)
    }

    func testSpellingAndSubstitutionsApplyToTheNextWindowOnly() throws {
        let (_, windowA) = try newWindow()
        let flags: [(DefaultsKey, (NSTextView) -> Bool)] = [
            (.checkSpellingWhileTyping, { $0.isContinuousSpellCheckingEnabled }),
            (.checkGrammarWithSpelling, { $0.isGrammarCheckingEnabled }),
            (.correctSpellingAutomatically, { $0.isAutomaticSpellingCorrectionEnabled }),
            (.smartCopyPaste, { $0.smartInsertDeleteEnabled }),
            (.smartQuotes, { $0.isAutomaticQuoteSubstitutionEnabled }),
            (.smartDashes, { $0.isAutomaticDashSubstitutionEnabled }),
            // Data detectors: no checkbox since 1.2.0 (always off).
            (.textReplacement, { $0.isAutomaticTextReplacementEnabled }),
        ]
        let before = flags.map { $0.1(windowA.textView) }
        for (key, _) in flags {
            try XCTUnwrap(settings.checkboxes[key]).performClick(nil)
        }

        let (_, windowB) = try newWindow()
        for ((key, read), old) in zip(flags, before) {
            XCTAssertEqual(read(windowB.textView), !old, "new window ignores \(key.rawValue)")
            XCTAssertEqual(read(windowA.textView), old, "open window changed \(key.rawValue)")
        }
    }

    func testWrapToPageAppliesToTheNextNewWindowOnly() throws {
        let (documentA, windowA) = try newWindow()
        XCTAssertFalse(documentA.hasMultiplePages)
        try XCTUnwrap(settings.checkboxes[.showPageBreaks]).performClick(nil)

        let (documentB, windowB) = try newWindow()
        XCTAssertTrue(documentB.hasMultiplePages)
        XCTAssertNotNil(windowB.pagesView)
        XCTAssertFalse(documentA.hasMultiplePages)
        XCTAssertNil(windowA.pagesView)
    }
}
