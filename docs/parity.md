# Parity with TextEdit (plain text)

Each row is one behavior QuickEdit must match or deliberately change. Status is one of: todo, same, better, left out (with why). "Ref" points at `docs/codemap.md` or the old source. The M10 sweep checks every row against the system TextEdit on macOS 27.

## M1: open, edit, save
| ID | Behavior | Ref | Status |
| --- | --- | --- | --- |
| P1 | File > New opens an empty plain-text window (Cmd+N). | menu File | todo |
| P2 | File > Open (Cmd+O) opens .txt and any `public.plain-text` file. | codemap 4.1 | todo |
| P3 | Typing, Save (Cmd+S) writes UTF-8; bytes on disk equal the text. | codemap 4.5 | todo |
| P4 | Untitled docs save via a Save panel with "If no extension is provided, use .txt" (default on). | codemap 4.4 | todo |
| P5 | Close (Cmd+W) on a dirty doc asks to save; Quit (Cmd+Q) keeps autosaved docs. | NSDocument | todo |
| P6 | New windows are 90 characters x 30 lines of the plain font. | defaults WidthInChars/HeightInChars | todo |
| P7 | Plain font is the user fixed-pitch font; tab stops every 8 spaces. | Document.m:331 | todo |
| P8 | Undo and Redo (Cmd+Z, Shift+Cmd+Z); Cut, Copy, Paste, Delete, Select All. | menu Edit | todo |

## M2: document life
| ID | Behavior | Ref | Status |
| --- | --- | --- | --- |
| P10 | Autosave in place; edits survive a quit with no prompt. | Document.m:831 | same (unit tested; UI test not run yet) |
| P11 | File > Duplicate (Shift+Cmd+S), Rename…, Move To…, Revert To > Last Saved / Browse All Versions. | codemap menu File | same; Save As is the Option alternate of Duplicate (UI test not run yet) |
| P12 | Save All. | menu File | same (kept, as in TextEdit 1.9) |
| P13 | Open Recent and Clear Menu. | menu File | same (unit test proves AppKit fills it) |
| P14 | Locked file: edits prompt "Unlock" or "Duplicate". | NSDocument | same, from NSDocument (UI test not run yet) |
| P15 | File changed by another app: reloads when clean, warns when dirty. | NSDocument | same; QuickEdit reloads after about 3 s (macOS notice delay); M3 makes it compare content, not dates |
| P16 | Windows, selection and scroll position restored after relaunch. | DocumentWindowController.m:619-637 | better: also restores the selection and first visible line (TextEdit 1.9 restores only the scroller style); fix for exact scroll place in M3 |
| P17 | Opening a file from an empty untitled window replaces that window (transient document). | DocumentController.m:153-266 | same (unit tested; UI test not run yet) |
| P18 | Export as PDF… | Edit.nib:315 | todo (built in M7) |

## M3: encodings and line endings
| ID | Behavior | Ref | Status |
| --- | --- | --- | --- |
| P20 | Open panel shows "Plain Text Encoding" with Automatic first; start value from settings. | codemap 4.1 | todo |
| P21 | Automatic order: `com.apple.TextEncoding` xattr, BOM, UTF-8, then fallback guess. Confirm each step against system TextEdit. | codemap 4.2 | todo |
| P22 | A chosen encoding that does not fit shows "could not be opened". | codemap 4.2 | todo |
| P23 | Save panel encoding popup; encodings that cannot hold the text are disabled. | codemap 4.4 | todo |
| P24 | Save writes the `com.apple.TextEncoding` xattr. | codemap 4.5 | todo |
| P25 | Editing into a character the encoding cannot hold shows "can no longer be saved using its original … encoding"; OK opens Save panel, Cancel undoes. | codemap 4.6 | todo |
| P26 | Lossy-loaded file warns before overwrite (Duplicate / Cancel / Overwrite). | codemap 4.6 | todo |
| P27 | CR, LF and CRLF kept as found. | codemap 4.3 | better: Return types the file's own line ending (TextEdit types LF) |
| P28 | UTF-8 BOM kept on save. | codemap 4.5 | better: TextEdit drops it |
| P29 | Customize Encodings List… panel. | EncodingManager.m:271 | todo |

