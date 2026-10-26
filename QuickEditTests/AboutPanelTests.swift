import AppKit
import XCTest
@testable import QuickEdit

/// M10 n2: About QuickEdit. The standard About panel
/// (`orderFrontStandardAboutPanel:`, MainMenuTests) reads its text from the
/// app bundle: the name, version and build from Info.plist, the copyright
/// from `NSHumanReadableCopyright`, and the credit line from Credits.rtf.
/// The test host is the app, so `Bundle.main` is the built QuickEdit.app.
final class AboutPanelTests: XCTestCase {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    func testNameVersionAndBuildComeFromInfoPlist() {
        XCTAssertEqual(info["CFBundleName"] as? String, "QuickEdit")
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "1.1.0")
        let build = info["CFBundleVersion"] as? String ?? ""
        XCTAssertFalse(build.isEmpty, "CFBundleVersion is empty")
        XCTAssertNotNil(Int(build), "CFBundleVersion is not a build number: \(build)")
    }

    func testCopyrightIsYiLi2026() {
        XCTAssertEqual(info["NSHumanReadableCopyright"] as? String, "\u{00A9} 2026 Yi Li")
    }

    func testCreditsHoldTheOneCreditLine() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Credits", withExtension: "rtf"),
                                "Credits.rtf is not in the app bundle")
        let credits = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        XCTAssertEqual(credits.string.trimmingCharacters(in: .whitespacesAndNewlines),
                       "A fast plain-text editor for macOS.")
    }
}
