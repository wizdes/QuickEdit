# QuickEdit state

Rewritten at each milestone, never appended. Last rewrite: 2026-10-24, M1 to M5 built on dev.

Milestone: M6 (Settings) building; encoding change (vote V2, match AppKit) building; M3+M5 reviews (Astra and Opus) running.
Branch / worktree / commit: dev / worktrees/dev / 0485e07. main holds docs only; dev merges into main when UI tests have run.
Unmerged work: all app code is on dev.
Checks run: `./build.sh unit` 155 of 155 (shell tests 2 of 2); `xcodebuild build-for-testing` OK; Release build signs with Developer ID.
Not run: about 40 UI tests (screen locked: CGSSessionScreenIsLocked true), launch timing for QuickEdit, TextEdit side-by-side checks, notarization of milestone builds after M1.
Speed facts so far: TextEdit launch 265.2 ms; Select Line 1,000,000 of 100 MB 93.8 ms forward, 91.4 ms backward; 10 MB switch to Wrap to Page 1.9 ms then one 340 ms freeze (M8).
Approvals: plain text, Swift, QuickEdit, vote rule, plan (2026-10-23); delete 3 old UTF-8-only tests (2026-10-24). Votes V1 TextKit 1, V2 match AppKit encoding detection.
Open questions: screen lock (user).
Dead ends: osascript System Events; runner sandbox for Xcode builds; `rm -rf` with variable paths (blocked by the safety check; use literal paths).
Next action: merge the encoding change and M6 onto dev, fix review findings, then plan M7 (printing and PDF).
