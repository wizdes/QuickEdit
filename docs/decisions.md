# Decisions

Critical questions go to Astra and Fable. The option with the most votes wins; root breaks a tie. Small choices are root's safe default and appear under "Choices to check".

## User decisions

- U8 (2026-10-25): the accessibility audit keeps its two skips (contrast, which other apps' floating windows made flaky, and AppKit's element-less "Parent/Child mismatch" from the shared text editor). In their place, a unit test checks text contrast at 4.5:1 or better, light and dark, in every window the audit covers: the document window, every Settings tab and Select Line. Done-test 1 counts as met with that note.
- U7 (2026-10-25): two existing tests updated for planned M9 changes: SettingsTests expects 3 tabs (adds Keyboard); M6ReviewFixTests expects 13 Tab stops (adds Paper size).
- U6 (2026-10-25): `./build.sh quick` (under 10 minutes: lint, unit tests but typing speed, 9 critical UI tests and the M9 UI test classes) is the check for each change. The full `./build.sh test` (about 25 minutes) runs only for a release.
- U5 (2026-10-25): a test already listed as flaky in POST_MVP.md that fails in a full run and passes when run again alone counts as passing (first case: `EditActionsTests.testStartAndStopSpeakingDriveTheSpeechSynthesizer` in the M9 sandbox run). Record each such retry in docs/STATE.md. Also: go on from M9 into M10 without stopping.
- U4 (2026-10-25): the Settings > Keyboard tab is mockup A, one flat table with a header row per menu (`docs/mockups/M9-keyboard.html`). This overrides vote V4 (B). Kept from the V4 changes because they fit A: the clash message stays on screen under the table and VoiceOver announces it; Edit's submenus are one level; recording and per-row reset work from the keyboard with spoken labels naming the command; the button is "Restore Keyboard Defaults". Not taken: search and folding groups (A has neither).
- U3 (2026-10-25): skip AppleScript and QuickEdit's own Services in M9. The Services menu that macOS adds by itself stays.

## Votes

### V1 (2026-10-23): which text engine?
Options: A, TextKit 2 everywhere (Wrap to Page redrawn as one tall view). B, TextKit 1 everywhere with `allowsNonContiguousLayout`, porting the old multi-container Wrap to Page. C, TextKit 2 for normal editing, rebuilt as TextKit 1 for Wrap to Page and printing.
- Astra: **B**. Wrap to Page, printing and zoom port directly; one engine is easier to keep; no measured TextKit 2 speed win exists.
- Fable: **B**. Same port argument; CotEditor handles 100 MB on TextKit 1; the one measured TextKit 2 number is a 3 s end jump; launch speed does not depend on the engine.
- Result: **B, 2 of 2.** This replaces the plan's "TextKit 2" wording (user decision 2 named TextKit 2 inside the recommended option; the user's own rule says the vote decides).
- What would reopen it (both voters): a Release benchmark on this Mac where TextKit 2 opens a 100 MB file (short lines and one giant paragraph) and jumps to the end with lower p95 time and lower peak memory than TextKit 1. M8 runs that benchmark.

### V1 check (2026-10-24): TextKit 2 benchmark, n=5, Release, this Mac (load 4.9, screen unlocked)
Medians, TextKit 1 vs TextKit 2 (full table: docs/research/tk2bench-n5.txt):
- 100 MB short lines: open+display 27 vs 17 ms; jump to end 11.9 vs 20.1 ms; typing p95 14.3 vs 1.7 ms; peak memory about 336-353 MiB both.
- 10 MB one line: open+display 12 vs 1,965 ms; jump to end 20 vs 2,315 ms; typing p50 26 vs 3,596 ms; TextKit 2 hit the 4 GiB cap after 4 of 200 keys (4.46 GB).
- Result: V1 stays closed (TextKit 1). The reopen rule needed TextKit 2 to win on both fixtures; it loses badly on the one-line file. Follow-up for M8: TextKit 1's typing p95 on 100 MB (14.3 ms) is higher than TextKit 2's, though under the 36 ms limit.

### V2 (2026-10-24): what should "Automatic" encoding detection do?
Options: A, match AppKit exactly (xattr, BOM, UTF-8, else Mac Roman; a stale xattr refuses to open), like TextEdit. B, add a guess with the encodings list as hints. C, add a guess with macOS's own detector, skip a stale xattr.
- Astra: **A**. Matching TextEdit is goal 1; a byte-exact round trip does not prove the shown text is right; the Open panel already lets users pick.
- Fable: **C**. TextEdit shows Mac Roman for nearly every non-UTF-8 file, which is wrong in practice; C reads more encodings right; a file that opens beats one that refuses.
- Result: tie, root breaks it: **A**. The user's brief says to check behavior against the current TextEdit, and a silent wrong guess is worse than a known fallback the user can override.
- What would reopen it: the user says older non-UTF-8 files matter in daily work.

