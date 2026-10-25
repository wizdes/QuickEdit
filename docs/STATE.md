# QuickEdit state

Rewritten at each milestone, never appended. Last rewrite: 2026-10-25, M8 done and merged into main.

Milestone: M8 (speed) done. Next: M9 (system parts, custom keyboard shortcuts U2, sandbox on).
Branch / worktree / commit: dev, merged into main at each milestone check. Work continues on dev (worktrees/dev).
Unmerged work: none.
Checks run at the M8 merge: `./build.sh test` 417 of 417 (unit and UI), shell tests 3 of 3; `./build.sh speed` 11 of 12 (the 1 GB open blocked 304 ms vs 200 ms under memory pressure level 2 with another session's VM at 2.6 GB; user: re-test later). M8 build notarized: builds/QuickEdit-M8.zip (Accepted, stapled). Diagram: docs/diagrams/M8.html. Reviews: docs/reviews/M8-code.md rows 1-44.
Not met: done-test 1. Launch race 2026-10-25 (swap 1.7 GB): QuickEdit ready 312.3 ms vs TextEdit 317.3 ms; goal 25 ms faster. User: merge now, race again later. M7 race on a quieter Mac: 269.4 vs 292.6 ms.
Speed facts (builder unit-level measurements): 100 MB open 525 to 80 ms; 10 MB Wrap to Page freeze 358 to 34.5 ms; 10 MB PDF export freeze 3,669 to under 50 ms (background job with Cancel); 1 GB opens read-only in 670 ms, 52 ms freeze, 1,144 MB peak (quiet Mac); typing p95 at the start of 100 MB in Wrap to Page 5.65 ms.
User decisions: plain text, Swift, QuickEdit, vote rule, plan (2026-10-23); U1 PDF only; U2 custom shortcuts in M9; UI tests guard every key press (2026-10-24); ReviewFixTests closes its document; M8ReviewFixTests reload test waits for the reload to end; PDF export memory checked only in the speed run; finish M8 with the 1 GB check and the launch goal re-tested later (all 2026-10-25). Votes: V1 TextKit 1, V2 match AppKit encoding detection, V3 read-only over 512 MiB.
Choices to check: docs/decisions.md "Choices to check"; M8: large-file note in the window title; background PDF over 100,000 characters; 12 ms idle layout slices; read-only limit 512 MiB; no Save As, Save To or Duplicate for a read-only file on a disk that cannot clone; empty window during a large reload; Duplicate allowed for a read-only file on APFS.
Traps: another session's VM can push this 8 GB Mac into swap and spoil speed numbers; UI tests need an unlocked screen and no typing; flaky checks are listed in POST_MVP.md.
Next action: plan M9 (docs/plans/M9.md), then build.
