# M4 code review (Astra and Opus, 2026-10-23, commit 41263c1)

| # | Finding | From | Decision |
| --- | --- | --- | --- |
| 1 | `--9223372036854775808` (or any huge backward entry) overflows `from - 1` and crashes (proven by both) | Both | Accept. Clamp before subtracting; test with Int.min forms. |
| 2 | Edit action tests mostly check `responds(to:)`, set explicit targets, skip Cut/Copy/Paste/Jump/Undo/Redo results | Astra | Accept. Send actions through `NSApp.sendAction(_:to:nil from:)` with the window key, and assert results (pasteboard contents, text, selection, undo state). Panels and speech: assert the panel or synthesizer state, not just routing. |
| 3 | CRLF-across-chunk test passes with the `skipFirst` handling removed (proven) | Opus | Accept. Add entries that keep scanning past the split ("1-2", "3"), a lone CR at the chunk end, CR as the last character. Show the broken copy fails. |
| 4 | Backward entries use `lineRange` per line: 424 ms for -999999 on 100 MB; huge backward numbers walk the whole text | Opus | Accept. Use a reverse UTF-16 scan with the same rules; stop early when the count exceeds the lines available. Target: under 200 ms optimized. |
| 5 | No test checks which window Select Line acts on | Opus | Accept. Unit test with two windows: the main one changes, the other does not. |
| 6 | The 200 ms limit is only checked in the builder's optimized run | Opus | Accept after M3 merges (`build.sh` is M3's): add `./build.sh speed` that runs speed tests optimized. |
| 7 | Panel first opens at (0,0) | Opus | Accept. Center it on first show when no saved frame exists. |
| 8 | Select Line can act on the find bar's field editor | Opus (uncertain) | Accept: skip field editors and use the window's document text view. |
| 9 | Locale digits accepted; restoration for unknown ids passes no error | Opus (uncertain) | Reject the first (matches NSScanner); accept the second (pass an error). |
