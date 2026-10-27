import XCTest

/// 1.2.0 change 5: the steps a screen recording of New Tab needs. In a
/// normal run this only checks that Cmd+T adds a tab from one tab and from
/// two. For the frame check, run it alone with screen recording on (the
/// scheme's preferredScreenCaptureFormat = screenRecording); the
/// recording in the result bundle is then read with bench/frames.swift
/// (bench/newtab-frames.sh needs Screen Recording for the terminal).
/// Each Cmd+T is preceded by a still second, so its frames stand apart.
@MainActor
final class NewTabRecordingUITests: QuickEditUITestCase {
    private var tabCount: Int {
        let group = app.windows.firstMatch.tabGroups.firstMatch
        return group.exists ? group.tabs.count : 0
    }

    func testNewTabFromOneTabAndFromTwo() throws {
        launch(extraArguments: ["-QETestDefaultsSuite", ShortcutUITests.suite, "-QETestDefaultsSuiteReset", "YES",
                                "-AppleInterfaceStyle", "Light"])
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        safeType("first tab")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        // Marker 1 (from one tab).
        safePress("t", .command)
        waitUntil(10, "Cmd+T made no second tab") { self.tabCount == 2 }
        safeType("second tab")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        // Marker 2 (from two tabs).
        safePress("t", .command)
        waitUntil(10, "Cmd+T made no third tab") { self.tabCount == 3 }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }
}
