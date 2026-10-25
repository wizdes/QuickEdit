# M6 + encoding-change review (Astra and Opus, 2026-10-24, commit a7b9336)

| # | Finding | From | Decision |
| --- | --- | --- | --- |
| 1 | Settings controller is `@MainActor` and observes `UserDefaults.didChangeNotification` with a selector; a background-thread default write traps (proven by probe, exit 133) | Opus | Accept. Observe with a block on `queue: .main`. Test: post the notification from a background thread. |
| 2 | Malformed BOM files (odd-length UTF-16, half surrogates, bad UTF-32 body, UTF-16-with-NUL vs UTF-32 BOM, short UTF-32 tail) differ from AppKit; QuickEdit falls to Mac Roman (proven, 8 shapes) | Both | Accept. Root decision (refines V2): match AppKit's encoding and displayed text for each shape (repair with U+FFFD, drop the odd byte, refuse where AppKit refuses), and mark the document lossy whenever the bytes would not round-trip, so the overwrite alert guards the save. Fixtures for all 8 shapes. |
| 3 | A `us-ascii` xattr or explicit ASCII over high bytes: AppKit opens (text "café"), QuickEdit refuses; same for explicit UTF-16 odd length and half surrogates | Opus | Accept with the same rule as row 2: match AppKit, mark lossy. Fixtures. |
| 4 | UTF-16 or UTF-32 xattr with no BOM: QuickEdit names the BE variant, AppKit names plain UTF-16/32 | Opus | Accept. Fixtures. |
| 5 | Oracle compares only the encoding number, not the text | Both | Accept. Compare the decoded text with AppKit's string too. |
| 6 | "Saving files" encoding never reaches a new document's first Save panel | Astra | Accept. New untitled documents start with `PlainTextEncodingForWrite` when set and the text fits (TextEdit `suggestedDocumentEncoding`). Test through `prepareSavePanel`. |
| 7 | Encoding pop-up shows Automatic while a removed encoding stays the saved default | Both | Accept (better than TextEdit): when a saved default encoding leaves the list, keep showing it as a checked extra item at the top of the pop-up instead of Automatic. Test. |
| 8 | Wrap toggle and revert pick up the new font in an open window | Both | Reject as parity: TextEdit does the same (`DocumentWindowController.m:404-411`, `Document.m:330`). Plan wording narrowed; parity note added. |
| 9 | Weak tests: font manager target set directly; junk and empty size fields bypass the real editing path; no test that Restore keeps `Encodings`; shared controller not checked after menu build | Opus | Accept. Use the real responder path (`NSApp.sendAction(#selector(NSFontManager.modifyFontViaPanel(_:)))` or `NSFontManager.shared.sendAction()`), drive field editing with `window.makeFirstResponder` and `insertText` then end editing; add the Encodings test and a shared-controller test. |
| 10 | Empty size field stays blank and keeps the old value | Opus | Accept. Empty input restores the shown value. |
| 11 | `./build.sh uicheck` exits 0 after temp-file errors | Astra | Accept. Any error in the check makes it report NOT possible and exit non-zero. |
| 12 | Parity rows P20, P21, P50-P52 not updated; P21 and P51 wording stale | Both | Accept; root updates. |
| 13 | Tab order between fields; Font panel with a field focused | Opus (uncertain) | Accept: set `nextKeyView` chain and `initialFirstResponder`; route `changeFont:` to the controller even when a field editor is first responder. |
| 14 | Tests write the user's real settings | Opus (uncertain) | Accept: tests use a separate suite name through a `Defaults.store` seam. |
