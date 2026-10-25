# QuickEdit: a plain-text TextEdit rebuilt for macOS 27

## Context

The user has two copies of Apple's old TextEdit sample code:
- Apple's archive sample (https://developer.apple.com/library/archive/samplecode/TextEdit/), the 10.8 version.
- github.com/zadr/TextEdit, the same 10.8 code with ARC, properties and warning fixes (last push 2013).

Both are Objective-C, about 20 source files (Document.m 71 KB, DocumentWindowController.m 52 KB, DocumentController.m 18 KB, EncodingManager.m 16 KB, plus print, page view, line panel and preferences). They do not build on macOS 27.0.1 with Xcode 27.1 as they are.

The goal is a working, very fast Mac app built from that code, checked against today's system TextEdit, delivered one milestone at a time with a build after each one.

User decisions (2026-10-23):
1. Plain text only. No rich-text mode, font panel, ruler, colors, pictures, or RTF, RTFD, HTML or Word files.
2. Swift on AppKit with NSTextView (TextKit 2). The old Objective-C is built once in M1 as a reference copy.
3. The app is named **QuickEdit**, bundle ID `dev.yili.QuickEdit`. (Note: `Projects/QuickPad` is a different, older project.)
4. Do not block on the user. For a critical question, ask Astra and Fable. The option with the most votes wins. On a tie, root's vote decides. Each vote goes into `docs/decisions.md`.

Tier: **Tier 3**, because it is a new project. It gets unit, integration and full end-to-end tests, a fresh review per milestone (Astra plus a native Opus reviewer), and a change diagram per milestone.

## Where things live

- Repo: `~/work/Projects/QuickEdit`, private GitHub remote `wizdes/QuickEdit`. Work happens in a Tier 3 worktree, merged into main at each milestone check.
- `reference/apple/` and `reference/zadr/`: both old sources, unchanged, for reading only.
- `docs/`: `research.md`, `design-readable.md` (Doc A), `design-spec.md` (Doc B), `plans/M<n>.md`, `STATE.md`, `AWAY_LOG.md`, `decisions.md`, `parity.md` (each TextEdit behavior and its status).
- `POST_MVP.md` for follow-ups.
- `builds/QuickEdit-M<n>.zip`: signed and notarized, plus a GitHub release on the private repo for each milestone.

## Reuse from Fastpad

`Projects/Fastpad` already measures a Mac editor against TextEdit. QuickEdit copies (not links) these files and adapts them:
- `bench/launchbench.swift` and `bench/run-bench.sh` for launch time against TextEdit. They interleave runs and log discards.
- `bench/typetest.sh` for typing latency (frames from key press to screen).
- `bench/make-fixtures.sh` for large test files.
- The notarize flow from the Fastpad memory note: `build.sh --devid`, ditto zip, `xcrun notarytool submit --wait --keychain-profile fastpad-notary`, `stapler staple`. It reuses the existing keychain profile, so no new credential is needed.

Fastpad traps that apply here: never `defaults read` another app's domain from a bench script (pass `-Key Value` arguments instead). The screen must be unlocked for UI tests and timing. Only root runs speed measurements. After a bench run, relaunch TextEdit if it was open.

## Stage 0: research and the plan page (before M1, about 3 hours)

1. Clone both sources into `reference/`. Download the Apple zip into its own empty folder first.
2. Run in parallel:
   - An Astra investigator through the runner reads both code bases. It returns a map of every class and what it does, the differences between the Apple and zadr copies, the API calls removed or deprecated since 10.8, and the rich-text code paths to drop.
   - The `research-sources` skill plus an Astra advisor on "how to make a Mac app extremely fast": launch time (dyld, linked frameworks, no work before first frame, lazy nib or code UI), TextKit 2 large-file layout, memory, energy, Instruments use. Sources must be dated and linked.
   - Root measures today's TextEdit as the bar: launch time, typing latency, and open time for a 10 MB, 100 MB and 1 GB plain file. It uses the Fastpad bench scripts, n=5, as medians.
3. Root writes `docs/research.md` and `docs/parity.md`. `docs/parity.md` lists every TextEdit plain-text behavior: menus, panels, dialogs, autosave, encodings, and so on.
4. Root publishes the 10-milestone plan as a private Artifact page with a milestone diagram. The user reviews it while work goes on.

## The 10 milestones

Each milestone ends with a working app, a notarized build, a hands-on script for the user, and a row of speed numbers (launch, typing, open). Each milestone also has a "not in this version" list, written in its plan file.

