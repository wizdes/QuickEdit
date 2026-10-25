# M8 code review

Two reviewers read the uncommitted M8 work on 2026-10-25: Astra (high, through the runner, 5.5 min) and a fresh Opus reviewer (4 min). Root checked each finding against the code.

| # | Finding | From | Root check | Decision |
|---|---|---|---|---|
| 1 | Wrap to Page idle layout restarts itself forever when layout makes no progress: the `break` at DocumentWindowController.swift:395 leaves only the inner loop, then line 399 schedules again | Opus; Astra (uncertain) | Read the code: confirmed | Accept: stop on no progress; test that the timer is nil when layout is done and in the no-progress case |
| 2 | Large-file mode does not follow new content: reload from an outside change never updates `readByteCount`; revert updates it but nothing re-applies the checks or the title | Opus, Astra | Read the code: confirmed | Accept: re-apply checks and title after reload and revert, both ways; restore the window's own settings when the file gets small |
| 3 | Each key press in Wrap to Page restarts idle work from the edit point; typing delay in Wrap to Page is not measured | Opus | Code path confirmed; cost not measured | Accept: add a Wrap to Page typing p95 test on 100 MB; fix only if it misses the n7 limit |
| 4 | No test closes the document during the attribute read at the start of a background export | Opus | Code handles it (checks `isCancelled`) | Accept: add the test |
| 5 | PDF layout managers used off the main thread keep `backgroundLayoutEnabled` on (Apple says turn it off for this use) | Astra | PDFRenderer.swift:107 has no such line: confirmed | Accept |
| 6 | Cancel or close after the last drawing check can still replace an old PDF and report success | Astra | TextDocument.swift:927-945 has no cancel check before the replace: confirmed | Accept: check cancel right before the replace; test with the `pdfTemporaryFile` hook |
| 7 | `./build.sh speed` leaves out the two 10 MB PDF freeze tests and the 100 MB line-ending test; the n6 2x memory limit is printed, never asserted | Astra | build.sh:305 list confirmed | Accept |
| 8 | The Wrap to Page stall test starts measuring after the first draw, and misses the last interval | Astra | Confirmed; the test is new in M8 (not committed), so changing it needs no OK | Accept |
| 9 | No window-close handler stops the idle timer; edits in Wrap to Window do not lower `idleGlyphsDone` | Astra (uncertain) | Plausible | Accept: stop the timer on close; reset idle state on mode switch; tests |
| 10 | Quit during a background export may leave the temp folder | Opus (uncertain) | Not shown | Follow-up |
| 11 | A paragraph over 1M characters stays one PDF piece; memory and cancel time unproven for it | Astra (uncertain) | Not measured | Follow-up |
| 12 | Mapped read during an outside truncation: no subprocess test | both (uncertain) | Opus's probe saw no crash | Follow-up |
| 13 | Large-file mode leaves smart insert and delete on | Opus (follow-up) | It does not change typed text | Reject |

## Very large files (V3 change), second review

Astra (high, runner) and a fresh Opus reviewer read the read-only change on 2026-10-25. Root checked each finding against the code.

| # | Finding | From | Root check | Decision |
|---|---|---|---|---|
| 14 | `originalBytes` keeps the file mapped for the document's life. Another app overwriting or truncating the file moves old pages into QuickEdit's memory (Opus measured 256 MB file: 258 to 578 MB); after Save As the mapping still points at the old file | Astra, Opus | TextDocument.swift:246-249, 386-389: confirmed | Accept: do not keep the mapping. Keep a stable copy that costs no memory (an APFS clone taken at open, copied on Save As and Save To); release the mapping once the storage is filled. If the volume cannot clone, say so and name the limit |
| 15 | A failed read sets `readByteCount` and `originalBytes` before decoding succeeds, so Save As could write the rejected file's bytes; the `defer` also updates read-only controls | Astra | TextDocument.swift:246-256: confirmed | Accept: change state only after a successful decode |
| 16 | `read(from: Data, ...)` never sets the limit or the original bytes | Astra | TextDocument.swift:261: confirmed | Accept |
| 17 | A lossy file saved with Save As gets the original bad bytes plus a UTF-8 encoding tag, so the copy cannot be opened | Opus | writeOriginal + writeEncodingAttribute: confirmed by reading | Accept: no encoding tag (or the right one) for lossy bytes; test reopens the copy |
| 18 | `testSaveAsWritesTheOriginalBytes` passes even without `writeOriginal` (all inputs round-trip through re-encoding) | Opus | Plausible from the inputs | Accept: add a lossy input that only the original-bytes path keeps |
| 19 | Reload after an outside change still makes a full String copy and compares the whole text on the main thread; a growing log reloads on every change | Opus | TextDocument.swift:356-410: confirmed | Accept: reload of a large file uses the same in-place check and piece fill, off the main thread, within the done-test-4 limits |
| 20 | Edit routes not tested on a read-only file: the `paste:` action, Return in a CRLF file, a real Replace All, Services, drag and drop, undo, Duplicate then Save | Astra, Opus | Confirmed missing | Accept: add the tests; fix any route that edits |
| 21 | An outside change that crosses the limit keeps the undo history | Astra (uncertain) | Plausible | Accept: clear undo when a document becomes read-only; test |
| 22 | The scroll-view order change has no unit test for zoom or Wrap to Page right after open | Opus | Confirmed | Accept |
| 23 | The memory sampler in the large-file tests reads and writes `peak` from two threads with no lock | Astra | Confirmed | Accept |
| 24 | `testRevertToASmallFileMakesItEditable` mentions Prevent Editing but never checks it | Opus | Confirmed | Accept |
| 25 | Save panel setup copies the whole text for `disableUnfitItems` | Astra (uncertain) | Not measured | Accept: measure at 1 GB; skip the copy when the pop-up is off |
| 26 | Network or removable disks may not map; the Revert To submenu's private items; Save As with an encoding missing from the list; bytes changed between the check pass and the fill pass | both (uncertain) | Not shown | Follow-ups |

