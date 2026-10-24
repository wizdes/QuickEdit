# M1 plan review (Astra, 2026-10-23)

9 findings. Root's decisions:
1. Save boundary and undo coalescing: accepted; added breakUndoCoalescing and a type-save-type-quit-reopen UI test.
2. File safety through the real save path: accepted; document-level round trips for CRLF, BOM, mixed, emoji; invalid UTF-8; read-only folder failure.
3. Autosave blocking typing: accepted; asynchronous writing with a main-thread snapshot. The large-file responsiveness timing moves to root's M1 speed checks.
4. Save panel ".txt" checkbox: accepted; built and tested in M1.
5. Cmd+O and Finder opening: accepted; Info.plist document types, Open panel UI test, one `open -a` check.
6. Engine check: accepted; runtime test checks `textLayoutManager == nil` first.
7. Launch behavior: accepted; QuickEdit always opens an untitled window. Root confirms what system TextEdit shows at launch before comparing numbers.
8. One command: accepted; `./build.sh dist` runs the tests first and refuses to package on failure.
9. Typing and opening baselines: accepted as root work, not builder work.
Uncertain items: P5 wording narrowed in M2 after checking TextEdit; the launch metric mismatch is root's to resolve; reload with an attached layout manager goes to M2 (revert).
These were sent to the builder during its run, because the build started alongside the review.
