import AppKit
import XCTest
@testable import QuickEdit

/// Typing from the keyboard after Wrap to Page. The first real UI run
/// (2026-10-24, LayoutTests.testWrapToPageAddsPagesAndZooms) found that
/// keystrokes reached the page's text view but changed nothing; the page
/// tests in PageModeTests insert text directly and so missed it.
@MainActor
final class PageModeKeyboardTests: XCTestCase {
    private var document: TextDocument?

    override func tearDown() async throws {
        document?.updateChangeCount(.changeCleared)
        document?.close()
        document = nil
    }

    private func keyDown(_ characters: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    func testKeystrokeAfterWrapToPageTypesIntoThePage() throws {
        let document = try XCTUnwrap(try DocumentController.shared.makeUntitledDocument(ofType: TextDocument.plainTextType)
            as? TextDocument)
        self.document = document
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        if controller.hasMultiplePages { controller.setHasMultiplePages(false) }
        let window = try XCTUnwrap(controller.window)

        // Wrap to Window first: a keystroke types.
        window.makeFirstResponder(controller.textView)
        controller.textView.keyDown(with: try keyDown("a", keyCode: 0, in: window))
        XCTAssertEqual(document.textStorage.string, "a", "a keystroke in Wrap to Window")

        controller.setHasMultiplePages(true)
        let page = controller.textView
        XCTAssertTrue(window.firstResponder === page, "the page is not first responder")
        XCTAssertTrue((page.inputContext?.client as AnyObject?) === page, "keystrokes go to another view")
        page.keyDown(with: try keyDown("b", keyCode: 11, in: window))
        XCTAssertEqual(document.textStorage.string, "ab", "a keystroke in Wrap to Page")
    }
}
