# M2 code review (Astra and Opus, 2026-10-23, commit 88ac407)

| # | Finding | From | Decision |
| --- | --- | --- | --- |
| 1 | Typing into the transient untitled window while a file loads is lost: `replace` closes it without rechecking edits or sheets | Both | Accept. Recheck `isDocumentEdited`, attached sheets and whether it was saved at replace time; if any, open the file in its own window. Unit test edits during a slow open. |
| 2 | launchbench can reuse and later terminate an app the user opened between rounds | Astra | Accept. Before each launch, if the target is already running and was not launched by the harness, stop the bench with an error; terminate only PIDs the harness launched. Test in bench/tests. |
| 3 | Outside-change reload uses timestamps: a date-only change reloads (caret jumps, undo lost); an older-dated replacement does not reload; a non-UTF-8 reload alerts on every later change | Both | Accept. Read and decode the bytes; reload only when the text differs; keep the selection (clamped) and scroll place; on decode failure show the error once and record the new date. Tests: touch only, older date, appended log, non-UTF-8. |
| 4 | Restored scroll puts the saved first line near the bottom (`scrollRangeToVisible`), proven by a probe | Opus | Accept. Scroll so the saved character's line is at the top. Unit test asserts the first visible character equals the saved one. |
| 5 | Restoration tests pass with restoration broken (find clipboard survives relaunch; weak unit asserts) | Both | Accept. Assert the selected range through accessibility (XCUIElement value of selected text) after clearing the find pasteboard; tighten the unit asserts. |
| 6 | No UI Revert test; Duplicate/Rename/Move order wrong; external-change wait 10 s | Astra | Accept the first two. The 3 s wait in the plan was too tight: macOS delivers the notice about 3.15 s after an outside write (builder measurement), so the plan now says 5 s. |
| 7 | Shell regression tests not in `./build.sh test` / `unit` | Astra | Accept. `./build.sh unit` and `test` also run `bench/tests/*.sh`. |
| 8 | Parity rows P10-P17 still todo | Both | Accept; root updates them. |
| 9 | Transient UI test does not move the window before checking the frame | Opus | Accept. Move it first. |
| 10 | `.json`, `.html`, no-extension files cannot be opened (only public.plain-text declared) | Opus (uncertain) | Accept into M3: declare `public.text` as Editor and `public.data` as Viewer-to-Editor like TextEdit's "Unknown document"; open as plain text. |
| 11 | Reload not inside NSDocument file-access serialization | Opus (uncertain) | Accept cheaply: perform the reload inside `performSynchronousFileAccess`. |
| 12 | Debug hooks in Release | Opus (uncertain) | Checked by root: `strings` on the Release binary finds no `QETest` hooks; `-QEOpenPath` stays as a launch argument by design. |
