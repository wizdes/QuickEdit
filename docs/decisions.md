# Decisions

Critical questions go to Astra and Fable. The option with the most votes wins; root breaks a tie. Small choices are root's safe default and appear under "Choices to check".

## Votes

### V1 (2026-10-23): which text engine?
Options: A, TextKit 2 everywhere (Wrap to Page redrawn as one tall view). B, TextKit 1 everywhere with `allowsNonContiguousLayout`, porting the old multi-container Wrap to Page. C, TextKit 2 for normal editing, rebuilt as TextKit 1 for Wrap to Page and printing.
- Astra: **B**. Wrap to Page, printing and zoom port directly; one engine is easier to keep; no measured TextKit 2 speed win exists.
- Fable: **B**. Same port argument; CotEditor handles 100 MB on TextKit 1; the one measured TextKit 2 number is a 3 s end jump; launch speed does not depend on the engine.
- Result: **B, 2 of 2.** This replaces the plan's "TextKit 2" wording (user decision 2 named TextKit 2 inside the recommended option; the user's own rule says the vote decides).
- What would reopen it (both voters): a Release benchmark on this Mac where TextKit 2 opens a 100 MB file (short lines and one giant paragraph) and jumps to the end with lower p95 time and lower peak memory than TextKit 1. M8 runs that benchmark.

## Choices to check
- Reference build: the Apple copy (version 309) is the base, not zadr (285), because it is newer and has autosave, versions and Base.lproj. zadr is kept for its ARC changes.
- App Sandbox stays off until M9, then goes on with a full test re-run. Reason: tests and timing open files anywhere; the sandbox would block them before the rest works.
- Builds go to native Opus `builder` subagents, not the runner, because the runner sandbox cannot run Xcode or Swift tools (BeautifulWeather note, 2026-10-14). Astra reviews still use the runner.
