import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import QuickEdit

/// The Save panel's ".txt" checkbox (first UI test run, 2026-10-24: "plain"
/// was saved without ".txt" while the box was on).
@MainActor
final class PlainTextExtensionPanelTests: XCTestCase {
    func testBareNameGetsTxtOnlyWhenTheBoxIsOn() {
        XCTAssertEqual(PlainTextExtensionPanelDelegate.filename("plain", addsTxt: true), "plain.txt")
        XCTAssertEqual(PlainTextExtensionPanelDelegate.filename("plain", addsTxt: false), "plain")
        XCTAssertEqual(PlainTextExtensionPanelDelegate.filename("x.md", addsTxt: true), "x.md")
        XCTAssertEqual(PlainTextExtensionPanelDelegate.filename("notes.txt", addsTxt: true), "notes.txt")
        XCTAssertEqual(PlainTextExtensionPanelDelegate.filename("", addsTxt: true), "")
    }

    func testDelegateOnARealPanel() throws {
        let panel = NSSavePanel()
        PlainTextExtensionPanelDelegate.install(on: panel)
        let delegate = try XCTUnwrap(panel.delegate as? PlainTextExtensionPanelDelegate, "no delegate installed")

        panel.allowedContentTypes = [.plainText] // the box on
        panel.allowsOtherFileTypes = true
        XCTAssertEqual(delegate.panel(panel, userEnteredFilename: "plain", confirmed: true), "plain.txt")
        XCTAssertEqual(delegate.panel(panel, userEnteredFilename: "plain", confirmed: false), "plain",
                       "the name changes only when the user presses Save")
        XCTAssertEqual(delegate.panel(panel, userEnteredFilename: "x.md", confirmed: true), "x.md")

        panel.allowedContentTypes = [] // the box off
        panel.allowsOtherFileTypes = false
        XCTAssertEqual(delegate.panel(panel, userEnteredFilename: "bare", confirmed: true), "bare")
    }
}
