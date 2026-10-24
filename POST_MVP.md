# Follow-ups after v1

One line each.

- Flaky: `LayoutTests.testDarkModeKeepsTextReadable` failed once with "Timed out while synthesizing event" while typing 540 characters (full run 2026-10-24 12:18, 217 of 218); it passed 3 of 3 reruns. Type less text or find what stalls event delivery.
- The real File menu shows both "Revert to Saved" and AppKit's own "Revert To".
- UI tests write to the shared system find pasteboard, so the user's Find field text changes after a test run.
- `PlainTextExtensionPanelDelegate` adds ".txt" only when the name has no extension; TextEdit says "no known extension", so `notes.v2` stays as typed.
- The Open Recent fix calls the private `_setMenuName:`; if AppKit drops it, the app logs to stderr and `MainMenuTests.testRealFileMenuHasOneOpenRecent` fails.
- Flaky: `EditActionsTests.testStartAndStopSpeakingDriveTheSpeechSynthesizer` ("Start Speaking did not start speech") failed in 3 full runs on 2026-10-24 and passed every time alone. It drives the system speech engine.
- M7: Wrap to Page reads `printInfo`, which connects to the system print helper (`com.apple.printtool.agent`, no network search). Use the planned paper-size setting so the app never contacts the print system (decision U1).
- Settings shots taken off screen show the tab names as a blank white bar; check on a real screen.
- UI tests fail with "Timed out while synthesizing event" when another app takes the front during a run: at 15:47 on 2026-10-24 Safari was in front and the test's key presses never reached QuickEdit (its main thread sat idle in the spindump). `testSelectLineRejectsBadEntry` then passed alone. Consider a `build.sh uicheck` warning, or a test setUp step that brings QuickEdit to the front.
