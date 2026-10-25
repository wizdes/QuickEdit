# QuickEdit state

Rewritten at each milestone, never appended. Last rewrite: 2026-10-24, M7 done and merged into main.

Milestone: M7 (PDF output) done. Next: M8 (speed).
Branch / worktree / commit: dev at 5920d65, merged into main at 8c90440. Work continues on dev (worktrees/dev) and merges into main at each milestone check.
Unmerged work: none.
Checks run at 5920d65's code (b750aae): `./build.sh test` 315 of 315 (unit and UI, shell tests 3 of 3). M7 build notarized: builds/QuickEdit-M7.zip (Accepted, stapled). Diagram: docs/diagrams/M7.html.
Not run: TextKit 2 benchmark at n=5 (needs a quiet Mac); typing latency; M2 to M6 notarized builds and diagrams (only M1 and M7 have builds).
Speed facts: launch to keystroke-ready 269.4 ms vs TextEdit window 292.6 ms (median of 5, 2026-10-24); Select Line near line 1,000,000 of 100 MB about 91 ms each way; 10 MB switch to Wrap to Page 4 ms; 1 MB to PDF 492 ms (Wrap to Window), 883 ms (Wrap to Page).
User decisions: plain text, Swift, QuickEdit, vote rule, plan (2026-10-23); 3 old UTF-8 tests deleted; 3 UI test assertion changes; encoding test changes; U1 PDF only, no printing; U2 custom keyboard shortcuts in M9; UI tests guard every key press and the dark mode test opens a file (all 2026-10-24). Votes: V1 TextKit 1, V2 match AppKit encoding detection.
Choices to check: docs/decisions.md "Choices to check"; M7: PDFs drawn by QuickEdit (Core Graphics), header and footer look, paper-size pop-up not in the Tab order.
Traps: UI tests type into the front app (now guarded); Page Setup triggers a local-network prompt (removed); full-screen test shots show the user's desktop; the disk filled once (clear build/ and old scratch clones).
Next action: TextKit 2 benchmark n=5 when the Mac is idle, then plan and build M8.