| # | Milestone | What it adds | Done-test | Budget |
|---|---|---|---|---|
| 1 | Skeleton and reference | The old zadr code built on macOS 27 as `reference/build` (fix only what blocks the build). A new Swift app from an XcodeGen `project.yml`: NSDocument, NSDocumentController, one window with a TextKit 2 NSTextView. It can open, edit and save UTF-8 `.txt`. Test targets, bench scripts and `build.sh` work. | One command builds, runs the tests and makes a notarized zip. A UI test opens a file, types, saves, and the bytes on disk match. | 5 h |
| 2 | Document life | Autosave in place, Versions (browse and revert), Duplicate, Rename, Move To, locked files, a file changed by another app, Open Recent, windows restored after relaunch, the unsaved-changes dialogs. | The parity script makes the same edits in TextEdit and QuickEdit. Both leave the same files and the same version list. | 4 h |
| 3 | Encodings and line endings | A Swift port of EncodingManager: the encoding pop-up in Open and Save panels, the guess on open, BOM handling, the "can't save in this encoding" alert, and CR, LF and CRLF kept as found. | A set of about 30 fixture files in different encodings opens, saves and comes back byte-for-byte equal. The guesses match TextEdit's for each file. | 4 h |
| 4 | Find and editing tools | Find bar and Find and Replace (NSTextFinder), Go to Line (port of LinePanelController), spelling and grammar, Substitutions and Transformations menus, completion, Speech. | UI tests cover find, replace all, regex-free search, case, wrap-around and go to line. Menu items match TextEdit's plain-text menus item by item. | 3 h |
| 5 | Layout and view | Wrap to Window and Wrap to Page (port of MultiplePageView and ScalingScrollView), zoom, full screen, window tabs, dark mode, the plain-text font. | Screenshots of both modes at 3 zoom levels next to TextEdit's. Root reads them. | 4 h |
| 6 | Settings | The Settings window: new-document size in characters, plain-text font, encodings for open and save, "add .txt extension", spelling defaults, autosave choices. | Each setting is changed by a UI test, survives relaunch, and changes the next new window as it does in TextEdit. | 3 h |
| 7 | PDF output (no printing, user decision U1) | Print… and Export as PDF… both save a PDF, with header and footer and wrap choices (port of PrintPanelAccessoryController and PrintingTextView) in the Save panel, and a paper-size setting. No Page Setup, no Print panel, no printer. | Exported PDFs for 3 fixtures have the right page count and text. No code path opens the Print panel or Page Setup. | 3 h |
| 8 | Speed | The fast pass: trim launch work, lazy menus and panels, TextKit 2 settings for large files, background open with a progress state, memory and energy checks in Instruments. | Launch median at least 25 ms faster than TextEdit. Typing p50 ≤ 1.5 frames + 3 ms. 100 MB file usable in under 1 second. 1 GB file opens with no beachball. All n=5 medians. | 6 h |
| 9 | System parts and custom shortcuts | AppleScript (sdef from the old scriptSuite), Services, drag and drop, Share menu, Writing Tools, VoiceOver and keyboard checks, Quick Look of `.txt` files. A Keyboard tab in Settings to change the shortcut of any menu command (user decision U2), with conflict warnings and Restore Defaults. | An AppleScript test script opens, edits and saves a file. An Accessibility Inspector audit has no errors. A changed shortcut works at once, survives relaunch, and a clash with another command is refused. | 5 h |
| 10 | Finish | App icon (3 drafts, root picks one, the user can swap later), About box, README, DMG, the full parity sweep of every row in `docs/parity.md`, and the final review. | Every parity row is "same", "better", or "left out on purpose". The full suite passes. The final notarized DMG is in `builds/`. | 3 h |

M8 is the main speed milestone, but every milestone records speed numbers. A milestone that makes launch or typing more than 10 ms slower than the one before is fixed before its check closes.

## How each milestone runs

1. Root writes `docs/plans/M<n>.md` (nodes, owned files, verify commands) from Doc B and the parity rows.
2. The plan is reviewed. Then one builder through the runner (Sol on medium; Opus native if the runner exits 6 with capacity full) builds the milestone in its own clone from `prep-clone.sh`.
3. Root runs the checks:
   - unit tests (XCTest)
   - integration tests (document, encoding and file tests on real files)
   - the full XCUITest end-to-end suite
   - the parity script, which runs the same steps in TextEdit and QuickEdit through AppleScript and Accessibility and compares saved bytes and window state
   - bench numbers, n=5
   - screenshots, which root reads
4. Review: Astra (high) through the runner and a fresh native Opus reviewer, in parallel, with a 900-second deadline. Findings go to a builder one level up.
5. Root writes a change diagram (`diagram-design`) to `docs/diagrams/M<n>.html`.
6. Root notarizes, puts the zip in `builds/`, makes a GitHub release, rewrites `docs/STATE.md`, merges to main and pushes.
7. Root sends a push notification with the build path and a short hands-on script. Root does **not** wait for the user. Feedback that arrives later goes into the next milestone, or reopens the milestone it breaks.

Critical questions go to Astra and Fable, and the majority wins (see decision 4 above). Small choices: root picks the safe default and adds it to "choices to check".

## Not in this version

- Rich text, RTF, RTFD, HTML, Word and ODT, attachments, the font panel, the ruler and lists.
- Localizations other than English.
- Sparkle auto-update and the App Store.
- iCloud features beyond what NSDocument gives for free.
- A custom GPU text view (that is Fastpad's job).

## Verification (end to end)

- `./build.sh test` runs unit, integration and UI tests. A run with zero tests, a pass on retry, or a skipped test counts as a failure. Long runs use `agent-config/claude/bin/quiet-run`.
- `bench/parity.sh` compares the result of each `docs/parity.md` row in TextEdit and QuickEdit.
- `bench/run-bench.sh` gives launch, typing and open-time medians against TextEdit.
- The screen must be unlocked (`ioreg -n Root -d1 | grep IOConsoleLocked`). If it is locked, root logs the blocked UI and speed checks in `docs/AWAY_LOG.md` and keeps building the parts that do not need the screen. It never reports those checks as passed.
- The notarized build launches on a clean user account with Gatekeeper on (`spctl -a -vv`).

## Risks

- XCUITest and timing need an unlocked console. This is the same blocker Fastpad hit.
- TextKit 2 has known slow paths on very large single-line files. M8 may need a fallback to TextKit 1 for files over a size limit. Astra and Fable vote on that choice.
- The parity script drives the real TextEdit, which may change its saved state. It uses scratch files only and never reads TextEdit's preferences domain.
