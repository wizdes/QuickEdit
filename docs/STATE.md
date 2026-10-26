# QuickEdit state

Rewritten at each milestone, never appended. Last rewrite: 2026-10-25, M9 and M10 done, version 1.0 released.

Milestone: M10 (finish) done; all 10 milestones done. Next: the POST_MVP.md list, only when the user asks.
Branch / worktree / commit: dev merged into main at the v1.0 release. Work continues on dev (worktrees/dev).
Unmerged work: none.

Checks run at the release (one run for M9 and M10, user decisions U11 to U13):
- `./build.sh test`: shell tests 5 of 5; unit and UI 483 of 485. Two failures passed when run alone and are now on the flaky list in POST_MVP.md: `PageModeTests.testPagesAreAddedAsLayoutReachesThemAndRemovedWhenEmpty` ("21" vs "1", swap 3.9 GB in use) and `FindAndLineTests.testReplaceAllIgnoringCase` ("Not hittable: All").
- `./build.sh speed`: NOT RUN (user: skip it, 2026-10-25). So the U10 PDF memory limit with the sandbox on, and the large-file speed limits with the sandbox on, are unchecked.
- No M10 review (user decision U12). M9 had two reviews per part: docs/reviews/M9-code.md rows 1-26.
- Release: builds/QuickEdit-1.0.dmg, app and DMG notarized (Accepted) and stapled; Gatekeeper accepts both; entitlements exactly app-sandbox and files.user-selected.read-write; SHA-256 7aa28f312d5e0d68f2a1cbf6291e4bddcb52dc4ba2aa6f5b5f35367318d22eef.

Done-tests:
- M9 1 (accessibility audit, no errors): met with the U8 note (contrast and AppKit's element-less "Parent/Child mismatch" skipped in the audit; ContrastTests checks 4.5:1 in every audited window).
- M9 2 (shortcut works at once, after relaunch, clash refused): ShortcutUITests.
- M9 3 (exactly two entitlements): checked on the release DMG.
- M9 4 (full suite with the sandbox on): 483 of 485, the two above passed alone.
- M9 5 (settings survive the move): sandbox-release-test.sh with a scratch bundle ID; the user's real container does not exist yet, so the move will run on first launch.
- M10 1 (every parity row proven or left out): 50 of 50.
- M10 2 (full suite): as above.
- M10 3 (notarized DMG): as above.
- M10 4 (own icon, About box): icon rendered through NSWorkspace at 512 and 64 px; AboutPanelTests.

User decisions this session: U4 Keyboard tab is mockup A; U5 listed flaky tests may pass alone; U6 `./build.sh quick` for each change; U7 two test counts updated; U8 audit skips plus a contrast test; U9 do not wait on the user for major or test changes; U10 PDF memory checked only in the speed run; U11 one full run at the end; U12 no M10 review; U13 no speed run; Quick Look test via QLThumbnailGenerator.
Choices to check: docs/decisions.md "Choices to check"; icon draft A (drafts in docs/icon-drafts); Restore All Defaults also clears shortcuts; Open Recent > Clear Menu has no custom shortcut; quick runs 2 of the 9 SandboxUITests; one large-file UI test, not two; old fixture folders removed after 2 hours.
Known limit: Untitled documents autosaved before M9, and old window positions, do not come back after the update (README).
Traps: another session's VM or build can push this 8 GB Mac into swap; UI tests need an unlocked screen and no typing; a full disk stops every build (2026-10-25: 159 MB free); test settings suites must delete their plist (3,837 leftovers were deleted).