## M4: find and editing tools
| ID | Behavior | Ref | Status |
| --- | --- | --- | --- |
| P30 | Find bar (Cmd+F), Find and Replace (Opt+Cmd+F), Find Next/Previous (Cmd+G / Shift+Cmd+G), Use Selection for Find (Cmd+E), Jump to Selection (Cmd+J). | menu Edit > Find | same (unit tested; 6 UI tests not run yet) |
| P31 | Select Line… (Cmd+L) panel: a line number or range. | LinePanelController | same; TextEdit's N, N-M, +N, -N forms; line 1,000,000 of 100 MB in 93.8 ms (optimized). Beeps on bad input (TextEdit does not) |
| P32 | Spelling and Grammar submenu, check while typing (default on), grammar (off), autocorrect (system). | menu Edit | same (unit tested) |
| P33 | Substitutions: Smart Copy/Paste (on), Smart Quotes (off), Smart Dashes (off), Text Replacement (system), Data Detectors (test). | menu Edit | same; Data Detectors kept after a test showed it marks text on TextKit 1 without changing saved bytes |
| P34 | Transformations: Upper, Lower, Capitalize. | menu Edit | same (unit tested, undo works) |
| P35 | Speech: Start and Stop Speaking. | menu Edit | same (wired; speech not audible-tested) |
| P36 | Complete (Opt+Esc). | menu Edit | same (unit tested) |
| P37 | Prevent Editing toggle. | menu Format | same (unit tested) |

## M5: layout and view
| ID | Behavior | Ref | Status |
| --- | --- | --- | --- |
| P40 | Wrap to Page / Wrap to Window (Shift+Cmd+W), menu title flips. | codemap 5 | todo |
| P41 | Wrap to Page draws white pages with gray frames and gaps; pages follow Page Setup. | codemap 5.3 | todo |
| P42 | Zoom: Actual Size (Cmd+0), Zoom In (Cmd+>), Zoom Out (Cmd+<), steps 25%-1600%, pinch. | codemap 5.4 | todo |
| P43 | Full screen, window tabs, dark mode. | system | todo |
| P44 | Window keeps text width when the scroller style changes. | DocumentWindowController.m:619 | todo |

## M6: settings
| ID | Behavior | Ref | Status |
| --- | --- | --- | --- |
| P50 | Settings window (Cmd+,): New Document tab (size, font, wrap to page, spelling and substitution defaults). | codemap 3 | todo |
| P51 | Open and Save tab: encodings for open and save, add .txt, autosave delay. | codemap 3 | todo |
| P52 | Settings survive relaunch and apply to the next new window only. | codemap 3 note | todo |

## M7: printing and PDF
| ID | Behavior | Ref | Status |
| --- | --- | --- | --- |
| P60 | Print (Cmd+P) with "Print header and footer" (off) and "Rewrap contents to fit page" (on, wrap-to-window only). | codemap 5.5 | todo |
| P61 | Page Setup (Shift+Cmd+P). | menu File | todo |
| P62 | Export as PDF matches Print output. | codemap 6 | todo |

## M9: system parts
| ID | Behavior | Ref | Status |
| --- | --- | --- | --- |
| P70 | AppleScript: open, get/set text, save, close. | TextEdit.scriptSuite | todo |
| P71 | Services menu works with the selection. | Controller.m:128 | todo |
| P72 | Drag a file onto the Dock icon or window opens it. | system | todo |
| P73 | Share menu, Writing Tools, VoiceOver reads the text. | system | todo |

## Left out on purpose
Rich text and everything in the Format > Font and Format > Text menus; Make Rich Text; Show Properties; Attach Files; Link; Insert submenu; Smart Links; Hyphenation; Vertical Layout; Lists; Tables; RTF, RTFD, HTML, Word and ODT. Reason: user decision 1 (plain text only).
