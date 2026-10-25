# M9 code review

## n2 and n3 (system parts, custom shortcuts), diff a424b21..4978f45

Two reviewers read it on 2026-10-25: Astra (high, through the runner, 3.5 min) and a fresh Opus reviewer (6 min). Root checked each finding against the code.

| # | Finding | From | Root check | Decision |
|---|---|---|---|---|
| 1 | Reset of one row (button or Delete) calls `Shortcuts.set(nil)` with no clash check: move New off Cmd+N, give Cmd+N to Save or Print, reset New, and two commands share Cmd+N | Astra, Opus | SettingsWindowController.swift:957 and the Delete path: confirmed | Accept: refuse the reset with the clash message when the default key is taken; test |
| 2 | `./build.sh quick` asks `ui_tests_possible` twice: locked at start, unlocked at the end passes with unit tests only. A listed UI test or class that does not exist runs nothing and is not noticed | Astra (reproduced), Opus | build.sh quick section (root's code): confirmed | Accept: keep the first answer; fail when any listed UI test or class ran zero tests |
| 3 | The accessibility audit skips contrast and element-less "Parent/Child mismatch"; done-test 1 says no errors | Astra, Opus | AccessibilityAuditTests.swift:21-23: confirmed | User decision U8: keep the skips; add a contrast unit test over every audited window |
| 4 | The Keyboard tab's Tab loop never reaches the window's "Restore All Defaults" button | Astra | linkKeyViews: confirmed (older tabs too) | Accept: every tab's loop includes the button |
| 5 | A new shortcut can take a text-editing key (Ctrl+A, Ctrl+E, Ctrl+K, Cmd+arrows, Cmd+Delete) with no warning, and the key stops editing | Opus | Shortcuts.swift:294 accepts any Ctrl or Cmd key: confirmed | Accept: refuse the standard text-editing keys with a message naming the editing action; test |
| 6 | `menuAnswers` in ShortcutTests builds an NSEvent and discards it, so the test checks the code against itself | Opus | ShortcutTests.swift:129-136: confirmed | Accept: send the event through `NSMenu.performKeyEquivalent` |
| 7 | The Share test does not prove Share is off while an untitled document is in front | Opus | Confirmed by reading | Accept: test with an untitled document in front |
| 8 | Some new tests pass without the change (Services, Quick Look, plain drags, Dock open event) | Opus | True; they prove the plan's checks, not new code | Reject: kept as proof that P71 to P73 work |
| 9 | `testRenderKeyboardTab` writes into build/shots, which the sandbox blocks; qlmanage and the drag-time type check may fail under the sandbox | Astra, Opus | Confirmed by reading | Sent to the n1 sandbox builder |
| 10 | The quick lint link finds the repo by folder depth; a different depth makes the lint check nothing and pass | Opus | raw-typing-lint-test.sh:19, 35: confirmed | Accept: the lint resolves its own real path |
| 11 | `draggingUpdated` reads every dragged file's type on each update | Opus | DocumentWindowController.swift:884: confirmed | Accept: work it out once in `draggingEntered` |
| 12 | Stale comment about "Open Recent > Clear Menu"; blank lines at end of three files (`git diff --check`) | Opus, Astra | Confirmed | Accept |
| 13 | Shortcuts set in System Settings > App Shortcuts are not seen by the clash check; US-only key table; more system keys (Ctrl+Cmd+Space, Shift+Cmd+3/4/5); Settings may restore at the Keyboard tab's height | Opus, Astra (uncertain) | Not shown | Follow-up (POST_MVP.md) |

## n1 (App Sandbox on), diff 1b9885a..b1db25e

Two reviewers read it on 2026-10-25: Astra (high, through the runner) and a fresh Opus reviewer (6 min). Root checked each finding against the code and the disk.

| # | Finding | From | Root check | Decision |
|---|---|---|---|---|
| 14 | sandbox-release-test.sh ignores failures of ditto, PlistBuddy, sed and cp; a failed bundle-ID rewrite could launch a copy as the real app and move the user's settings | Astra (shell mock) | Confirmed by reading | Accept: every step fails the script; verify the scratch ID and manifest before launch |
| 15 | build-sh-test.sh's xcodebuild mock fails on the new preliminary build when the Debug container is missing, so `./build.sh test` fails on a fresh Mac | Astra (simulated) | Confirmed by reading | Accept |
| 16 | The large-file UI test (52 MiB) never reaches the clone-copy Save As (only above 512 MiB) and checks only size and 64 bytes | Astra | TextDocument.originalForCopy: confirmed | Accept: Debug-only lower limit; compare all bytes |
| 17 | Outside-file paths untested: Save As changing the extension, autosave and Versions, Reopen with Encoding, PDF over an existing PDF, large-file Save As over an existing file | Astra, Opus | Confirmed: older UI tests now save inside the Debug container | Accept: UI tests in the full suite only |
| 18 | The reload test's fixed 40 s wait races the Open panel | Astra, Opus | Confirmed | Accept: write after the document opens |
| 19 | The first sandboxed run may have made the real container, so the settings move never runs | Opus (assumed) | `~/Library/Containers/dev.yili.QuickEdit` does not exist; the real settings file is untouched (Oct 24 16:35) | Reject: not the case |
| 20 | Untitled documents autosaved before M9 (in ~/Library/Autosave Information) and pre-M9 window state do not come back after the update | Opus | Manifest moves only the settings file: confirmed | Known limit, in the release notes: that folder is shared with other apps |
| 21 | A sandbox test writes a probe into the real ~/Library/Caches; UUID-named test settings files are never deleted (root found and deleted 3,837 of them in ~/Library/Preferences) | Opus | Confirmed | Accept |
| 22 | TestShots.folder falls back to a temp folder without saying so | Opus | Confirmed | Accept: print where shots go |
| 23 | build.sh writes a 56 MB fixture for every run, keeps old fixture folders, misses "big-copy" with no extension; release-test check 4 cannot fail | Opus | Confirmed | Accept |
| 24 | quick runs 2 of the 7 SandboxUITests | Astra | Root's choice for the 10-minute limit (U6) | Reject: the rest run in the full suite |
| 25 | The sandbox raised the Debug PDF export peak from +16-19 MB to +52 MB with no cause found | Opus | U10 moved the check to the speed run | The release speed run decides; investigate if it fails |
| 26 | Save panel extension fix depends on the out-of-process panel re-reading `allowsOtherFileTypes`; other-disk temp folders; first-run access prompts; drag and Share of outside files untested | Opus (uncertain) | Not shown | Covered by row 17 where testable; the rest follow-up |
