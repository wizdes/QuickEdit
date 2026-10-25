import AppKit
import XCTest
@testable import QuickEdit

#if DEBUG
/// The DEBUG-only -QETestExposeSelection hook (QuickEdit/App/TestHooks.swift):
/// each selection change shows in the text view's accessibility label.
@MainActor
final class TestHooksSelectionTests: XCTestCase {
    override func tearDown() async throws {
        TestHooks.stopExposingSelection()
    }

    private func makeTextView(_ text: String) -> NSTextView {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.string = text
        return textView
    }

    func testSelectionChangeUpdatesTheLabel() {
        let textView = makeTextView("L1\nL2\nL20")
        TestHooks.startExposingSelection()
        textView.setSelectedRange(NSRange(location: 6, length: 3))
        XCTAssertEqual(textView.accessibilityLabel(), "selection:L20")
        textView.setSelectedRange(NSRange(location: 0, length: 2))
        XCTAssertEqual(textView.accessibilityLabel(), "selection:L1")
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertEqual(textView.accessibilityLabel(), "selection:")
    }

    func testNothingChangesWithoutTheFlag() {
        let textView = makeTextView("L1\nL2")
        TestHooks.start(arguments: ["QuickEdit"])
        textView.setSelectedRange(NSRange(location: 0, length: 2))
        XCTAssertNil(textView.accessibilityLabel(), "the hook ran without -QETestExposeSelection YES")
    }

    func testFieldEditorsAreLeftAlone() {
        let textView = makeTextView("L1")
        textView.isFieldEditor = true
        TestHooks.startExposingSelection()
        textView.setSelectedRange(NSRange(location: 0, length: 2))
        XCTAssertNil(textView.accessibilityLabel())
    }
}
#endif
