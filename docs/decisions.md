# Decisions

Critical questions go to Astra and Fable. The option with the most votes wins; root breaks a tie. Small choices are root's safe default and appear under "Choices to check".

## Votes

### V1 (2026-10-23): which text engine?
Options: A, TextKit 2 everywhere (Wrap to Page redrawn as one tall view). B, TextKit 1 everywhere with `allowsNonContiguousLayout`, porting the old multi-container Wrap to Page. C, TextKit 2 for normal editing, rebuilt as TextKit 1 for Wrap to Page and printing.
- Astra: **B**. Wrap to Page, printing and zoom port directly; one engine is easier to keep; no measured TextKit 2 speed win exists.
- Fable: **B**. Same port argument; CotEditor handles 100 MB on TextKit 1; the one measured TextKit 2 number is a 3 s end jump; launch speed does not depend on the engine.
- Result: **B, 2 of 2.** This replaces the plan's "TextKit 2" wording (user decision 2 named TextKit 2 inside the recommended option; the user's own rule says the vote decides).
- What would reopen it (both voters): a Release benchmark on this Mac where TextKit 2 opens a 100 MB file (short lines and one giant paragraph) and jumps to the end with lower p95 time and lower peak memory than TextKit 1. M8 runs that benchmark.

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

## Choices to check
- Reference build: the Apple copy (version 309) is the base, not zadr (285), because it is newer and has autosave, versions and Base.lproj. zadr is kept for its ARC changes.
- App Sandbox stays off until M9, then goes on with a full test re-run. Reason: tests and timing open files anywhere; the sandbox would block them before the rest works.
- Builds go to native Opus `builder` subagents, not the runner, because the runner sandbox cannot run Xcode or Swift tools (BeautifulWeather note, 2026-10-14). Astra reviews still use the runner.
- The 3 old UTF-8-only tests were deleted with the user's OK (2026-10-24); EncodingTests and testFailedOpenThroughTheControllerLeavesNoDocument cover the same code.
- M5's builder added `document.updateChangeCount(.changeCleared)` at the end of `testSaveIntoReadOnlyFolderFailsAndKeepsBytes` so a leftover edited document does not autosave into a deleted folder and hang the run with an alert. No assertion changed.
- Wrap to Page on a 10 MB file: switch 1.9 ms, then one 340 ms main-thread freeze while AppKit builds all glyphs (page mode lays text out in order, as in TextEdit). Left for M8.
- PDF paper size: with no Page Setup, PDFs and Wrap to Page use the Mac's default paper size (Letter or A4 by region). A paper-size choice in Settings is planned for M7; root picked this, not the user.
