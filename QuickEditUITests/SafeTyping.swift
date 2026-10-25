import AppKit
import XCTest

/// The only place in QuickEditUITests that sends keys.
///
/// XCUITest's typeText and typeKey send keys to whatever app is in front.
/// When another app comes to the front during a run (a browser, the user's
/// terminal), the keys go there: a Return in a shell runs a command. So every
/// key press and typed string goes through `safeType` or `safePress`, which
/// first check that QuickEdit is the frontmost app and fail the test at once,
/// without sending any key, when it is not. Long strings go in chunks of at
/// most `safeTypeChunk` characters, checked before each chunk, so losing the
/// front mid-string stops within one chunk.
///
/// bench/tests/raw-typing-lint-test.sh fails on any typeText or typeKey call
/// outside this file.

extension QuickEditUITestCase {
    static let quickEditBundleID = "dev.yili.QuickEdit.debug"  // the Debug build (project.yml)
    static let safeTypeChunk = 20

    /// Types `text` into `target` (the app when nil), in short chunks, each
    /// after a frontmost check.
    func safeType(_ text: String, into target: XCUIElement? = nil,
                  file: StaticString = #filePath, line: UInt = #line) {
        var rest = Substring(text)
        while !rest.isEmpty {
            let chunk = rest.prefix(Self.safeTypeChunk)
            rest = rest.dropFirst(chunk.count)
            guard quickEditIsFrontmost(before: "typing \(String(chunk).debugDescription)",
                                       file: file, line: line) else { return }
            (target ?? app).typeText(String(chunk))
        }
    }

    /// Presses `key` with `modifierFlags` on `target` (the app when nil),
    /// after a frontmost check.
    func safePress(_ key: String, _ modifierFlags: XCUIElement.KeyModifierFlags,
                   on target: XCUIElement? = nil, file: StaticString = #filePath, line: UInt = #line) {
        guard quickEditIsFrontmost(before: "pressing \(key.debugDescription)", file: file, line: line) else {
            return
        }
        (target ?? app).typeKey(key, modifierFlags: modifierFlags)
    }

    func safePress(_ key: XCUIKeyboardKey, _ modifierFlags: XCUIElement.KeyModifierFlags,
                   on target: XCUIElement? = nil, file: StaticString = #filePath, line: UInt = #line) {
        guard quickEditIsFrontmost(before: "pressing \(key.rawValue.debugDescription)", file: file, line: line) else {
            return
        }
        (target ?? app).typeKey(key, modifierFlags: modifierFlags)
    }

    /// True when QuickEdit is in front by both XCUITest's view
    /// (`XCUIApplication.state`) and the window server's
    /// (`NSWorkspace.frontmostApplication`). Otherwise fails the test, which
    /// stops it (continueAfterFailure is false), and returns false so the
    /// caller sends nothing either way.
    private func quickEditIsFrontmost(before action: String, file: StaticString, line: UInt) -> Bool {
        guard let app else {
            XCTFail("not \(action): QuickEdit was not launched", file: file, line: line)
            return false
        }
        // Let NSWorkspace take any pending front-app change before reading it.
        RunLoop.current.run(mode: .default, before: Date())
        let state = app.state
        let front = NSWorkspace.shared.frontmostApplication
        if state == .runningForeground && front?.bundleIdentifier == Self.quickEditBundleID {
            return true
        }
        XCTFail("not \(action): QuickEdit is not the frontmost app, so no key was sent "
                + "(XCUIApplication.state \(state.rawValue), 4 is runningForeground; "
                + "frontmost app \(front?.bundleIdentifier ?? "none") \(front?.localizedName ?? ""))",
                file: file, line: line)
        return false
    }
}
