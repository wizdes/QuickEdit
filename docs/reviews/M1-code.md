# M1 code review (Astra and Opus, 2026-10-23)

Both reviews ran in parallel on commit c385638. Root's decisions:

| # | Finding | From | Decision |
| --- | --- | --- | --- |
| 1 | Revert to shorter text leaves the selection past the end; next keystroke throws NSRangeException (proven by a probe) | Opus | Accept. Fix test-first: clear the storage while layout managers are attached (TextEdit Document.m:189), then fill. Unit test reverts with a window and types. |
| 2 | Save snapshot is one shared slot taken before NSDocument's file-access wait; overlapping saves can mismatch; costs a main-thread copy per autosave | Both | Accept. Remove the snapshot; copy the storage inside `write` while AppKit blocks input, then `unblockUserInteraction()` (TextEdit Document.m:1143). Test: two saves back to back plus an edit in between; bytes and edited state right. |
| 3 | Unchecking ".txt" replaces the typed name with the display name; `allowsOtherFileTypes` differs from TextEdit | Both | Accept. Only change allowed types, as TextEdit does; UI test types the name before toggling. |
| 4 | Async-save test passes with `unblockUserInteraction` removed | Both | Accept. Add a test that proves interaction is unblocked during the write (an edit lands before the write finishes and stays unsaved). |
| 5 | Cmd+N UI test passes when New does nothing | Astra | Accept. Assert the window count goes up and work in the new window. |
| 6 | No unit test that a real text-view edit marks the doc edited, or that save breaks undo grouping | Opus | Accept. Unit tests with window controllers and `insertText`. |
| 7 | No unit test opens a valid file through `NSDocumentController.openDocument` (the background read path) | Opus | Accept. |
| 8 | Window height (30 lines) and AutosavingDelay wiring unchecked | Both | Accept. |
| 9 | launchbench can terminate a pre-existing TextEdit session | Astra | Accept. Refuse to start when a target is already running (print which); only quit what it launched. |
| 10 | launchbench and run-bench can exit 0 with missing samples, ready stamps or CSV | Astra | Accept. Fail on any of those. |
| 11 | `dist --skip-tests` prints its warning only at the start; ioreg pipeline under pipefail can misread the lock | Opus | Accept both. |
| 12 | `QEOpenPath` read from user defaults ships in Release | Opus | Accept. Read it from launch arguments only. |
| 13 | A `.md` file opens with a more specific type than the writable `public.plain-text` | Opus (uncertain) | Accept: normalize the document type to `public.plain-text` on read, as TextEdit narrows types (Document.m:167). Test with a .md file save. |
| 14 | Windows may not cascade | Opus (uncertain) | Checked in M2 UI tests. |
| 15 | Text measuring off the main thread during concurrent read | Opus (uncertain) | Rejected for now: NSFont and string measuring are thread-safe for reads on current macOS; revisit if a crash shows up. |
| 16 | Return types LF in a CRLF file | Opus (uncertain) | Already planned as parity row P27 in M3. |

The fixes go to the M2 builder as phase A, test-first, because M2 touches the same files. The M2 review re-checks these fixes.
