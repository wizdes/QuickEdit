# Stage 0 research, 2026-10-23

## Bottom line
- Plain NSTextView can beat TextEdit at launch and typing if QuickEdit does almost nothing before the first window, and nothing proportional to the whole document while typing.
- 100 MB files are borderline for any NSTextView. 1 GB files will not fit as editable text on this 8 GiB Mac (about 2 GB of UTF-16 before layout). They need a separate limited mode.
- TextKit 2 is fast near the visible area but has known bugs on long documents and long lines. TextKit 1 with non-contiguous layout is the proven fallback (CotEditor uses it).

## Sources
| What | File | Notes |
| --- | --- | --- |
| Code map of both old copies | `docs/codemap.md` | Every class, menu item, default, open and save path, deprecated API, top 10 risks. |
| Mac speed research (Astra) | `docs/research/speed-astra-2026-10-23.md` | 15 ranked changes, 22 dated sources. |
| X posts, Sept 2025 to Oct 2026 | `docs/research/x-posts-2026-10-23.md` | 36 posts. TextKit 2 complaints from STTextView's author; dyld and AppKit floor of about 150 ms. |
| YouTube search | none kept | Only WWDC21 "Meet TextKit 2" and a 2022 talk; both already covered by Astra's sources. |
| Reddit | none | Antigravity needs a new login; see `docs/AWAY_LOG.md`. |

## Measured on this Mac (Mac14,3, 8 GiB, macOS 27.0.1)
- System TextEdit launch to visible window: median 265.2 ms, min 216.6, max 270.3, n=7 (`bench/baseline/textedit-launch.csv`).
- `xcrun xctrace list instruments` prints "No instruments found", so Instruments recording does not work from the shell yet. Speed proof uses our own timing harness plus `os_signpost`.

## Speed rules for builders (from Astra's top 15)
1. No whole-document layout, scan or copy while opening or typing.
2. Each edit touches only the changed range.
3. Read and decode files off the main thread; install the text in one batch.
4. Build only the first window at launch; create panels, the Settings window and encodings lists on first use.
5. Release builds: `-O`, whole module, dead code stripping. Test `-Osize` and LTO separately.
6. Never touch `textView.layoutManager` on a TextKit 2 view (it silently switches to TextKit 1).
7. No timers or display links at idle.

## Old code facts that change the plan
- Apple copy is TextEdit 1.9 (version 309); zadr is 1.8 (version 301). Neither uses ARC. Apple copy is the base.
- TextEdit has no encoding or line-ending code of its own; AppKit decides. QuickEdit decodes itself so it can be tested.
- Wrap to Page needs many text containers on one layout manager, which only TextKit 1 supports. Text engine choice goes to a vote (`docs/decisions.md`).
- The old nibs are the IB 3 format and cannot be reused; menus and windows are built in code.
