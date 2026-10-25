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
