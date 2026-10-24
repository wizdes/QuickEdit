# QuickEdit state

Rewritten at each milestone, never appended. Last rewrite: 2026-10-23, M1 built, M2 building.

Milestone: M2 (document life) plus M1 review fixes; one native Opus builder in flight in a scratch clone.
Branch / worktree / commit: dev / worktrees/dev / 9b4bf95. main holds docs only so far.
Unmerged work: M1 code is on dev (c385638), not merged to main, because its UI tests have not run.
Checks run: `./build.sh unit` 26 passed of 26; `./build.sh` Release OK (ad-hoc); `reference/build-reference.sh` OK, 0 errors.
Not run: 8 UI tests (Automation Mode off, needs the user's admin password; screen lock), launch bench for QuickEdit, screenshots, notarization (keychain locked).
Builds: `builds/QuickEdit-M1-unit-tests-only.zip` (66,968 bytes, ad-hoc, not notarized; has the revert crash fixed in M2).
Speed bar: TextEdit 265.2 ms median to window (n=7); 276.6 ms with the untitled-window argument.
Approvals: see `docs/decisions.md` (plain text, Swift, QuickEdit, vote rule, 10-milestone plan; V1 TextKit 1).
Open questions: see `docs/AWAY_LOG.md` (Automation Mode, keychain, Screen Recording, Antigravity login).
Dead ends (do not retry): osascript System Events for window checks (times out); runner sandbox for Xcode builds.
Next action: when the M2 builder reports, copy its owned files onto dev, run `./build.sh unit` and `xcodebuild build-for-testing`, then start the M2 reviews.
