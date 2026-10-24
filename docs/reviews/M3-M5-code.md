# M3 + M5 code review (Astra and Opus, 2026-10-24, commit 7db64dd)

| # | Finding | From | Decision |
| --- | --- | --- | --- |
| 1 | xattr, explicit and fallback decodes never check that the text encodes back to the same bytes; cp932 658 pairs, Shift JIS 46, EUC-KR 94, EUC-JP 5,253, Mac Chinese Simplified 4,965, Big5 7, GB 18030 2 change on save (proven); ISO-2022-JP cannot save at all | Both | Accept. After every non-UTF decode, encode once and compare; if bytes differ (or encoding fails) mark the document lossy so the overwrite alert guards it. Fixtures: real byte sequences that do not round-trip (e.g. cp932 `FA 40`, EUC-JP `8E xx`). |
| 2 | "Automatic" chosen in the Open panel is stored as nil, so revert and outside-change reload fall back to the `PlainTextEncoding` default (café becomes cafÃ©) | Both | Accept. Store an explicit "automatic" choice distinct from "no choice". Tests for revert and reload with a non-Automatic default. |
| 3 | Save As onto the original URL skips the lossy-overwrite alert | Astra | Accept. Guard every operation that writes over the file the document was loaded from. |
| 4 | Reload compares Swift `String` (canonical equivalence), so é vs e+combining accent changes are ignored | Astra | Accept. Compare UTF-16 code units. |
| 5 | No Page Setup menu item; test sets printInfo directly | Astra | Accept. File > Page Setup… (Shift+Cmd+P, `runPageLayout:`) now; Print… stays for M7. UI test through the menu. |
| 6 | Customize Encodings adds new items enabled without the fit check | Astra | Accept. Recompute the disabled set after a list change. |
| 7 | `./build.sh speed` missing (M4 row 6) | Both | Accept. `speed` runs the speed tests in an optimized build with their real limits (Select Line 200 ms both ways, Wrap to Page switch 300 ms). |
| 8 | No test of a successful reload of a legacy-encoded file | Astra | Accept. |
| 9 | Cancelled Save panel can set the next Cmd+S encoding; autosave during the panel clears the panel choice | Opus (assumed) | Accept. Capture the panel's encoding only in the panel's completion when it returns OK, tied to that save operation; never read panel state later. Tests with a shown-and-cancelled panel (UI) and a unit test of the state machine. |
| 10 | Failing to write the xattr fails the whole save; replaceItemAt drops the old xattr when the encoding has no IANA name | Opus | Accept. xattr is best effort: log, do not fail. Write a CFStringEncoding-only value when there is no IANA name (AppKit's format allows it; check). |
| 11 | Lossy alert unreachable on an English Mac (Mac Roman decodes everything) | Opus | Accept as a fact; row 1 makes it reachable for multi-byte encodings. No other change. |
| 12 | Option-Return, `insertLineBreak:` and `insertParagraphSeparator:` still type LF | Opus | Accept for `insertNewlineIgnoringFieldEditor:` and `insertParagraphSeparator:`. `insertLineBreak:` stays U+2028 (TextEdit's Insert > Line Break is dropped from the menu anyway). |
| 13 | Added pages skip typing-attributes setup | Opus | Accept (TextEdit's addPage does it). |
| 14 | Multi-range edits may skip the encoding check | Opus (uncertain) | Accept: implement the multi-range delegate method and test Replace All with an unencodable replacement. |
| 15 | Input method composition and the encoding check | Opus (uncertain) | Accept: skip the check while the text view has marked text; check when composition commits. |
| 16 | Page mode memory at thousands of pages; 340 ms freeze | Opus (uncertain) | M8. |
| 17 | `cacheDisplay` PNGs may not show page drawing | Astra (uncertain) | Root read the M5 PNGs: page frames and gaps are visible at 50%. No change. |
