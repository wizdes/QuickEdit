# QuickEdit state

Rewritten at each milestone, never appended. Last rewrite: 2026-10-26, version 1.2.0.

Milestone: 1.2.0 (six user asks: blank untitled close, Sublime-like defaults with a line-number gutter, document map, Settings cleanup, new tab without the swap, Ctrl+1 to Ctrl+9) done. Plan: ~/.claude/plans/a-bunch-of-things-lucky-parasol.md. Next: the POST_MVP.md list, only when the user asks.
Branch / worktree / commit: dev is merged into main at each release. Work continues on dev (worktrees/dev).
Unmerged work: none.
Releases: 1.0 (2026-10-25); 1.0.1 (2026-10-26: About credit and README, repo made public, page at https://yili.dev/projects/quickedit/); 1.1.0 (2026-10-26: tabs); 1.2.0 (2026-10-26, tag on 05f87ca, DMG SHA-256 d69d92a2...6b51).

1.2.0 checks:
- Builder: a native Opus builder (the runner sandbox cannot run Xcode), two fix rounds.
- Reviews: Astra twice (qe-12-review-astra, qe-12-review2-astra). Accepted: reload race with the line index, index memory on huge files (gutter now off over 50 MB like the map), edit cost, map drag, gutter width, speed limits, quit tests, a paused-index reader. Rejected: whitespace-only untitled text over 1 MB still asks (the scan cap keeps Close fast).
- Also fixed: a 1.1.0 relaunch crash (AppKit restores an autosaved untitled document on a background thread and called the main-thread updateChangeCount override).
- Full run at the release: 569 of 570; the speech test fails on 1.1.0 too (POST_MVP.md). Packaged with --skip-tests on the same tree.
- Choices to check: Ctrl (not Cmd) for tab numbers; gutter and map on by default, toggled from the View menu; Paper size key kept (region default); Edit > Substitutions > Data Detectors item kept per window; an untouched empty untitled window is not restored at relaunch; Wrap to Page typing is slower at the 13 pt default (p95 9.3 ms Debug, optimized not measured).
- Follow-ups: the optimized speed run (`./build.sh speed`) was not run; new-tab frame check is a bench script (bench/newtab-xcresult-frames.sh) because this terminal cannot record the screen; page screenshots still show 1.1.0 without the gutter and map.

Earlier, M11 checks:
- Builder: a native Opus builder. It ran `./build.sh quick` (460 of 460) and the tab UI tests.
- Review: Astra (runner task qe-m11-review-astra). It found no app bug and 2 test gaps; both are fixed (Cmd+N tests no longer depend on the "Prefer tabs" setting; a large-file title test inside a tab).
- Full suite at the release: shell 5 of 5, unit 447 of 447, UI 64 of 64. The `./build.sh test` run hit its old 1,200 s limit after 47 UI tests had passed. The 17 UI tests it did not reach then passed in one `./build.sh only` run. The full-run limit is now 2,400 s.

Done-tests (M11): 1 to 3 TabUITests.testNewTabNextPreviousAndCloseTab; 4 TabUITests.testMergeAndMoveTabToNewWindow; 5 TabUITests and ShortcutTests; 6 TabTests menu tests; 7 as above.

Choices to check (M11): File > New Tab has its own target (NewTabCommand), not a nil target, because AppKit's own route opened a separate window in tests and stayed on under a Save panel; `TextDocument.isShowingSavePanel` turns New Tab off while a Save panel is open; LayoutTests.testMergeAllWindowsMakesTabs now makes its second window with Cmd+T and Move Tab to New Window.
Follow-ups (M11): ShortcutUITests.testChangedShortcutWorksAtOnceAndAfterARelaunch and WindowsAndMenusTests.testNewWindowCascades still depend on the "Prefer tabs" setting being off; Show Next and Previous Tab are not tested under a Save panel; group changes by drag and by restoration are tested only through the windows observation; in full screen, Esc to close a menu leaves full screen.

Earlier (M9, M10, 1.0): 483 of 485 at the 1.0 full run, the two failures passed alone and are on the flaky list in POST_MVP.md. The speed run was not run (user decision U13). Details are in git history of this file.
User decisions: U4 Keyboard tab is mockup A; U5 listed flaky tests may pass alone; U6 `./build.sh quick` for each change; U9 do not wait on the user for major or test changes; U11 one full run at the end; U13 no speed run.
Known limit: Untitled documents autosaved before M9, and old window positions, do not come back after the update (README).
Traps: another session's VM or build can push this 8 GB Mac into swap; UI tests need an unlocked screen and no typing; a full disk stops every build; test settings suites must delete their plist; NSTabView and other controls draw a black bar when drawn offscreen with cacheDisplay.
