import AppKit
import XCTest
@testable import QuickEdit

/// 1.2.0 changes 2 and 4: defaults closer to Sublime Text (spelling and
/// auto-correct off, 13 pt text until the user picks a font) and the
/// Settings clean-up (no Paper size pop-up, no Data detectors checkbox,
/// room under Restore Keyboard Defaults).
@MainActor
final class SublimeDefaultsTests: XCTestCase {
    private var saved: SavedSettings!
    private var documents: [NSDocument] = []
    private var controllers: [SettingsWindowController] = []

    override func setUp() async throws {
        saved = SavedSettings()
    }

    override func tearDown() async throws {
        for document in documents { document.close() }
        documents = []
        for controller in controllers { controller.window?.close() }
        controllers = []
        saved.restore()
    }

    private func newWindow() throws -> DocumentWindowController {
        let document = TextDocument()
        document.makeWindowControllers()
        documents.append(document)
        return try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
    }

    private func settings() -> SettingsWindowController {
        let controller = SettingsWindowController()
        controller.loadSettingsWindowIfNeeded()
        controllers.append(controller)
        return controller
    }

    // MARK: Spelling

    func testSpellingAndAutoCorrectAreOffByDefault() throws {
        XCTAssertEqual(Defaults.registeredValues()[DefaultsKey.checkSpellingWhileTyping.rawValue] as? Bool, false)
        XCTAssertEqual(Defaults.registeredValues()[DefaultsKey.correctSpellingAutomatically.rawValue] as? Bool, false)
        let view = try newWindow().textView
        XCTAssertFalse(view.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)
    }

    // MARK: Font size

    func testPlainTextIs13PointUntilTheUserPicksAFont() throws {
        NSFont.setUserFixedPitch(nil)
        XCTAssertFalse(TextViewFactory.userPickedPlainFont)
        XCTAssertEqual(TextViewFactory.plainFont().pointSize, 13)
        XCTAssertTrue(TextViewFactory.plainFont().isFixedPitch)
        let font = try XCTUnwrap(try newWindow().textView.typingAttributes[.font] as? NSFont)
        XCTAssertEqual(font.pointSize, 13)
        XCTAssertEqual(settings().fontNameField?.stringValue.hasSuffix(" 13"), true, "Settings shows the 13 pt font")
    }

    func testAPickedFontKeepsItsSize() throws {
        let picked = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 11))
        settings().setPlainTextFont(picked)
        XCTAssertEqual(TextViewFactory.plainFont().pointSize, 11, "a font the user picked stays as picked")
        XCTAssertEqual(TextViewFactory.plainFont().fontName, "Menlo-Regular")
    }

    func testRestoreAllDefaultsGivesBack13Point() throws {
        let controller = settings()
        controller.setPlainTextFont(try XCTUnwrap(NSFont(name: "Courier", size: 20)))
        controller.restoreAllDefaults(nil)
        XCTAssertEqual(TextViewFactory.plainFont().pointSize, 13)
        XCTAssertEqual(controller.fontNameField?.stringValue, SettingsWindowController.fontDescription(TextViewFactory.plainFont()))
    }

    // MARK: Data detectors

    func testDataDetectorsAreAlwaysOffInNewWindows() throws {
        Defaults.store.set(true, forKey: DefaultsKey.dataDetectors.rawValue)
        XCTAssertFalse(try newWindow().textView.isAutomaticDataDetectionEnabled, "a stored YES no longer turns them on")
    }

    // MARK: Settings

    func testNoPaperSizeOrDataDetectorsControls() throws {
        let controller = settings()
        let newDocument = try XCTUnwrap(controller.tabView?.tabViewItems[0].view)
        func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
        let views = all(newDocument)
        XCTAssertFalse(views.contains { $0 is NSPopUpButton }, "the Paper size pop-up is gone")
        let texts = views.compactMap { ($0 as? NSTextField)?.stringValue } + views.compactMap { ($0 as? NSButton)?.title }
        XCTAssertFalse(texts.contains("Paper size:"))
        XCTAssertFalse(texts.contains("Data detectors"))
        XCTAssertNil(controller.checkboxes[.dataDetectors])
        // The paper size is still stored and used.
        XCTAssertNotNil(Defaults.registeredValues()[Defaults.paperSizeKey])
        XCTAssertEqual(PageLayout.forNewDocument().paperSize, PaperSize.current.size)
    }

    func testRestoreKeyboardDefaultsHasRoomBelowIt() throws {
        let keyboard = KeyboardTabController()
        let button = keyboard.restoreButton
        let view = keyboard.view
        XCTAssertTrue(view.isFlipped)
        XCTAssertEqual(view.bounds.height - button.frame.maxY, 12, accuracy: 0.5, "12 points under the button")
        XCTAssertTrue(view.bounds.contains(button.frame))
    }
}
