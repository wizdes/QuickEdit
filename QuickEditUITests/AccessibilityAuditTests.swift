import XCTest

/// M9 done-test 1: the accessibility audit (Accessibility Inspector's audit,
/// run by XCUITest) finds no issues in the document window, each Settings
/// tab, and the Select Line panel.
///
/// Two kinds of issue are left out, and docs/STATE.md says so:
/// - Contrast. On this Mac the screen-based contrast check flags different
///   standard AppKit labels (labelColor, white on dark gray) on each run,
///   with other apps' windows on screen. The colors QuickEdit picks itself
///   are checked exactly in ShortcutTests.testKeyboardTabColorsHaveEnoughContrast.
/// - "Parent/Child mismatch" with no element, while a text field has focus:
///   AppKit's field editor reports the tab view (or the panel) as its
///   parent, which does not list it (measured 2026-10-25). The window's own
///   elements are all still audited.
@MainActor
final class AccessibilityAuditTests: QuickEditUITestCase {
    /// Every issue the audit finds now, one line each.
    private func audit(_ what: String) throws -> [String] {
        var issues: [String] = []
        let types = XCUIAccessibilityAuditType.all.subtracting(.contrast)
        try app.performAccessibilityAudit(for: types) { issue in
            if issue.element == nil, issue.compactDescription == "Parent/Child mismatch" { return true }
            let element = issue.element.map { "type \($0.elementType.rawValue) id '\($0.identifier)' label '\($0.label)' "
                + "value '\(String(describing: $0.value))' frame \($0.frame)" } ?? "no element"
            issues.append("\(what): \(issue.compactDescription) (\(issue.detailedDescription)) [\(element)]")
            // Collect every issue; the test fails once with the whole list.
            return true
        }
        return issues
    }

    /// A document with text, not edited: typing would add AppKit's grey
    /// "— Edited" to the title bar.
    func testDocumentWindowHasNoAuditIssues() throws {
        launch(opening: try fixtureFolder("open-type-save").appendingPathComponent("hello.txt").path)
        XCTAssertEqual(try audit("document window"), [])
    }

    func testEverySettingsTabHasNoAuditIssues() throws {
        launch(extraArguments: ["-QETestDefaultsSuite", ShortcutUITests.suite, "-QETestDefaultsSuiteReset", "YES"])
        safePress(",", .command)
        let settings = app.windows["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        var issues: [String] = []
        for name in ["New Document", "Open and Save", "Keyboard"] {
            let tab = settings.tabs[name].exists ? settings.tabs[name] : settings.radioButtons[name]
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "no tab \(name)")
            tab.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            attachScreenshot("settings-\(name)", settings.screenshot())
            issues += try audit("Settings > \(name)")
        }
        XCTAssertEqual(issues, [])
    }

    func testSelectLinePanelHasNoAuditIssues() throws {
        launch()
        safePress("l", .command)
        // macOS 27 reports this NSPanel as a dialog (FindAndLineTests).
        XCTAssertTrue(app.dialogs["Select Line"].waitForExistence(timeout: 5))
        XCTAssertEqual(try audit("Select Line panel"), [])
    }
}
