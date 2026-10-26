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
- M8: re-run `LargeFileSpeedTests.testOneGigabyteOpensReadOnlyWithinTheLimits` with no VM and no swap; it blocked 304 ms (limit 200) on 2026-10-25 at memory pressure level 2. If it still fails, check whether the clone taken before the read adds to the first display.
- M8: the 10 MB one-line file still blocks the main thread about 3.4 s on open.
- M8: the first read of a text's attributes costs about 160 ms per 10 MB; any whole-text pass on the main thread pays it.
- M8: Wrap to Page eventually makes one text view per page (about 3,300 for 10 MB); a read-only 1 GB file in Wrap to Page needs a memory check.
- M8: Duplicate of a 1 GB read-only file makes a second 1.1 GB copy (over the 1.5 GB limit).
- M8: quitting during a background PDF export may leave the temp folder behind.
- M8: a paragraph over 1M characters stays one PDF piece; memory and Cancel time unproven for it.
- M8: a non-UTF-8 large file still decodes to a full String on open and on reload; the size limit counts file bytes, not memory.
- M8: the byte count is not updated after Save As in another encoding; a disk that cannot clone reads during a reload after file access ends; the lossy flag is cleared by the overwrite confirmation.
- M8: macOS may clean `$TMPDIR` while a window stays open for days, which would remove a read-only file's clone; Save As would then fail.
- M8: launch build settings: `-Osize` with LTO has the smallest code (304 KB `__TEXT` vs 400 KB); race it against `-O` on a quiet Mac.
- Flaky: `bench/tests/launchbench-test.sh` "already-running target" failed once in a full run on 2026-10-25 (load 4) and passed alone twice. It waits a fixed 1 s for the fake app to register; wait for the registration instead.
- M8 done-test 1 not met: launch race 2026-10-25 11:11 (swap 1.7 GB), QuickEdit ready 312.3 ms vs TextEdit 317.3 ms (goal: 25 ms faster). Race again with no VM and no swap; try `-Osize` with LTO.
- Flaky: `PageModeTests.testPagesAreAddedAsLayoutReachesThemAndRemovedWhenEmpty` failed in the final full run on 2026-10-25 ("XCTAssertEqual failed: ("21") is not equal to ("1")", swap 3.9 GB in use) and passed alone. Find what in the idle page layout depends on timing.
- Flaky: `FindAndLineTests.testReplaceAllIgnoringCase` failed in the same run ("Not hittable: Button ... label: 'All'") and passed alone. Wait for the find bar's All button to be hittable before the click.