### U1 (2026-10-24, user): no real printing, PDF only
The user said: "don't allow printing - just do a print to pdf". QuickEdit never opens the system Page Setup sheet or Print panel, and never talks to a printer. Reason found first: opening Page Setup makes macOS's print helper search the local network for printers, and macOS then asks "Allow QuickEdit to find devices on local networks?". Page Setup (added for M3+M5 review row 5) is removed. M7 makes Print… (Cmd+P) and Export as PDF… both save a PDF.

### U2 (2026-10-24, user): custom keyboard shortcuts
The user asked for keyboard shortcuts that can be changed for different commands, in a later milestone. It goes in M9.

### V3 (2026-10-25): what to do with very large files (about 1 GB)?
Measured (M8 builder, n=3): usable in 3,215 ms median; main thread blocked 286 ms median (limit 200 ms); peak memory +2,133 MB (limit 1.5 GB), of which the UTF-8 check's String copy is +1,025 MB; memory pressure warning in 4 of 6 runs.
Options: A, full editing at any size, fix the open costs; B, A's fixes plus a size limit above which the file opens read-only (view, find, select, copy, Save As) with a banner; C, refuse to open above a limit.
- Fable: B. Opening can be fixed, but editing, undo and save each copy about 1 GB more on an 8 GiB Mac; C does worse than TextEdit, which opens the file.
- Astra: B. Both limits are missed; remove the UTF-8 copy first; pick the limit from measurements (512 MB is a starting point); Save As must keep the bytes.
Result: B, 2 of 2. Read-only alone does not pass done-test 4; the open path must still meet both limits.

### V4 (2026-10-25): layout of the Settings > Keyboard tab (U2)?
Options (mockups: three rendered windows, 440 pt wide): A, one flat table at 11 pt with a header row per menu; B, a search field over an outline with one group per menu, 13 pt, 24 pt rows; C, a menu pop-up that shows one menu's commands, 32 pt rows with key caps.
- Fable: B. Search by name or by key reaches any of 59 commands fastest; NSOutlineView plus NSSearchField is stock AppKit and works with VoiceOver; C's key caps are custom drawing and the riskiest build.
- Astra: B. Search does not need the menu name; 13 pt and 24 pt rows fit 440 pt; more work than A, worth it for 59 commands.
Result: B, 2 of 2, then overridden by the user (U4: A). Changes both or one asked for, all taken: no popover, the clash message stays on screen under the list and VoiceOver announces it without moving focus (both); groups start expanded and search shows matches flat (Fable); Edit's submenus become one level, as "Find > Find..." rows (Fable); search also matches typed key names such as "cmd+shift+p" (Astra); recording and per-row reset work from the keyboard with spoken labels naming the command (Astra); the button is "Restore Keyboard Defaults" (Astra).

## Choices to check
- Reference build: the Apple copy (version 309) is the base, not zadr (285), because it is newer and has autosave, versions and Base.lproj. zadr is kept for its ARC changes.
- App Sandbox stays off until M9, then goes on with a full test re-run. Reason: tests and timing open files anywhere; the sandbox would block them before the rest works.
- Builds go to native Opus `builder` subagents, not the runner, because the runner sandbox cannot run Xcode or Swift tools (BeautifulWeather note, 2026-10-14). Astra reviews still use the runner.
- The 3 old UTF-8-only tests were deleted with the user's OK (2026-10-24); EncodingTests and testFailedOpenThroughTheControllerLeavesNoDocument cover the same code.
- M5's builder added `document.updateChangeCount(.changeCleared)` at the end of `testSaveIntoReadOnlyFolderFailsAndKeepsBytes` so a leftover edited document does not autosave into a deleted folder and hang the run with an alert. No assertion changed.
- Wrap to Page on a 10 MB file: switch 1.9 ms, then one 340 ms main-thread freeze while AppKit builds all glyphs (page mode lays text out in order, as in TextEdit). Left for M8.
- PDF paper size: with no Page Setup, PDFs and Wrap to Page use the Mac's default paper size (Letter or A4 by region). A paper-size choice in Settings is planned for M7; root picked this, not the user.
