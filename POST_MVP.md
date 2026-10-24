# Follow-ups after v1

One line each.

- Flaky: `LayoutTests.testDarkModeKeepsTextReadable` failed once with "Timed out while synthesizing event" while typing 540 characters (full run 2026-10-24 12:18, 217 of 218); it passed 3 of 3 reruns. Type less text or find what stalls event delivery.
- The real File menu shows both "Revert to Saved" and AppKit's own "Revert To".
- UI tests write to the shared system find pasteboard, so the user's Find field text changes after a test run.
- `PlainTextExtensionPanelDelegate` adds ".txt" only when the name has no extension; TextEdit says "no known extension", so `notes.v2` stays as typed.
- The Open Recent fix calls the private `_setMenuName:`; if AppKit drops it, the app logs to stderr and `MainMenuTests.testRealFileMenuHasOneOpenRecent` fails.