## Very large files, third review (after rows 14-25)

Astra (runner) and a fresh Opus reviewer re-read the change on 2026-10-25. The fixes for rows 14-25 were written before their tests, so the reviewers also checked whether each test can fail. Root checked each finding against the code. Root chose to simplify the design (rows 27-30) rather than patch each hole.

| # | Finding | From | Root check | Decision |
|---|---|---|---|---|
| 27 | Close, Quit, Duplicate or a synchronous file access during a large reload hangs the app for good: the NSDocument file access stays open across background work whose end needs a main-thread hop | Opus (proven with a probe); Astra (uncertain) | TextDocument.swift:373, 483, 527: confirmed | Accept: hold the file access only while cloning the file (about 0.2 ms), then end it; decode and fill afterwards. Test: close and duplicate while a reload is held in the fill |
| 28 | The clone (or the no-clone identity) is taken after the fill, so the window can show B while the clone holds C; a later reload then says "unchanged" | Opus, Astra | TextDocument.swift:259-271, 526: confirmed | Accept: clone first, then map and decode the clone, on open and reload |
| 29 | Without a clone, Save As checks the file once, then copies for seconds; same-size changes and FAT or SMB times can pass as unchanged; the limit is only on stderr | Opus, Astra | LargeFileOriginal.swift:87, 116-136: confirmed | Accept, simplified: on a volume that cannot clone, Save As and Save To are off for a read-only file, and the title note says so at open |
| 30 | PDF export and print read the text storage while a background fill writes it | Opus, Astra | TextDocument.swift:960, 1278, 1455: confirmed | Accept: no export, print or Duplicate while a reload runs (menus off, guards); a reload waits until a running export ends |
| 31 | A document closed during a reload keeps working: new clone, new reload | Opus, Astra (uncertain) | Confirmed by reading | Accept: cancel the reload on close; remove its clone |
| 32 | Equal bytes hide an encoding-tag-only change | Astra | TextDocument.swift:478: confirmed | Accept: compare the encoding tag too |
| 33 | A date-only change clears undo for an editable large file (no clone below the limit) | Astra | Confirmed | Accept: clone every file over 50 MB (APFS clones cost no space) so unchanged bytes keep the text and undo |
| 34 | After a reload, Wrap to Page idle layout is not restarted | Astra | DocumentWindowController.swift:430, 808: confirmed | Accept: reset and restart idle layout after reattach; test |
| 35 | Row 21 test passes without its fix (revert and reload already clear undo) | Opus | NSDocument.h:226 and :532: confirmed | Accept: test a route that only the fix covers, or drop the redundant fix and say so |
| 36 | Row 19 "change during a reload" test can pass without the reload-again logic | Opus, Astra | Confirmed | Accept: hold the first reload with `beforeReloadFill` |
| 37 | Row 20 tests do not run the real actions: Replace All, `duplicate()`, paste with a filled pasteboard, a drop | Opus, Astra | Confirmed | Accept |
| 38 | Stale clone cleanup trusts the pid alone; a reused pid keeps a dead folder | Astra, Opus (uncertain) | Confirmed | Accept: record the process start time with the pid |
| 39 | Temp-folder cleanup by macOS while a window is open for days; undo during a fill in an editable large file; Save As to a new place during the background check | both (uncertain) | Not shown | Follow-ups; the third is covered if rows 27 and 30 hold |

## Very large files, final narrow review (after rows 27-38)

Scope: only byte loss, hangs, crashes or stuck documents. Astra found none in scope. Opus found one.

| # | Finding | From | Root check | Decision |
|---|---|---|---|---|
| 40 | Edits typed while a reload checks the file can be lost: the document is "reloading" from the start, autosave returns success without writing, but views stop taking keys only when the fill starts; Close then closes without saving | Opus | TextDocument.swift:447, 551-598, 717-719, 776-779: confirmed by reading | Accept: views stop taking edits when the reload starts; test with a hook that holds the check part |
| 41 | The clone taken after a save runs without file access; another app's write in that gap is taken as "unchanged" and later overwritten without a warning | Opus (uncertain) | TextDocument.swift:766-772: plausible | Accept: take that clone inside the save's file access; test with a hook in the gap |
| 42 | No test keeps the PDF Save panel open during a reload, or checks that cancelling the panel lets the reload go on | Astra | Confirmed missing | Accept |
| 43 | Done-test 4 needs n=5 in a signed Release build | Astra | Correct | Root measures |
| 44 | Byte count is kept after Save As in another encoding; no-clone reload reads after file access ends; lossy flag cleared by overwrite confirmation | Opus, Astra | Not in scope | Follow-ups |
