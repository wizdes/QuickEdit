# TextEdit code map for QuickEdit

This report maps Apple's old TextEdit sample so we can rebuild it as QuickEdit.
QuickEdit is plain text only, in Swift and AppKit, with NSDocument and a TextKit 2 NSTextView, for macOS 27.

All paths are relative to `reference/`.
`apple/` is the Apple archive copy. `zadr/` is the GitHub zadr/TextEdit copy.
Line numbers point at `apple/` unless the text says `zadr/`.

## 0. Summary first

- Two classes do almost all the work: `Document` (reads and writes the file) and `DocumentWindowController` (builds the text views).
- About two thirds of the code is for rich text. All of that is dropped.
- Plain text open and save lean on AppKit's `NSAttributedString` text reader and writer. TextEdit has no BOM code and no line-ending code of its own. AppKit does that work out of sight.
- "Wrap to Page" uses one shared `NSLayoutManager` with many text containers, one per page. TextKit 2 gives one text container per layout manager. This is the hardest part to port.
- Both copies are manual retain/release code (no ARC). Both already have Auto Save in place, Versions, window restoration and the sandbox comment. The task brief says zadr is "version 285 with ARC"; the files say otherwise (see section 6).
- All nibs are in the old Interface Builder 3 archive format (`designable.nib` inside `.nib` folders). We should rebuild the UI, not import it.

Terms used below:
- **TextKit 1**: the older text layout system built on `NSLayoutManager` and glyphs.
- **TextKit 2**: the newer system built on `NSTextLayoutManager` and `NSTextContentStorage`. An `NSTextView` falls back to TextKit 1 (called "compatibility mode") as soon as code asks for its `layoutManager`.
- **KVO**: key-value observing, where one object watches a property of another.
- **Transient document**: the empty "Untitled" window made at launch. If you open a real file before typing in it, the real file takes over its window.

Marks: **KEEP** = needed for plain text. **DROP** = rich text only, or not needed. **CHANGE** = needed, but needs a modern replacement.

---

## 1. Classes and files

### 1.1 `Edit_main.m`
- `main` (`Edit_main.m:52`) calls `NSApplicationMain`. CHANGE: use `@main` on an `NSApplicationDelegate` in Swift.

### 1.2 `Controller` (`Controller.h`, `Controller.m`)
What it does: the app delegate. It registers default values and serves the two Services menu items.
State: outlets to the three singleton panel controllers: `preferencesController`, `propertiesController`, `lineController` (`Controller.h:55-63`).
Talks to: `DocumentController`, `Document`, `NSUserDefaults`, `NSUserDefaultsController`.

| Method | Line | Mark | Why |
| --- | --- | --- | --- |
| `defaultValues()` | `Controller.m:60-103` | CHANGE | Registers all defaults. Keep the plain-text keys only (see section 3). |
| `+initialize` | `Controller.m:109-119` | CHANGE | Registers defaults and seeds `NSUserDefaultsController`. Lines 113-118 clean a 32-to-64-bit bug value; a new bundle ID never has it, so drop that part. |
| `applicationDidFinishLaunching:` | `Controller.m:121-124` | KEEP | Sets itself as the Services provider. |
| `openFile:userData:error:` | `Controller.m:128-155` | CHANGE | "Open Selected File in TextEdit" service. Takes a path string, trims it, expands `~`. Under the sandbox, opening a path the user did not pick will fail (see risk 8). Uses `kUTTypePlainText` (line 132). |
| `openSelection:userData:error:` | `Controller.m:158-166` | CHANGE | "New Window Containing Selection" service and drop-on-Dock-icon. Keep, but read plain text from the pasteboard only. |

### 1.3 `DocumentController` (`DocumentController.h`, `DocumentController.m`)
What it does: subclass of `NSDocumentController`. It adds the encoding accessory to the Open panel, remembers the user's open choices per URL, and does the transient-document swap.
State (`DocumentController.h:57-62`):
- `customOpenSettings`: URL -> {encoding, ignoreHTML, ignoreRich} chosen in the Open panel.
- `deferredDocuments`: documents waiting to show until the transient window is replaced.
- `transientDocumentLock`, `displayDocumentLock`: `NSLock`s, because documents can open on several threads at once.
Talks to: `Document`, `EncodingManager`, `OpenSaveAccessoryOwner` (a tiny outlet holder, `DocumentController.m:59-68`), `NSUserDefaults`, `NSAppleEventManager`.

| Method | Line | Mark | Why |
| --- | --- | --- | --- |
| `awakeFromNib` | `:72-77` | CHANGE | Binds `autosavingDelay` to the `AutosavingDelay` default. Creates the dictionary and locks. In Swift, set `autosavingDelay` directly. |
| `dealloc` | `:79-85` | DROP | Manual memory code. |
| `openDocumentWithContentsOfPasteboard:display:error:` | `:89-149` | CHANGE | Makes a new doc from pasteboard text. Accepts plain, RTF, RTFD (lines 100-108). Keep the plain path only. Error code `TextEditOpenDocumentWithSelectionServiceFailed` (lines 143-146). |
| `openUntitledDocumentAndDisplay:error:` | `:153-170` | CHANGE | Marks the first untitled doc as transient if the current Apple Event is open-app or reopen-app (lines 161-166). |
| `transientDocumentToReplace` | `:172-176` | KEEP | Returns the single transient doc if it has no sheet. |
| `displayDocument:` | `:178-186` | CHANGE | Hops to the main thread with `performSelectorOnMainThread`. Use `MainActor`. |
| `replaceTransientDocument:` | `:188-218` | CHANGE | Moves window controllers from the transient doc to the new doc, closes the transient doc, posts an accessibility "value changed" note (lines 207-213). Uses TextKit 1 `layoutManagers`. |
| `openDocumentWithContentsOfURL:display:error:` | `:222-266` | CHANGE | Core of the transient swap. Defers display of other documents until the swap is done (lines 245-263). Removes `customOpenSettings[url]` (line 237). |
| `addDocument:` | `:270-277` | KEEP | A second document clears the first one's transient flag. |
| `+encodingAccessory:includeDefaultEntry:encodingPopUp:checkBox:` | `:281-292` | CHANGE | Loads `EncodingAccessory.nib` fresh each time and fills the popup via `EncodingManager`. Build the view in code. |
| `beginOpenPanel:forTypes:completionHandler:` | `:296-332` | CHANGE | Adds the accessory to the Open panel. Sets up the "Ignore rich text commands" checkbox, with a mixed state when `IgnoreRichText != IgnoreHTML` (lines 307-313). On OK, stores the choices for each picked URL (lines 315-328). For QuickEdit, keep the encoding popup; drop the checkbox, because every file opens as plain text. |
| `lastSelectedEncodingForURL:` | `:334-337` | KEEP | Open-panel choice, or the `PlainTextEncoding` default. |
| `lastSelectedIgnoreHTMLForURL:` | `:339-342` | DROP | Always "ignore" in QuickEdit. |
| `lastSelectedIgnoreRichForURL:` | `:344-347` | DROP | Same reason. |
| `defaultType` | `:352-354` | CHANGE | Returns RTF or `public.text` from the `RichText` default. QuickEdit always returns plain text. |

### 1.4 `Document` (`Document.h`, `Document.m`)
What it does: subclass of `NSDocument`. One per open file. It holds the text, reads and writes it, tracks encoding, handles the save-safety alerts and printing.
State (`Document.h:52-92`):
- `textStorage` (the text), `scaleFactor`, `isReadOnly`, `backgroundColor`, `hyphenationFactor`, `viewSize`, `hasMultiplePages`, `usesScreenFonts`.
- Seven document properties: `author`, `copyright`, `company`, `title`, `subject`, `comment`, `keywords` (rich only).
- `openedIgnoringRichText`, `documentEncoding`, `convertedDocument`, `lossyDocument`, `transient`, `originalOrientationSections`.
- `documentEncodingForSaving` (the encoding picked in the Save panel), `currentSaveOperation`, `fileTypeToSet`, `setUpPrintInfoDefaults`, `inDuplicate`.
- zadr only: `saveOperationTypeLock` (`zadr/Document.h:87`).
Talks to: `DocumentController`, `DocumentWindowController`, `PrintingTextView`, `PrintPanelAccessoryController`, `EncodingManager` (for `NoStringEncoding`), `NSUserDefaults`, `NSWorkspace`.

Reading and types:

| Method | Line | Mark | Why |
| --- | --- | --- | --- |
| `+isRichTextType:` | `:75-78` | DROP | A doc is rich if its type is not `public.text`. QuickEdit is never rich. |
| `+readableTypeForType:` | `:80-101` | CHANGE | Picks the most specific readable type the file conforms to (for example `public.xml` -> `public.text`). Uses `UTTypeConformsTo`. Port with `UTType.conforms(to:)`. |
| `-init` | `:103-128` | CHANGE | Makes the text storage, white background, no encoding, scale 1.0, default properties, default type, print info, `ShowPageBreaks`, screen fonts. Keep the plain parts. |
| `textDocumentTypeToTextEditDocumentTypeMappingTable` | `:132-151` | DROP | Maps AppKit document types to UTIs for 10 formats. QuickEdit has one. |
| `readFromURL:ofType:error:` | `:155-158` | KEEP | Pulls the Open-panel choices from `DocumentController`, then calls the full reader. |
| `readFromURL:ofType:encoding:ignoreRTF:ignoreHTML:error:` | `:160-307` | CHANGE | The main reader. See section 4. Keep the encoding parts. Drop margins, view size, paper size, hyphenation, background color, properties, read-only, orientation attributes (lines 252-302). Plain text files carry none of them. |
| `defaultTextAttributes:` | `:309-346` | CHANGE | Plain branch (lines 329-344): user fixed-pitch font, no tab stops, `defaultTabInterval = width of " " x TabWidth`. Uses `screenFontWithRenderingMode:` (line 331), deprecated. Rich branch (lines 312-328) DROP. |
| `applyDefaultTextAttributes:` | `:348-363` | CHANGE | Sets the plain attributes over all text, but keeps each paragraph's writing direction. Fine to keep in a simpler form. |
| `suggestedDocumentEncoding` | `:368-379` | KEEP | `PlainTextEncodingForWrite` if set, not UTF-16/UTF-8, and it can hold the text; else UTF-8. |
| `dealloc` | `:383-399` | DROP | Manual memory. zadr forgets `[company release]` (`zadr/Document.m:393-402`), a small leak. |

Simple accessors (`:401-553`): `scaleFactor`, `viewSize`, `readOnly` KEEP. `backgroundColor` DROP. `paperSize`/`setPaperSize:` (`:439-451`) KEEP for wrap-to-page and printing. `originalOrientationSections`, `usesScreenFonts`, `hyphenationFactor` DROP. `encoding`, `encodingForSaving` (`:484-500`) KEEP. `converted` DROP. `lossy` (`:511-517`) KEEP. `openedIgnoringRichText` DROP. `transient` and `isTransientAndCanBeReplaced` (`:529-543`) KEEP.

| Method | Line | Mark | Why |
| --- | --- | --- | --- |
| `setFileType:` | `:545-549` | DROP | Maps `public.plain-text` back to `public.text`. Only needed for the rich-to-plain switch under the sandbox (comment at line 546). |
| `isRichText` | `:551-553` | DROP | Always NO. Many call sites branch on it; remove those branches. |
| Document properties block | `:560-629` | DROP | `documentPropertyToAttributeNameMappings`, `knownDocumentProperties`, `hasDocumentProperties`, `clearDocumentProperties`, `setDocumentPropertiesToDefaults`, `setValue:forDocumentProperty:`, `setValue:forKey:`. Plain text cannot store them. |
| `printOperationWithSettings:error:` | `:633-677` | CHANGE | See section 5. Uses a TextKit 1 layout-manager swap to print. |
| `printInfo` | `:679-692` | KEEP | First call sets fit-to-width pagination, no centering, 72 pt (1 inch) margins. |
| `toggleReadOnly:` | `:696-702` | KEEP | Format > Prevent/Allow Editing, with undo. Not saved in plain files. |
| `toggleRichWillLoseInformation` | `:704-715` | DROP | Rich-to-plain check. |
| `hasMultiplePages`, `setHasMultiplePages:`, `togglePageBreaks:` | `:717-727` | KEEP | Wrap-to-page flag and its menu action. |
| `toggleHyphenation:` | `:729-733` | DROP | Hyphenation is saved only in RTF. |
| `appendPlainTextExtensionChanged:` | `:737-741` | CHANGE | Save-panel checkbox action. Uses `setAllowedFileTypes:` (deprecated). |
| `encodingPopupChanged:` | `:743-745` | KEEP | Save-panel popup action; sets `encodingForSaving`. |
| `validateToggleItem` (C function) | `:751-763` | CHANGE | Swaps menu titles; uses tags 42/43 as a cache. Uses `setTitleWithMnemonic:`. Just set `title`. |
| `validateMenuItem:` | `:767-783` | CHANGE | Titles for Prevent Editing, Wrap to Page, Hyphenation. Keep the first two. |
| `setTextStorage:` | `:786-798` | CHANGE | Scripting setter for "text of document", with undo. Keep if we keep AppleScript. |
| `revertToContentsOfURL:ofType:error:` | `:800-812` | KEEP | Restores the file type after a revert, re-applies wrap mode, and re-runs `setupTextViewForDocument` on each window controller. |
| `defaultTextPadding()` (C function) | `:819-827` | KEEP | Reads `lineFragmentPadding` from a fresh `NSTextContainer` (5 pt by default). Used in all window-size and page math. |

NSDocument overrides (category `TextEditNSDocumentOverrides`, `:829-1323`):

| Method | Line | Mark | Why |
| --- | --- | --- | --- |
| `+autosavesInPlace` | `:831-833` | KEEP | YES. Turns on Auto Save, Versions, and the modern Duplicate/Rename/Revert menu behavior. |
| `+canConcurrentlyReadDocumentsOfType:` | `:835-838` | KEEP | YES for all but HTML and web archive. So plain text reads on background threads. This is why the locks exist. |
| `makeWindowControllers` | `:840-847` | KEEP | Makes a `DocumentWindowController` unless one came over from a transient doc. |
| `writableTypesForSaveOperation:ignoreTemporaryState:` | `:851-866` | DROP | Removes plain types from rich docs, forces RTFD for attachments. |
| `writableTypesForSaveOperation:` | `:868-870` | CHANGE | Return just plain text. |
| `fileNameExtensionForType:saveOperation:` | `:872-876` | KEEP | `public.text` has no extension of its own, so return `txt`. |
| `saveToURL:ofType:forSaveOperation:completionHandler:` | `:884-896` | KEEP | Breaks undo grouping in every window (so undo can stop at the save point), stores `currentSaveOperation`, calls super, then clears `encodingForSaving`. zadr uses an `NSLock` here instead (`zadr/Document.m:895-901`). |
| `canAsynchronouslyWriteToURL:ofType:forSaveOperation:` | `:900-902` | KEEP | YES for plain text, so saves write on a background thread. |
| `errorInTextEditDomainWithCode:` | `:904-978` | CHANGE | Builds 4 recoverable errors. Keep `TextEditSaveErrorLossyDocument` (`:950-960`) and `TextEditSaveErrorEncodingInapplicable` (`:961-974`). Rewrite `TextEditSaveErrorWritableTypeRequired` (`:906-932`) to convert to UTF-8 plain text, not RTF. Drop `TextEditSaveErrorConvertedDocument` (`:933-949`). |
| `checkAutosavingSafetyAfterChangeAndReturnError:` | `:980-996` | KEEP | After each edit, checks that the text still fits the doc's encoding. See section 4.6. |
| `updateChangeCount:` | `:998-1047` | CHANGE | Clears the transient flag. Runs the safety check. On failure shows a sheet; if the user cancels, it undoes the edit. Uses `Block_copy` context pointers. Rich auto-convert for untitled docs (lines 1010-1013) DROP. |
| `autosavingFileType` | `:1049-1055` | DROP | Rich-only duplicate case. |
| `duplicateAndReturnError:` | `:1061-1067` | DROP | Only sets `inDuplicate` for the method above. |
| `document:didSave:block:`, `didPresentErrorWithRecovery:block:` | `:1069-1077` | CHANGE | Block trampolines for selector callbacks. Use closures. |
| `attemptRecoveryFromError:optionIndex:delegate:didRecoverSelector:contextInfo:` | `:1079-1139` | CHANGE | Handles the alert buttons. Calls the delegate's selector through a cast `objc_msgSend` (lines 1103, 1129, 1138). Hard in Swift (risk 5). |
| `fileWrapperOfType:error:` | `:1143-1237` | CHANGE | The writer. See section 4.5. Most of the attribute dictionary is rich-only. |
| `checkAutosavingSafetyAndReturnError:` | `:1239-1256` | CHANGE | Before writing over the file: writable type, converted, lossy. Keep writable-type and lossy. |
| `shouldRunSavePanelWithAccessoryView` | `:1260-1262` | KEEP | Returns NO for plain text, which hides NSDocument's file-format popup. |
| `prepareSavePanel:` | `:1266-1321` | CHANGE | Adds the encoding popup and the ".txt" checkbox. See section 4.4. |
| `truncatedString()` (C function) | `:1328-1332` | KEEP | Cuts long strings for error text. |
| `saveDocumentAsPDFTo:` | `zadr/Document.m:818-821` | DROP | zadr only. Apple's copy uses the built-in `saveDocumentToPDF:` instead. |

### 1.5 `DocumentWindowController` (`DocumentWindowController.h`, `.m`)
What it does: owns the window, the scroll view, the one shared `NSLayoutManager`, and one or many text views. Switches between wrap-to-window and wrap-to-page. Handles window sizing, restoration, links, attachments and the rich toggle.
State (`DocumentWindowController.h:53-59`): `scrollView` (a `ScalingScrollView` outlet), `layoutMgr`, `hasMultiplePages`, `rulerIsBeingDisplayed`, `isSettingSize` (stops resize loops).
Talks to: `Document` (KVO on `printInfo`, `richText`, `viewSize`, `hasMultiplePages`), `ScalingScrollView` (KVO on `scaleFactor`), the vertical scroller (KVO on `scrollerStyle`), `MultiplePageView`, `NSUserDefaults`, `NSWorkspace`.

| Method | Line | Mark | Why |
| --- | --- | --- | --- |
| `init` | `:87-94` | CHANGE | Loads `DocumentWindow.nib`. Makes the shared `NSLayoutManager` with non-contiguous layout. TextKit 2 has no shared layout manager across views. |
| `dealloc` | `:96-109` | DROP | Manual memory and observer removal. |
| `setDocument:` | `:118-160` | CHANGE | Runs on open, on close, and twice on a transient swap. Moves the layout manager between text storages, binds hyphenation (drop) and `editable` to `!document.readOnly`, adds and removes KVO. |
| `breakUndoCoalescing` | `:162-164` | KEEP | Called at each save. |
| `layoutManager`, `firstTextView` | `:166-172` | CHANGE | `firstTextView` goes through the layout manager. That forces TextKit 1. Keep a direct reference to the text view. |
| `setupInitialTextViewSharedState` | `:174-201` | KEEP | Find bar, incremental search, undo, delegate, and the spelling and substitution flags from defaults. Drop `setUsesFontPanel:` and `setAllowsDocumentBackgroundColorChange:`. |
| `observeValueForKeyPath:...` | `:203-234` | CHANGE | Background color (drop), scale factor to doc (keep), scroller style change resizes the window (keep), doc print info (keep), view size (keep), wrap mode (keep). Use Swift KVO or plain callbacks. |
| `setupTextViewForDocument` | `:236-262` | CHANGE | Sets typing attributes, rich state, background, screen fonts, vertical orientation. Keep only typing attributes. |
| `printInfoUpdated` | `:264-279` | KEEP | When Page Setup changes, resizes each page's container and view. |
| `showRulerDelayed:`, `showRuler:` | `:283-295` | DROP | Ruler. |
| `removeAttachments` | `:299-322` | DROP | Rich-to-plain. |
| `presenterDidPresent:soContinue:` | `:327-330` | DROP | Block trampoline. |
| `chooseAndAttachFiles:` | `:332-389` | DROP | Attach Files. |
| `updateForRichTextAndRulerState:` | `:393-402` | CHANGE | For plain: not rich, no ruler, no inspector bar, no graphics, screen fonts on. Keep the first four as fixed setup. Drop screen fonts. |
| `configureTypingAttributesAndDefaultParagraphStyleForTextView:` | `:404-412` | KEEP | Plain font and tab width for each new text view. |
| `convertTextForRichTextState:removeAttachments:` | `:414-434` | DROP | Rich toggle. |
| `numberOfPages` | `:436-438` | KEEP | Page count, 1 in wrap-to-window. |
| `updateTextViewGeometry` | `:440-446` | DROP | Only for vertical layout. |
| `setupPagesViewForLayoutOrientation:` | `:448-457` | DROP | Vertical layout. |
| `addPage` | `:459-495` | CHANGE | Adds one page: container + text view at the page's document rect. TextKit 1 only. |
| `removePage` | `:497-506` | CHANGE | Removes the last page. TextKit 1 only. |
| `documentView` | `:508-510` | KEEP | Used for printing. |
| `setHasMultiplePages:force:` | `:512-615` | CHANGE | The mode switch. See section 5. |
| `restoreStateWithCoder:` / `encodeRestorableStateWithCoder:` | `:619-637` | KEEP | Saves the scroller style. If it changed since quit, resizes the window so the text width stays the same. |
| `resizeWindowForViewSize:` | `:639-654` | KEEP | Sets the window frame from a wanted text size. Adds padding in wrap-to-window. Keeps the top-left corner fixed. |
| `setupWindowForDocument` | `:656-679` | KEEP | Window size from `viewSize`, page size, or `WidthInChars` x `HeightInChars` (90 x 30) of the fixed-pitch font. Uses `defaultLineHeightForFont:` (TextKit 1) and `screenFontWithRenderingMode:` (deprecated). |
| `windowDidLoad` | `:681-698` | KEEP | Builds the first text view, shared state, window size, zoom, observers. Clears undo. |
| `setDocumentEdited:` | `:700-703` | DROP | Clears orientation sections. |
| `layoutOrientationSections` | `:706-745` | DROP | Vertical layout info for RTF. |
| `toggleRichWithNewFileType:` | `:747-789` | DROP | Rich toggle. |
| `toggleRich:`, `didEndToggleRichSheet:...` | `:793-836` | DROP | Rich toggle and its alert. |
| `toggleLayoutOrientation:` | `:840-852` | DROP | Vertical layout. |
| `windowWillUseStandardFrame:defaultFrame:` | `:860-882` | KEEP | Zoom button: in wrap-to-page, fit one page width. |
| `windowDidResize:` | `:884-897` | CHANGE | Clears the transient flag; stores the new `viewSize`. Uses a scroll-view sizing method deprecated since 10.7 (line 889). |
| `windowDidMove:` | `:899-901` | KEEP | Clears the transient flag. |
| `textView:clickedOnLink:atIndex:` | `:905-952` | DROP | Links exist only in rich text. Keep if we turn on link detection later. |
| `textView:URLForContentsOfTextAttachment:atIndex:` | `:954-968` | DROP | Attachments. |
| `textView:writablePasteboardTypesForCell:...`, `textView:writeCell:...` | `:970-988` | DROP | Attachments. |
| `layoutManager:didCompleteLayoutForTextContainer:atEnd:` | `:992-1022` | CHANGE | Adds a page when the last page is full; removes empty pages when layout ends. TextKit 1 delegate. |
| `validateMenuItem:` | `:1029-1054` | CHANGE | Rich toggle, Attach Files, vertical layout. All three items are dropped, so this shrinks to nothing. |
| `textView:menu:forEvent:atIndex:` | `:1056-1081` | DROP | Removes the vertical-layout item from the context menu. |
| `-[NSTextView textEditDoForegroundLayoutToCharacterIndex:]` | `:1089-1101` | CHANGE | Forces layout up to a character by asking a glyph question. TextKit 1. In TextKit 2 use `ensureLayout(for:)` on the text layout manager. |
| `autosaveIfNeededThenToggleRich` | declared `:67`, built only in `zadr/DocumentWindowController.m:787-798` | DROP | Leftover declaration in apple. |

### 1.6 `MultiplePageView` (`MultiplePageView.h`, `.m`)
What it does: the document view in wrap-to-page mode. It draws the pages and works out page rectangles. Each page's text view is a subview.
State (`MultiplePageView.h:52-58`): `printInfo` (a copy), `lineColor` (light gray), `marginColor` (white), `numPages`, `layoutOrientation`.
Talks to: nothing but its superview; `DocumentWindowController` drives it.

| Method | Line | Mark | Why |
| --- | --- | --- | --- |
| `initWithFrame:` | `:56-65` | KEEP | Colors and shared print info. Use dynamic colors for dark mode. |
| `isFlipped`, `isOpaque` | `:67-73` | KEEP | Top-left origin. |
| `updateFrame` | `:75-89` | KEEP | Height = pages x paper height + 5 pt gaps. Drop the vertical branch. |
| `setPrintInfo:`, `printInfo` | `:91-102` | KEEP | |
| `setNumberOfPages:`, `numberOfPages` | `:104-119` | KEEP | |
| `pageSeparatorHeight` | `:121-123` | KEEP | 5 pt. |
| `documentSizeInPage` | `:130-132` | KEEP | Calls `documentSizeForPrintInfo`. |
| `documentRectForPageNumber:` | `:134-140` | KEEP | Page rect moved in by the margins, minus padding on the left. |
| `pageRectForPageNumber:` | `:142-153` | KEEP | Drop the vertical branch. |
| `pageNumberForPoint:` | `:157-169` | KEEP | Used by smart magnify. |
| color accessors | `:171-193` | KEEP | |
| `setLayoutOrientation:`, `layoutOrientation` | `:195-205` | DROP | Vertical layout. |
| `drawRect:` | `:207-247` | CHANGE | Fills white, frames each page's text area, paints gaps in the clip view's color. Uses `NSRectFill`; fine but use dynamic colors. |
| `rectForSmartMagnificationAtPoint:inRect:` | `:251-274` | KEEP | Two-finger double-tap zoom target. |
| `knowsPageRange:`, `rectForPage:`, `locationOfPrintRect:` | `:278-292` | KEEP | Printing in wrap-to-page prints this view directly. |
| `documentSizeForPrintInfo()` (C function) | `:297-302` | KEEP | Paper size minus margins, plus 2 x padding in width. |

### 1.7 `ScalingScrollView` (`ScalingScrollView.h`, `.m`)
What it does: an `NSScrollView` with zoom. Since TextEdit 1.8 it uses the built-in magnification, not a popup.
State: none of its own; `scaleFactor` is `magnification`.
Talks to: `DocumentWindowController` observes `scaleFactor`.

| Method | Line | Mark | Why |
| --- | --- | --- | --- |
| `awakeFromNib` | `:55-60` | KEEP | Magnification on; min 0.25, max 16.0. |
| `scaleFactor`, `setScaleFactor:`, `setScaleFactor:adjustPopup:` | `:62-72` | KEEP | Thin wrappers. `adjustPopup` is a leftover name. |
| `zoomToActualSize:` | `:76-78` | KEEP | Animates to 1.0. |
| `zoomIn:` | `:80-84` | KEEP | Doubles; from 0.4-0.6 snaps to 1.0. |
| `zoomOut:` | `:86-90` | KEEP | Halves; from 1.8-2.2 snaps to 1.0. |
| `preservesContentDuringLiveResize` | `:94-96` | KEEP | Turns back on a live-resize speedup that AppKit turns off for subclasses. |

### 1.8 `PrintingTextView` (`PrintingTextView.h`, `.m`)
What it does: a throwaway `NSTextView` used to print wrap-to-window documents.
State (`PrintingTextView.h:54-61`): `printPanelAccessoryController`, `originalSize` (on-screen text view size), last page size, last "rewrap" value.
Talks to: `PrintPanelAccessoryController`.

| Method | Line | Mark | Why |
| --- | --- | --- | --- |
| `knowsPageRange:` | `:63-77` | CHANGE | When the page size or "Rewrap" choice changes, resizes itself to the page's text width (rewrap) or to the on-screen width, then forces full layout. Sets attachment scaling (drop). Forces TextKit 1 through `textEditDoForegroundLayoutToCharacterIndex:`. |

### 1.9 `PrintPanelAccessoryController` (`PrintPanelAccessoryController.h`, `.m`)
What it does: the extra two checkboxes in the Print panel: "Print header and footer" and "Rewrap contents to fit page".
State: `showsWrappingToFit`, `wrappingToFit`; `pageNumbering` lives in the print info dictionary (`NSPrintHeaderAndFooter`).
Talks to: `NSPrintInfo` (its `representedObject`), `NSUserDefaults`.

| Method | Line | Mark | Why |
| --- | --- | --- | --- |
| `initWithNibName:bundle:` | `:58-61` | CHANGE | Forces `PrintPanelAccessory.nib`. Build in code. |
| `setRepresentedObject:` | `:65-72` | KEEP | Loads both values from defaults; starts KVO on itself. |
| `dealloc` | `:74-80` | DROP | Observer removal. |
| `observeValueForKeyPath:...` | `:84-92` | KEEP | Writes changed values back to defaults, so they stick across launches. |
| `setPageNumbering:`, `pageNumbering` | `:96-104` | KEEP | Read and write `NSPrintHeaderAndFooter`. |
| `keyPathsForValuesAffectingPreview` | `:106-108` | KEEP | Redraws the print preview on change. |
| `localizedSummaryItems` | `:112-124` | KEEP | Lines in the Print panel's summary. |
| `changePageNumbering:`, `changeWrappingToFit:` | `zadr/PrintPanelAccessoryController.m:81-88` | DROP | zadr used target-action plus bindings to defaults; apple replaced that with KVO. |

### 1.10 `Preferences` (`Preferences.h`, `.m`)
What it does: the Preferences window controller. Most controls bind straight to `NSUserDefaultsController` in the nib. Code is only for fonts, HTML options, and "Restore All Defaults".
State: `changingRTFFont`, `originalDimensionFieldValue`.
Talks to: `NSFontManager`, `NSFont` user-font class methods, `NSUserDefaults`, `Controller` (for restoration).

| Method | Line | Mark | Why |
| --- | --- | --- | --- |
| `init` | `:61-63` | CHANGE | Loads `Preferences.nib`. Build a new Settings window. |
| `windowDidLoad` | `:65-71` | KEEP | Not hidden on deactivate, not in Window menu, restorable. |
| `+restoreWindowWithIdentifier:...` | `:75-77` | KEEP | Reopens after relaunch. |
| `changeRichTextFont:` | `:82-90` | DROP | Rich font. |
| `changePlainTextFont:` | `:92-100` | CHANGE | Opens the Font panel to pick the plain font. The brief drops the Font panel from documents; we still need some font picker here. A Font panel used only from Settings is the simplest choice. |
| `changeFont:` | `:102-108` | CHANGE | Font panel callback. In modern AppKit, adopt `NSFontChanging`. |
| `setRichTextFont:`, `richTextFont` | `:110-120` | DROP | |
| `setPlainTextFont:`, `plainTextFont` | `:114-124` | KEEP | `+[NSFont setUserFixedPitchFont:]` and `userFixedPitchFontOfSize:0`. |
| `HTMLDocumentType` ... `setHTMLStylingMode:` | `:130-178` | DROP | HTML save options. |
| `revertToDefault:` | `:182-199` | CHANGE | Clears HTML keys, both fonts, then reverts all bound defaults. Keep the plain-font and bound-defaults parts. |
| `windowShouldClose:` | `:205-207` | KEEP | Commits a half-typed field. |
| `controlTextDidBeginEditing:`, `control:didFailToFormatString:errorDescription:` | `:211-220` | KEEP | Puts back the old window-size value if the user types junk. Formatter range is 1-10000 (`Base.lproj/Preferences.nib/designable.nib:445-446`, `:534-535`). |

### 1.11 `EncodingManager` and `EncodingPopUpButtonCell` (`EncodingManager.h`, `.m`)
What it does: the list of encodings shown in every encoding popup, the "Customize Encodings List" panel, and a popup cell that refreshes itself when the list changes.
State: `encodingMatrix` (outlet), `encodings` (the enabled list). `NoStringEncoding = 0xFFFFFFFF` (`EncodingManager.h:53-55`) means "Automatic / none". `WantsAutomaticTag = -1` (`:57-59`) marks a popup that wants the "Automatic" item.
Talks to: `NSUserDefaults` (key `Encodings`), `NSNotificationCenter` (`EncodingsListChanged`), CoreFoundation encoding functions.

| Method | Line | Mark | Why |
| --- | --- | --- | --- |
| `EncodingPopUpButtonCell initTextCell:pullsDown:`, `initWithCoder:` | `:62-76` | CHANGE | Fill on creation; listen for list changes. In Swift, a small `NSPopUpButton` helper. |
| `EncodingPopUpButtonCell selectItemAtIndex:` | `:85-87` | KEEP | Stops the separator and "Customize…" item from staying selected. |
| `EncodingPopUpButtonCell encodingsListChanged:` | `:91-93` | KEEP | Refills, keeping the selection. |
| `+sharedInstance`, `init`, `dealloc` | `:104-119` | CHANGE | Old singleton pattern. Use `static let shared`. |
| `encodingCompare` (C) | `:125-137` | KEEP | Sorts Unicode first, then by the closest Mac encoding. |
| `+allAvailableStringEncodings` | `:141-159` | KEEP | All CF encodings that have a human name, sorted. |
| `setupEncodingsList` | `:164-180` | CHANGE | Fills the `NSMatrix` of checkboxes. `NSMatrix` is legacy; use a table of checkboxes. |
| `setupPopUpCell:selectedEncoding:withDefaultEntry:` | `:185-223` | KEEP | Builds the popup: optional "Automatic", the enabled encodings (adds the selected one if missing), separator, "Customize Encodings List…". |
| `enabledEncodings` | `:228-251` | KEEP | From the `Encodings` default, or the built-in list: UTF-16, UTF-8, Mac Roman, Windows Latin 1, Mac Japanese, Shift JIS, Mac Chinese Traditional, Mac Korean, Mac Chinese Simplified, GB 18030 (lines 229-231), plus the system default C-string encoding if missing (lines 235-246). |
| `noteEncodingListChange:updateList:postNotification:` | `:255-267` | KEEP | Save, refresh the panel, tell all popups. |
| `worksWhenModal` | `:271-273` | KEEP | So "Customize…" works while the Open or Save panel is up. |
| `showPanel:` | `:278-290` | CHANGE | Loads `SelectEncodingsPanel.nib`, works when modal, modal-panel window level. Build in code. |
| `encodingListChanged:`, `clearAll:`, `selectAll:`, `revertToDefault:` | `:292-326` | KEEP | Panel buttons and checkbox clicks. |

### 1.12 `LinePanelController` (`LinePanelController.h`, `.m`)
What it does: Edit > Find > Select Line… (Cmd+L). Parses `N`, `N-M`, `+N`, `-N`, `+N-M`, `-N-M` and selects those lines.
State: `lineField` outlet.
Talks to: the main window's first responder (any `NSTextView`).

| Method | Line | Mark | Why |
| --- | --- | --- | --- |
| `init`, `windowDidLoad`, `+restoreWindowWithIdentifier:...` | `:58-73` | CHANGE | Nib loading and restoration. Build in code; keep restoration. |
| `parseLineDescription:fromLineSpec:toLineSpec:relative:` | `:77-87` | KEEP | Uses `NSScanner` (localized). |
| `getRange:inTextView:fromLineSpec:toLineSpec:relative:` | `:94-137` | KEEP | Walks lines with `lineRangeForRange:`, which counts LF, CR, CRLF, U+2028 and U+2029 as line ends. Line numbers are hard (paragraph) lines, not wrapped lines. |
| `selectLinesUsingDescription:error:` | `:141-158` | KEEP | Errors `TextEditInvalidLineSpecification` (200) and `TextEditOutOfRangeLineSpecification` (201); both say "Invalid line specification "%@"." |
| `lineFieldChanged:`, `selectClicked:` | `:162-182` | KEEP | Return key closes the panel on success; the button leaves it open. |

### 1.13 `DocumentPropertiesPanelController` (`.h`, `.m`)
What it does: the File > Show Properties inspector for author, title, keywords and so on.
Mark: DROP the whole class. Plain text cannot store these. The nib itself says "Document properties are not saved in plain text documents" (`Base.lproj/DocumentProperties.nib/designable.nib:396`).
For the record: it tracks the main window's document by KVO on `mainWindow.windowController.document` (`DocumentPropertiesPanelController.m:109`), commits edits when the panel loses key (`:105`, `:126-128`), and toggles its menu title (`:143-149`).

### 1.14 `FontNameTransformer` (`.h`, `.m`)
What it does: turns an `NSFont` into "Name 12" for the Preferences window.
Mark: CHANGE. Keep the idea; in Swift just format the string.
Bug: the class method is spelled `tranformedValueClass` (`FontNameTransformer.m:54`), so AppKit never calls it. Harmless.

### 1.15 Header-only files
- `TextEditDefaultsKeys.h:51-88`: all default key names. See section 3.
- `TextEditErrors.h:50-61`: error domain `com.apple.TextEdit` and codes 1-4, 100, 200, 201, 300. KEEP 2 (lossy), 3 (writable type), 4 (encoding), 100, 200, 201. DROP 1 (converted) and 300 (attach).
- `TextEditMisc.h:52-67`: prototypes for `defaultTextPadding`, `validateToggleItem`, `truncatedString`, `documentSizeForPrintInfo`, and the `NSTextView` category.

### 1.16 Resources and project files
- `Info-TextEdit.plist`:
  - Document types (`:9-205`). KEEP: `public.text` (Editor, `:141-156`) and `public.plain-text` (Editor, `:157-174`). CHANGE: `com.apple.traditional-mac-plain-text` (Viewer, `:175-190`) and `public.data` "Unknown document" (Viewer, `:191-204`); decide whether QuickEdit opens any file as text. DROP: RTF, RTFD, HTML, web archive, ODT, Word types (`:11-140`).
  - Services (`:239-278`): KEEP both, but limit `NSSendTypes` to `public.plain-text`.
  - `NSSupportsSuddenTermination` YES (`:279-280`), `NSAppleScriptEnabled` (`:230-231`), help book keys (`:208-211`): review.
  - `LSMinimumSystemVersion` 10.9 (`:228-229`); zadr says 10.8.
- `TextEdit.scriptSuite`, `TextEdit.scriptTerminology`: old-style scripting. They add `document.text` mapped to `textStorage` (`TextEdit.scriptSuite:16-25`). CHANGE: write an `.sdef` if we keep AppleScript.
- `TextEdit.scatterload`: a linker symbol order file. DROP.
- `English.lproj/*.strings` (apple: binary plists; zadr: UTF-16 text): UI text. `ZoomValues.strings` (10% to 1600%) is not used by any code in either copy; it is left over from the old zoom popup. `PrintAccessory.strings` (apple) is named `PrintPanelAccessory.strings` in zadr, and each copy's code uses its own table name.
- `ReadMe.txt` and `README.rtf`: partly out of date. They say `Document` overrides `writeToURL:ofType:error:` (no such override in either copy) and that `ScalingScrollView` has a zoom popup (it does not since 1.8). zadr's `README.rtf` has a useful change log for 1.6 to 1.8.
- `TextEdit Test Document.rtf`: a rich sample. DROP.

---

## 2. Main menu (`apple/Base.lproj/Edit.nib/designable.nib`)

Keys: "Cmd+S" means Command-Shift-S (capital letter). Target "FR" means First Responder. The nib line is where the item starts.
Plain text column: KEEP, DROP or CHANGE, with the reason when it is not obvious.

### TextEdit (app menu, `:44`)
| Item | Key | Action -> target | Line | Plain text |
| --- | --- | --- | --- | --- |
| About TextEdit | | `orderFrontStandardAboutPanel:` -> NSApplication | 64 | KEEP |
| Preferences… | Cmd+, | `showWindow:` -> Preferences | 84 | CHANGE: rename "Settings…" |
| Services (submenu `_NSServicesMenu`) | | | 104 | KEEP |
| Hide TextEdit | Cmd+H | `hide:` -> NSApplication | 135 | KEEP |
| Hide Others | Opt+Cmd+H | `hideOtherApplications:` -> NSApplication | 144 | KEEP |
| Show All | | `unhideAllApplications:` -> NSApplication | 153 | KEEP |
| Quit TextEdit | Cmd+Q | `terminate:` -> NSApplication | 173 | KEEP |

### File (`:186`)
| Item | Key | Action -> target | Line | Plain text |
| --- | --- | --- | --- | --- |
| New | Cmd+N | `newDocument:` -> FR | 202 | KEEP |
| Open… | Cmd+O | `openDocument:` -> FR | 211 | KEEP |
| Open Recent > Clear Menu | | `clearRecentDocuments:` -> FR | 220, 236 | KEEP |
| Close | Cmd+W | `performClose:` -> FR | 260 | KEEP |
| Save | Cmd+S | `saveDocument:` -> FR | 269 | KEEP |
| Save As… | Shift+Cmd+S | `saveDocumentAs:` -> FR | 278 | CHANGE: with Auto Save, modern apps show Duplicate (Shift+Cmd+S), Rename…, Move To… and Revert To; add those |
| Save All | | `saveAllDocuments:` -> FR | 287 | KEEP |
| Revert to Saved | | `revertDocumentToSaved:` -> FR | 296 | CHANGE: becomes the "Revert To" submenu with Browse All Versions |
| Export as PDF… | | `saveDocumentToPDF:` -> FR | 315 | KEEP (built into NSDocument) |
| Show Properties | Opt+Cmd+P | `toggleWindow:` -> DocumentPropertiesPanelController | 334 | DROP: properties are rich only |
| Page Setup… | Shift+Cmd+P | `runPageLayout:` -> FR | 354 | KEEP |
| Print… | Cmd+P | `printDocument:` -> FR | 363 | KEEP |

### Edit (`:375`)
| Item | Key | Action -> target | Line | Plain text |
| --- | --- | --- | --- | --- |
| Undo | Cmd+Z | `undo:` | 391 | KEEP |
| Redo | Shift+Cmd+Z | `redo:` | 400 | KEEP |
| Cut | Cmd+X | `cut:` | 420 | KEEP |
| Copy | Cmd+C | `copy:` | 429 | KEEP |
| Paste | Cmd+V | `paste:` | 438 | KEEP |
| Paste and Match Style | Opt+Shift+Cmd+V | `pasteAsPlainText:` | 447 | DROP: a plain view always pastes plain |
| Delete | | `delete:` | 456 | KEEP |
| Complete | Opt+Esc | `complete:` | 465 | KEEP |
| Select All | Cmd+A | `selectAll:` | 474 | KEEP |
| Insert > Line Break | | `insertLineBreak:` | 494, 508 | DROP: inserts U+2028, not a normal line end in a .txt file |
| Insert > Paragraph Break | | `insertNewline:` | 517 | DROP: same as Return |
| Insert > Page Break | | `insertContainerBreak:` | 525 | DROP: inserts a form feed for page breaks; rarely wanted in plain text |
| Attach Files… | Shift+Cmd+A | `chooseAndAttachFiles:` | 537 | DROP |
| Link… | Cmd+K | `orderFrontLinkPanel:` | 546 | DROP: links are attributes |
| Find > Find… | Cmd+F | `performTextFinderAction:` tag 1 | 566, 582 | KEEP |
| Find > Find and Replace… | Opt+Cmd+F | `performTextFinderAction:` tag 12 | 592 | KEEP |
| Find > Find Next | Cmd+G | `performTextFinderAction:` tag 2 | 602 | KEEP |
| Find > Find Previous | Shift+Cmd+G | `performTextFinderAction:` tag 3 | 612 | KEEP |
| Find > Use Selection for Find | Cmd+E | `performTextFinderAction:` tag 7 | 622 | KEEP |
| Find > Jump to Selection | Cmd+J | `centerSelectionInVisibleArea:` | 632 | KEEP |
| Find > Select Line... | Cmd+L | `showWindow:` -> LinePanelController | 641 | KEEP |
| Spelling and Grammar > Show Spelling and Grammar | Cmd+: | `showGuessPanel:` | 653, 667 | KEEP |
| … > Check Document Now | Cmd+; | `checkSpelling:` | 676 | KEEP |
| … > Check Spelling While Typing | | `toggleContinuousSpellChecking:` | 695 | KEEP |
| … > Check Grammar With Spelling | | `toggleGrammarChecking:` | 704 | KEEP |
| … > Correct Spelling Automatically | | `toggleAutomaticSpellingCorrection:` | 713 | KEEP |
| Substitutions > Show Substitutions | | `orderFrontSubstitutionsPanel:` | 725, 739 | KEEP |
| … > Smart Copy/Paste | | `toggleSmartInsertDelete:` | 757 | KEEP |
| … > Smart Quotes | | `toggleAutomaticQuoteSubstitution:` | 765 | KEEP |
| … > Smart Dashes | | `toggleAutomaticDashSubstitution:` | 773 | KEEP |
| … > Smart Links | | `toggleAutomaticLinkDetection:` | 781 | DROP: makes link attributes |
| … > Data Detectors | | `toggleAutomaticDataDetection:` | 790 | CHANGE: test it on a plain TextKit 2 view first; drop if it does nothing |
| … > Text Replacement | | `toggleAutomaticTextReplacement:` | 799 | KEEP |
| Transformations > Make Upper Case / Make Lower Case / Capitalize | | `uppercaseWord:` / `lowercaseWord:` / `capitalizeWord:` | 811, 824, 832, 840 | KEEP |
| Speech > Start Speaking / Stop Speaking | | `startSpeaking:` / `stopSpeaking:` | 851, 865, 874 | KEEP |

### Format (`:889`)
| Item | Key | Action -> target | Line | Plain text |
| --- | --- | --- | --- | --- |
| Font > Show Fonts | Cmd+T | `orderFrontFontPanel:` -> NSFontManager | 905, 921 | DROP (brief drops the Font panel) |
| Font > Bold | Cmd+B | `addFontTrait:` tag 2 -> NSFontManager | 930 | DROP |
| Font > Italic | Cmd+I | `addFontTrait:` tag 1 -> NSFontManager | 940 | DROP |
| Font > Underline | Cmd+U | `underline:` | 950 | DROP |
| Font > Outline | | `outline:` | 959 | DROP |
| Font > Styles... | | `orderFrontStylesPanel:` -> NSFontManager | 967 | DROP |
| Font > Bigger | Cmd++ | `modifyFont:` tag 3 -> NSFontManager | 986 | DROP: use View > Zoom |
| Font > Smaller | Cmd+- | `modifyFont:` tag 4 -> NSFontManager | 996 | DROP: use View > Zoom |
| Font > Kern > Use Default / Use None / Tighten (Opt+Cmd+[) / Loosen (Opt+Cmd+]) | | `useStandardKerning:` / `turnOffKerning:` / `tightenKerning:` / `loosenKerning:` | 1017-1060 | DROP |
| Font > Ligatures > Use Default / Use None / Use All | | `useStandardLigatures:` / `turnOffLigatures:` / `useAllLigatures:` | 1072-1104 | DROP |
| Font > Baseline > Use Default / Superscript / Subscript / Raise / Lower | | `unscript:` / `superscript:` / `subscript:` / `raiseBaseline:` / `lowerBaseline:` | 1116-1167 | DROP |
| Font > Character Shape > Traditional Form | | `toggleTraditionalCharacterShape:` | 1179, 1193 | DROP |
| Font > Show Colors | Shift+Cmd+C | `orderFrontColorPanel:` | 1216 | DROP |
| Font > Copy Style | Opt+Cmd+C | `copyFont:` | 1236 | DROP |
| Font > Paste Style | Opt+Cmd+V | `pasteFont:` | 1245 | DROP |
| Text > Align Left (Cmd+{) / Center (Cmd+\|) / Justify / Align Right (Cmd+}) | | `alignLeft:` / `alignCenter:` / `alignJustified:` / `alignRight:` | 1258-1299 | DROP |
| Text > Writing Direction > Paragraph: Default / Left to Right / Right to Left | | `makeBaseWritingDirectionNatural:` / `…LeftToRight:` / `…RightToLeft:` | 1319-1357 | DROP for v1: not stored in a .txt file (note for right-to-left users) |
| Text > Writing Direction > Selection: Default / Left to Right / Right to Left | | `makeTextWritingDirectionNatural:` / `…LeftToRight:` / `…RightToLeft:` | 1375-1400 | DROP |
| Text > Show Ruler | Cmd+R | `toggleRuler:` | 1422 | DROP |
| Text > Copy Ruler | Ctrl+Cmd+C | `copyRuler:` | 1431 | DROP |
| Text > Paste Ruler | Ctrl+Cmd+V | `pasteRuler:` | 1440 | DROP |
| Text > Spacing... | | `orderFrontSpacingPanel:` | 1460 | DROP |
| Make Rich Text | Shift+Cmd+T | `toggleRich:` | 1482 | DROP |
| Prevent Editing | | `toggleReadOnly:` | 1491 | KEEP |
| Wrap to Page | Shift+Cmd+W | `togglePageBreaks:` | 1500 | KEEP (hard under TextKit 2, see risk 1) |
| Allow Hyphenation | | `toggleHyphenation:` | 1509 | DROP |
| Make Vertical Layout | | `toggleLayoutOrientation:` | 1517 | DROP |
| List… | | `orderFrontListPanel:` | 1536 | DROP |
| Table… | | `orderFrontTablePanel:` | 1544 | DROP |

With most items gone, Format keeps only Prevent Editing and Wrap to Page. Those two could move to View.

### View (`:1555`)
| Item | Key | Action -> target | Line | Plain text |
| --- | --- | --- | --- | --- |
| Actual Size | Cmd+0 | `zoomToActualSize:` | 1568 | KEEP |
| Zoom In | Shift+Cmd+. (Cmd+>) | `zoomIn:` | 1577 | KEEP |
| Zoom Out | Shift+Cmd+, (Cmd+<) | `zoomOut:` | 1586 | KEEP |

### Window (`_NSWindowsMenu`, `:1598`)
| Item | Key | Action -> target | Line | Plain text |
| --- | --- | --- | --- | --- |
| Minimize | Cmd+M | `performMiniaturize:` | 1614 | KEEP |
| Zoom | | `performZoom:` | 1623 | KEEP |
| Bring All to Front | | `arrangeInFront:` | 1643 | KEEP |

### Help (`:1656`)
| Item | Key | Action -> target | Line | Plain text |
| --- | --- | --- | --- | --- |
| TextEdit Help | Cmd+? | `showHelp:` | 1672 | CHANGE: no help book yet |

zadr's menu (`zadr/English.lproj/Edit.nib/designable.nib`) is the same except: "Export as PDF…" sits right after "Save As…" and calls `saveDocumentAsPDFTo:` (`:283`), and "Attach Files…" is in the File menu (`:319`), not the Edit menu.

Menu titles that code changes at run time: Prevent/Allow Editing and Wrap to Page/Wrap to Window (`Document.m:767-783`), Make Rich/Plain Text and Make Layout Vertical/Horizontal (`DocumentWindowController.m:1029-1054`), Show/Hide Properties (`DocumentPropertiesPanelController.m:143-149`).

---

## 3. User defaults

Registered in `Controller.m:60-103`. Key names in `TextEditDefaultsKeys.h`. The Preferences window binds most of them through `values.<key>` (`Base.lproj/Preferences.nib/designable.nib:2036-2550`).
The window has two tabs: "New Document" (`:1299`) and "Open and Save" (`:1905`).

| Key string (macro) | Type | Default | What it controls | UI | Plain text |
| --- | --- | --- | --- | --- | --- |
| `RichText` (`RichText`) | Bool | YES (`Controller.m:67`) | New docs are RTF or plain (`DocumentController.m:352-354`) | Format radio | DROP: always plain |
| `ShowPageBreaks` | Bool | NO (`:68`) | New docs start in wrap-to-page (`Document.m:121`). Opened plain files always start in wrap-to-window, because the mode comes from RTF attributes (`Document.m:253-258`). | "Wrap to page" checkbox | KEEP if wrap-to-page stays |
| `OpenPanelFollowsMainWindow` | Bool | NO (`:69`) | Nothing. No code reads it. | none | DROP |
| `AddExtensionToNewPlainTextFiles` | Bool | YES (`:70`) | Save panel ".txt" checkbox start state (`Document.m:1273`) | checkbox | KEEP |
| `WidthInChars` (`WindowWidth`) | Int | 90 (`:71`) | New window width in characters (`DocumentWindowController.m:668`) | field, 1-10000 | KEEP |
| `HeightInChars` (`WindowHeight`) | Int | 30 (`:72`) | New window height in lines (`:667`) | field, 1-10000 | KEEP |
| `PlainTextEncoding` (`PlainTextEncodingForRead`) | UInt (NSStringEncoding) | `NoStringEncoding` = Automatic (`:73`) | Open encoding when no Open panel choice (`DocumentController.m:336`); Open panel start value (`:302`) | "Opening files" popup | KEEP |
| `PlainTextEncodingForWrite` | UInt | `NoStringEncoding` (`:74`) | Preferred save encoding for new docs (`Document.m:368-379`) | "Saving files" popup | KEEP |
| `TabWidth` | Int | 8 (`:75`) | Tab stop width in spaces (`Document.m:332`) | none | KEEP (add UI later maybe) |
| `ForegroundLayoutToIndex` | Int | 50000 (`:76`) | Nothing. No code reads it. | none | DROP |
| `IgnoreRichText` | Bool | NO (`:77`) | Open RTF and Word XML as source text (`Document.m:182`, `:217`) | "Display RTF files as RTF code…" | DROP: always on |
| `IgnoreHTML` | Bool | NO (`:78`) | Open HTML as source text | "Display HTML files as HTML code…" | DROP: always on |
| `CheckSpellingWhileTyping` (`CheckSpellingAsYouType`) | Bool | YES (`:79`) | Continuous spell check (`DocumentWindowController.m:190`) | checkbox | KEEP |
| `CheckGrammarWithSpelling` | Bool | NO (`:80`) | Grammar check (`:191`) | checkbox | KEEP |
| `CorrectSpellingAutomatically` | Bool | system setting (`:81`) | Autocorrect (`:192`) | checkbox | KEEP |
| `ShowRuler` | Bool | YES (`:82`) | Ruler for rich docs (`:294`) | checkbox | DROP |
| `SmartCopyPaste` | Bool | YES (`:83`) | Smart insert/delete (`:193`) | checkbox | KEEP |
| `SmartQuotes` | Bool | NO (`:84`) | (`:194`) | checkbox | KEEP |
| `SmartDashes` | Bool | NO (`:85`) | (`:195`) | checkbox | KEEP |
| `SmartLinks` | Bool | NO (`:86`) | Link detection (`:196`) | checkbox | DROP |
| `DataDetectors` | Bool | NO (`:87`) | (`:197`) | checkbox | CHANGE: test first |
| `TextReplacement` | Bool | system setting (`:88`) | (`:198`) | checkbox | KEEP |
| `SubstitutionsEnabledInRichTextOnly` | Bool | NO (`:89`) | If YES, turns off autocorrect, quotes, dashes and replacement in plain docs (`:187-198`) | none | DROP: QuickEdit has no rich mode; use the per-feature keys |
| `author`, `company`, `copyright` | String | "" (`:90-92`) | Default document properties | fields | DROP |
| `UseXHTMLDocType`, `UseTransitionalDocType` | Bool | NO, NO (`:93-94`) | HTML save doctype | popup | DROP |
| `UseEmbeddedCSS`, `UseInlineCSS` | Bool | YES, NO (`:95-96`) | HTML save styling | popup | DROP |
| `HTMLEncoding` | UInt | UTF-8 (`:97`) | HTML save encoding | popup | DROP |
| `PreserveWhitespace` | Bool | YES (`:98`) | HTML save whitespace | checkbox | DROP |
| `UseScreenFonts` | Bool | NO (`:99`) | Screen fonts for new rich docs | none | DROP |
| `AutosavingDelay` | Int (seconds) | 30 (`:64`) | `NSDocumentController.autosavingDelay` via binding (`DocumentController.m:73`) | none | KEEP |
| `NumberPagesWhenPrinting` | Bool | NO (`:65`) | Print header and footer (`PrintPanelAccessoryController.m:68`, `:86`) | Print panel checkbox | KEEP |
| `WrapToFitWhenPrinting` | Bool | YES (`:66`) | Rewrap to page width when printing wrap-to-window docs (`:69`, `:88`) | Print panel checkbox | KEEP |

Keys not in the defaults table:
- `Encodings` (array of NSStringEncoding numbers), read and written by `EncodingManager.m:233`, `:256`, `:323`. KEEP.
- The plain font is stored by AppKit through `+[NSFont setUserFixedPitchFont:]` (`Preferences.m:115`). KEEP.
- `AppleMeasurementUnits` (system, read only) picks rich tab stops (`Document.m:316`). DROP.

Note: the menu toggles for spelling and substitutions change only the current text view. They never write back to defaults. Only the Preferences window changes defaults.

---

## 4. Plain-text open and save, end to end

### 4.1 Open, step by step
1. File > Open runs `-[DocumentController beginOpenPanel:forTypes:completionHandler:]` (`DocumentController.m:296`).
   - It adds the encoding accessory: a "Plain Text Encoding:" popup and a checkbox (`English.lproj/EncodingAccessory.nib`). The popup has "Automatic" first (`includeDefaultEntry:YES`, `:302`).
   - The popup starts at the `PlainTextEncoding` default.
   - The checkbox becomes "Ignore rich text commands" (`:305-306`). It shows a mixed state when the two ignore defaults differ (`:307-313`).
2. On OK, it stores `{encoding, IgnoreHTML, IgnoreRichText}` for every chosen URL in `customOpenSettings` (`:315-328`). A mixed checkbox leaves both values as the defaults had them (`:321-323`).
3. NSDocumentController opens each file, on background threads for plain text (`Document.m:835-838`). Our override `openDocumentWithContentsOfURL:display:error:` (`DocumentController.m:222`) handles the transient window, then removes the URL's settings (`:237`).
4. `-[Document readFromURL:ofType:error:]` (`Document.m:155-158`) asks the controller for the three settings. A file opened by Finder or drag uses the defaults.
5. The full reader `readFromURL:ofType:encoding:ignoreRTF:ignoreHTML:error:` (`Document.m:160-307`):
   - Narrows the type to the most specific readable type (`:167`).
   - Sets `NSBaseURLDocumentOption`. If the encoding is not "Automatic", sets `NSCharacterEncodingDocumentOption` (`:174-177`) and stores it.
   - **Ignore rich text, first check** (`:180-186`): if ignoring RTF and the type is RTF or Word 2003 XML, or ignoring HTML and the type is HTML, or this doc was opened ignoring rich text before (a revert), it forces `NSDocumentTypeDocumentOption = NSPlainTextDocumentType`, sets the type to `public.text`, and sets `openedIgnoringRichText`.
   - Empties the text and detaches all layout managers during the load for speed (`:188-193`).
   - Calls `-[NSTextStorage readFromURL:options:documentAttributes:error:]` (`:204`). On failure, puts the layout managers back and returns NO with AppKit's error (`:206-212`).
   - **Ignore rich text, second check** (`:216-224`): the type check is not always right, so after loading it looks at the document type AppKit reports. If AppKit read HTML, RTF or Word XML that the user wanted ignored, it clears the text, forces plain, and loops once more (`retry`).
   - Otherwise maps the AppKit document type to a UTI (`:225-230`). For plain text it calls `applyDefaultTextAttributes:NO` (`:231`): fixed-pitch font, tab width.
   - Sets the file type and keeps a copy in `fileTypeToSet` so a revert can restore it (`:236-238`). Re-attaches the layout managers (`:240-242`).
   - **Encoding actually used** (`:244-245`): reads `NSCharacterEncodingDocumentAttribute` from the result. This is how "Automatic" learns the real encoding.
   - **Lossy flag** (`:247-250`): if `NSConvertedDocumentAttribute` is below 0, the load lost data; `lossyDocument` is set. Above 0 means "converted by a filter".
   - Plain files have no view mode, so the doc goes to wrap-to-window (`:253-258`). The rest of the attribute reads (`:260-302`) find nothing for plain text.

### 4.2 How encoding detection works
- TextEdit itself has **no** detection code. There is no BOM check and no byte sniffing in either copy. I searched all `.m` files for BOM, `FEFF`, byte order, CR, line endings and xattr; the only hit is a comment at `Document.m:1223`.
- With "Automatic", the `NSCharacterEncodingDocumentOption` key is left out (`Document.m:175`). AppKit's plain-text reader then picks the encoding. From AppKit's behavior (not from this code, and not tested here), it looks at the `com.apple.TextEncoding` extended attribute that TextEdit writes on save, then at a byte order mark, then tries UTF-8, then falls back to a default 8-bit encoding. We must confirm each step with tests before we copy it.
- With a chosen encoding, AppKit decodes with it. If the bytes do not fit, the read fails and NSDocumentController shows its standard "could not be opened" alert with AppKit's error text. TextEdit adds no alert of its own.
- QuickEdit should do this itself: read `Data`, check the xattr, check the BOM, try UTF-8, then use `NSString.stringEncoding(for:encodingOptions:convertedString:usedLossyConversion:)` or the fallback. This makes the behavior testable and keeps TextKit out of the read path.

### 4.3 Line endings
- TextEdit has no line-ending code. CR, LF and CRLF go into the text storage as they are, and they are written back as they are.
- Typing Return calls `insertNewline:`, which adds LF. So editing a CRLF file gives mixed line endings.
- Edit > Insert > Line Break adds U+2028 (`Edit.nib:508`). Insert > Page Break adds a form feed (`:525`).
- `lineRangeForRange:` (used by Select Line, `LinePanelController.m:110`, `:124`, `:130`) treats all of these as line ends, so line counts stay right.
- QuickEdit should detect the main line ending on open, keep it on save, and convert typed Return to it. This is new behavior, not in TextEdit.

### 4.4 Save panel and the encoding accessory
1. NSDocument asks `shouldRunSavePanelWithAccessoryView` (`Document.m:1260`). It returns NO for plain text, so no file-format popup.
2. `prepareSavePanel:` (`Document.m:1266-1321`):
   - Picks the start encoding: the doc's encoding if set and the text fits it, else `suggestedDocumentEncoding` (UTF-8, or `PlainTextEncodingForWrite` if that fits) (`:1276-1277`). Stores it in `encodingForSaving`.
   - Loads the same `EncodingAccessory` view, without "Automatic" (`:1278-1280`).
   - The checkbox becomes "If no extension is provided, use ".txt"." (`:1283-1287`). Its start state is `AddExtensionToNewPlainTextFiles`.
   - Checked: allowed types = `public.plain-text`, other types allowed (`:1288-1290`). Unchecked: no allowed types, so no extension is added; the name field gets the file's current name or the display name (`:1291-1303`).
   - Turns off every popup item whose encoding cannot hold the text (`:1306-1315`). UTF-16, UTF-8 and non-lossy ASCII are never turned off. This check is skipped when items x characters is 5,000,000 or more, because it is slow.
   - Popup changes call `encodingPopupChanged:` (`:743-745`); checkbox changes call `appendPlainTextExtensionChanged:` (`:737-741`).
3. The popup's last item, "Customize Encodings List…", opens the encodings panel even while the Save panel is up (`EncodingManager.m:218-220`, `:271-290`).

### 4.5 Writing the file
1. `saveToURL:ofType:forSaveOperation:completionHandler:` (`Document.m:884-896`): breaks undo grouping, records the operation, calls super, then resets `encodingForSaving` to none.
2. NSDocument calls `fileWrapperOfType:error:` (`Document.m:1143-1237`), on a background thread for plain text (`:900-902`).
   - `public.plain-text` conforms to the type, so `docType = NSPlainTextDocumentType` (`:1171`).
   - Encoding (`:1187-1193`): the doc's encoding; for Save and Save As only, the Save panel's choice wins; if still none, `suggestedDocumentEncoding`. Autosave in place uses the doc's encoding, never the panel's.
   - Normal plain docs use `fileWrapperFromRange:documentAttributes:error:` (`:1223-1224`). The comment says this also writes the encoding into an extended attribute. Docs opened with "ignore rich text" use `dataFromRange:` instead, with no xattr (`:1225-1231`).
   - After a good Save or Save As, the chosen encoding becomes the doc's encoding (`:1232-1234`).
3. `fileNameExtensionForType:` returns `txt` for `public.text` (`:872-876`).
4. AppKit writes the bytes. From AppKit's normal behavior, UTF-16 gets a BOM and UTF-8 does not. TextEdit does not control this. A UTF-8 file that had a BOM loses it on save. QuickEdit should remember and keep the BOM.

### 4.6 Errors and alerts in this path
| When | Code | Title and text | Buttons | Result |
| --- | --- | --- | --- | --- |
| Every edit, if the new text no longer fits the doc's encoding (`Document.m:980-996`, called from `updateChangeCount:` `:998-1047`) | `TextEditSaveErrorEncodingInapplicable` (4) | "This document can no longer be saved using its original %@ encoding." / "Please choose another encoding (such as UTF-8)." (`:961-974`) | OK, Cancel | OK opens the Save panel to pick an encoding (`:1120-1133`). Cancel undoes the edit (`:1015-1023`, `:1032-1037`). |
| Before writing over a file that loaded lossily (`:1250-1252`) | `TextEditSaveErrorLossyDocument` (2) | "Are you sure you want to modify the document in place?" / "…might cause you to lose some of the original formatting…" (`:950-960`) | Duplicate, Cancel, Overwrite | Duplicate copies the doc; Overwrite clears the flag (`:1084-1118`). |
| Before writing, if the file type is not writable, for example a Viewer-only type (`:1244-1246`) | `TextEditSaveErrorWritableTypeRequired` (3) | "Convert this document to RTF format?" (`:906-932`) | Convert, Cancel, Duplicate | Convert sets RTF. QuickEdit must change this to "save as UTF-8 plain text". |
| Converted by a filter (`:1247-1249`) | `TextEditSaveErrorConvertedDocument` (1) | "Are you sure you want to edit this document?" | Edit, Cancel, Duplicate | DROP for QuickEdit. |
| Open fails | AppKit's error | AppKit text | OK | Shown by NSDocumentController. |
| Services fail (`Controller.m:148-153`, `:162-165`) | `NSFileReadInvalidFileNameError` or code 100 | "Service failed. Couldn't open the selection." | OK | Modal alert. |

Two details:
- `updateChangeCount:` runs the check only for done and redone changes (`Document.m:1006`). The "undone" branch inside its blocks (`:1019-1020`, `:1035-1036`) can never run.
- The check is skipped for untitled docs, because they have no file yet (`:983`).

---

## 5. Wrap to window and wrap to page

### 5.1 The pieces
- `Document.hasMultiplePages` is the truth. `togglePageBreaks:` flips it (`Document.m:725-727`).
- `DocumentWindowController` watches it by KVO (`DocumentWindowController.m:230-231`) and calls `setHasMultiplePages:force:` (`:512-615`).
- One `NSLayoutManager` (`layoutMgr`, made in `init` at `:89`) is shared by every text view in the window. The text views share selection, typing attributes and undo through it. This is why the code adds the new container before it removes the old one (`:540-544`, `:572-573`): the shared state lives on while at least one view exists.
- `ScalingScrollView` is the window's scroll view in both modes.
- `MultiplePageView` is the scroll view's document view in wrap-to-page only.

### 5.2 Wrap to window
- One container, `width = scroll content width`, height `CGFLOAT_MAX` (`:568-569`).
- The container width tracks the text view; the text view grows in height and its width follows the window (`:583-589`).
- The text view becomes the scroll view's document view (`:595`).
- Window size comes from `viewSize` if a file stored one (RTF only), else `WidthInChars` x `HeightInChars` measured with the fixed-pitch font's "x" width and default line height (`:656-679`).
- Resizing stores the new text size in `viewSize` (`:884-897`). The `isSettingSize` flag stops a loop with the `viewSize` KVO (`:224`).
- If the system scroller style changes (for example, a mouse is plugged in), the window is resized so the text width stays the same (`:212-219`, `:619-631`).

### 5.3 Wrap to page
- A new `MultiplePageView` gets the doc's print info (`:533-538`).
- `addPage` (`:459-495`) adds one page: a container sized to `documentSizeInPage` (paper minus margins, plus 2 x padding in width; `MultiplePageView.m:297-302`) and a fixed-size text view placed at `documentRectForPageNumber:` (`MultiplePageView.m:134-140`).
- The layout manager delegate (`DocumentWindowController.m:992-1022`) adds a page when the last page fills up. It only does this if the last page really has text (a workaround noted at `:1003`). When layout ends with room to spare, it removes empty pages.
- Page Setup changes reach `printInfoUpdated` (`:264-279`) through KVO on `printInfo`. It resizes every page.
- `MultiplePageView.drawRect:` (`:207-247`) paints white, frames each text area in light gray, and paints the 5 pt gaps in the clip view's background color. It draws only on screen.
- The window's Zoom button sizes the window to one page width (`DocumentWindowController.m:860-882`).
- After switching, the code scrolls to the selection and tries to center the page (`:551-565`).

### 5.4 Zoom
- `ScalingScrollView` uses `NSScrollView` magnification in both modes (`ScalingScrollView.m:55-60`). Range 25% to 1600%.
- Menu steps: Zoom In doubles; Zoom Out halves; values near 50% (zoom in) or 200% (zoom out) snap to 100% (`:80-90`). So menu steps are 25%, 50%, 100%, 200%, 400%, 800%, 1600%.
- Pinch gives any value in the range. Smart magnify (two-finger double tap) in wrap-to-page uses `rectForSmartMagnificationAtPoint:inRect:` (`MultiplePageView.m:251-274`).
- The scroll view's `scaleFactor` is watched (`DocumentWindowController.m:695`) and copied to the doc (`:208-211`).
- The zoom is restored only in wrap-to-page (`:148`, `:694`) and saved only in RTF when wrap-to-page and not 100% (`Document.m:1184`). For plain text, zoom is never saved.
- `ZoomValues.strings` (10%-1600%) is not used.

### 5.5 Printing in each mode (`Document.m:633-677`)
- Wrap to page: prints the `MultiplePageView` itself, after laying out the whole text (`:643-645`). Paper size and orientation are not offered in the Print panel; Page Setup rules.
- Wrap to window: makes a new `PrintingTextView`, takes its layout manager, drops its own text storage, and attaches the layout manager to the doc's text storage (`:646-654`). The Print panel shows paper size and orientation (`:668-673`).
- The accessory shows "Rewrap contents to fit page" only in wrap-to-window (`:665`). If on, `PrintingTextView.knowsPageRange:` sizes the view to the page text width; if off, to the on-screen width (`PrintingTextView.m:63-77`). With fit-to-width pagination (`Document.m:683`), a wide view is scaled down to fit.
- The job title comes from the on-screen view (`:662`).

### 5.6 What changes under TextKit 2
- TextKit 2 gives one `NSTextContainer` per `NSTextLayoutManager`. The "many containers, one layout manager" design cannot be copied.
- Options for wrap-to-page:
  1. Keep wrap-to-page on a TextKit 1 view only (accept compatibility mode in that mode).
  2. One tall TextKit 2 view with page-sized line-fragment breaks, drawing page edges behind it.
  3. Drop wrap-to-page from v1 and keep "rewrap to page" only for printing.
- All glyph calls (`glyphRangeForTextContainer:`, `textContainerForGlyphAtIndex:`, `characterRangeForGlyphRange:`, `defaultLineHeightForFont:`) must go. Any one of them silently switches the view to TextKit 1.

---

## 6. Differences between the apple and zadr copies

Facts first:
- apple: `CURRENT_PROJECT_VERSION = 309` (`apple/Version.xcconfig:1`), short version 1.9, minimum macOS 10.9 (`apple/Info-TextEdit.plist:223`, `:229`). This is the 10.9 Mavericks sample.
- zadr: `CURRENT_PROJECT_VERSION = 301` (`zadr/Version.xcconfig:1`), not 285. Short version 1.8, minimum 10.8 (`zadr/Info-TextEdit.plist:223`, `:229`). Its `README.rtf` has a "Changes in TextEdit 1.8" section. This is the 10.8 Mountain Lion sample.
- Neither copy uses ARC. Both use `retain`, `release`, `autorelease`, `Block_copy` and `Block_release` (for example `zadr/Document.m:402`, `zadr/Document.m:897`). Neither project sets `CLANG_ENABLE_OBJC_ARC`. zadr's git history inside our repo is one import commit, so I cannot see what "warning fixes" were made.
- Auto Save in place, Versions, window restoration and the sandbox note are in **both** copies: `+autosavesInPlace` (`apple/Document.m:831`, `zadr/Document.m:839`), restoration (`apple/DocumentWindowController.m:619-637`, `zadr/DocumentWindowController.m:619-637`), sandbox comment (`apple/Document.m:546`, `zadr/Document.m:551`). These came in TextEdit 1.7 (Lion).
- Neither copy has an entitlements file. The sandbox setup is not in the sample.

What changed from zadr (1.8) to apple (1.9), and why it matters:

| Area | zadr (1.8) | apple (1.9) | Matters for QuickEdit because |
| --- | --- | --- | --- |
| Save thread safety | `NSLock` around the save and `currentSaveOperation` (`zadr/Document.m:895-901`) | `performAsynchronousFileAccessUsingBlock:` around the super call (`apple/Document.m:887-894`) | Apple's version follows NSDocument's file-access rules. Copy the apple pattern. |
| Rich toggle flow | Alert first, then autosave, through `NSBeginAlertSheet` (`zadr/DocumentWindowController.m:787-822`) | Whole flow inside `performActivityWithSynchronousWaiting`, reads the doc inside `performSynchronousFileAccessUsingBlock`, saves through `CFRunLoopPerformBlock` to dodge an NSDocument bug (`apple/DocumentWindowController.m:776-785`, `:793-831`) | Dropped, but the bug note shows how fragile nested NSDocument file access is. |
| Export as PDF | Custom `saveDocumentAsPDFTo:` via a print job (`zadr/Document.m:818-821`) | Built-in `saveDocumentToPDF:` (`apple/Base.lproj/Edit.nib/designable.nib:315`) | Use the built-in action. |
| Nib loading | `+[NSBundle loadNibNamed:owner:]` (`zadr/DocumentController.m:284`, `zadr/EncodingManager.m:280`) | `-loadNibNamed:owner:topLevelObjects:` plus a manual retain (`apple/EncodingManager.m:280-284`) | Both are replaced by code-built views. |
| Accessory views | Plain `setAccessoryView:` | Sets `translatesAutoresizingMaskIntoConstraints = NO` first (`apple/DocumentController.m:302-304`, `apple/Document.m:1278-1280`) | Auto Layout accessories need this. |
| Print accessory | Bindings to `values.NumberPagesWhenPrinting` and target-action (`zadr/PrintPanelAccessoryController.m:81-88`) | KVO on itself writes defaults; each panel keeps its own values (`apple/PrintPanelAccessoryController.m:65-92`) | Apple's way stops two open Print panels from fighting. |
| Plain tab width | Uses screen font metrics only when `usesScreenFonts` (`zadr/Document.m:332-338`) | Always uses screen font metrics (`apple/Document.m:331-334`) | Both use a deprecated call; QuickEdit measures with the real font. |
| Doc property map | Not thread safe `if (!dict)` (`zadr/Document.m:567-574`) | `dispatch_once` (`apple/Document.m:562-572`) | Dropped. |
| Leak | Never releases `company` (`zadr/Document.m:393-402`) | Fixed (`apple/Document.m:393`) | None after port. |
| Localization | `English.lproj` nibs | `Base.lproj` nibs (Base Internationalization) | Use String Catalogs. |
| Icons | `.icns` files | `.iconset` folders | Make a new icon. |
| Menu layout | "Attach Files…" in File | "Attach Files…" in Edit | Dropped. |
| Document Properties nib | no "Title:" label difference | adds a "Title:" label | Dropped. |

---

## 7. Deprecated or removed APIs

"Apple" line numbers unless noted. "Deprecated" means the SDK marks it deprecated; I give the macOS version only where I am sure.

| API | Call sites | Modern replacement |
| --- | --- | --- |
| `kUTType*` constants (deprecated macOS 12) | `Controller.m:132`; `DocumentController.m:103-107`, `:130`, `:353`; `Document.m:77`, `:138-147`, `:184`, `:221`, `:229`, `:547`, `:740`, `:837`, `:856-862`, `:874`, `:1012`, `:1052`, `:1114`, `:1171-1180`, `:1289`; `DocumentWindowController.m:755`, `:773` | `UTType.plainText`, `UTType.text` (UniformTypeIdentifiers) |
| `UTTypeConformsTo` (deprecated macOS 12) | `Document.m:91`, `:92`, `:98` | `UTType.conforms(to:)` |
| `-[NSWorkspace type:conformsToType:]` (deprecated macOS 11) | `Document.m:182`, `:837`, `:1171-1180`; `DocumentWindowController.m:930` | `UTType.conforms(to:)` |
| `-[NSSavePanel setAllowedFileTypes:]` (deprecated macOS 12) | `Document.m:740`, `:1289`, `:1294` | `allowedContentTypes` |
| `NSOKButton` (deprecated) | `DocumentController.m:316` | `NSApplication.ModalResponse.OK` |
| `NSFileHandlingPanelOKButton` (deprecated) | `DocumentWindowController.m:339` | `.OK` |
| `+[NSAlert alertWithMessageText:defaultButton:...]` (deprecated 10.10) | `DocumentWindowController.m:818` | `NSAlert()` + `addButton(withTitle:)` |
| `-[NSAlert beginSheetModalForWindow:modalDelegate:didEndSelector:contextInfo:]` (deprecated 10.10) | `DocumentWindowController.m:819` | `beginSheetModal(for:completionHandler:)` |
| `NSAlertDefaultReturn` (deprecated 10.10) | `DocumentWindowController.m:834`; `zadr/DocumentWindowController.m:820` | `.alertFirstButtonReturn` |
| `NSBeginAlertSheet` (deprecated 10.10) | `zadr/DocumentWindowController.m:806` | `NSAlert.beginSheetModal` |
| `+[NSBundle loadNibNamed:owner:]` (deprecated 10.8) | `zadr/DocumentController.m:284`, `zadr/EncodingManager.m:280` | Build views in code |
| `-[NSMenuItem setTitleWithMnemonic:]` (deprecated; macOS has no mnemonics) | `Document.m:754`, `:759` | `title` |
| `allocWithZone:` / `[self zone]` / `copyWithZone:[self zone]` (zones ignored) | `Document.m:107`, `:845`; `DocumentWindowController.m:89`, `:460-480`, `:514-570`; `MultiplePageView.m:94`, `:174`, `:186` | Plain `init` / `copy()` |
| `NSFilenamesPboardType` (deprecated 10.14) | `DocumentWindowController.m:973`, `:979`, `:983` | `.fileURL` (code is dropped anyway) |
| `-[NSFont screenFontWithRenderingMode:]` (deprecated 10.15) | `Document.m:331`; `DocumentWindowController.m:669` | Use the font as is |
| `-[NSLayoutManager setUsesScreenFonts:]` and `NSUsesScreenFontsDocumentAttribute` (deprecated) | `DocumentWindowController.m:246`, `:401`; `Document.m:302`, `:1157` | Remove |
| `+[NSScrollView contentSizeForFrameSize:hasHorizontalScroller:hasVerticalScroller:borderType:]` (deprecated 10.7) | `DocumentWindowController.m:889` | `contentSize(forFrameSize:horizontalScrollerClass:verticalScrollerClass:borderType:controlSize:scrollerStyle:)` |
| `NSRegularControlSize` (renamed) | `DocumentWindowController.m:626`, `:650`, `:871` | `.regular` |
| `NSOnState` / `NSOffState` / `NSMixedState` (renamed) | `DocumentController.m:309-322`; `EncodingManager.m:262`, `:299` | `NSControl.StateValue.on/.off/.mixed` |
| `NSMatrix` (legacy, discouraged) | `EncodingManager.h:70`; `EncodingManager.m:164-180`, `:255-306` | `NSTableView` or `NSStackView` of checkboxes |
| `prepareWithInvocationTarget:` (no `NSInvocation` in Swift) | `Document.m:606`, `:731` | `registerUndo(withTarget:handler:)` |
| `registerUndoWithTarget:selector:object:` | `Document.m:697`, `:789`; `DocumentWindowController.m:757` | `registerUndo(withTarget:handler:)` |
| `Block_copy` / `Block_release` as `contextInfo` | `Document.m:1031`, `:1071`, `:1076`, `:1101`, `:1127`; `DocumentWindowController.m:329`, `:378`, `:819`, `:835`, `:919` | Swift closures; completion-handler APIs |
| Cast `objc_msgSend` to call `didRecoverSelector` | `Document.m:1103`, `:1129`, `:1138` | Swift: `method(for:)` + `unsafeBitCast` to a `@convention(c)` type, or avoid sheet recovery (risk 5) |
| `presentError:modalForWindow:delegate:didPresentSelector:contextInfo:` and `runModalSavePanelForSaveOperation:delegate:didSaveSelector:contextInfo:` (selector style, still there) | `Document.m:1027`, `:1097`, `:1124`; `DocumentWindowController.m:378`, `:919` | Same APIs with Swift selectors, or `NSAlert` sheets with closures |
| `performSelectorOnMainThread:withObject:waitUntilDone:` | `DocumentController.m:184`, `:216` | `MainActor` / `DispatchQueue.main` |
| `NSLock` around shared state | `DocumentController.m:75-76`, `:117-123`, `:225-232`, `:246-262`; `zadr/Document.m:115`, `:895-901` | Swift actors or `Mutex` / `OSAllocatedUnfairLock` |
| TextKit 1 glyph and container APIs (not deprecated, but they force TextKit 1 on a TextKit 2 view) | `DocumentWindowController.m:89-91`, `:166-171`, `:268-276`, `:443-445`, `:459-506`, `:543`, `:569-579`, `:671`, `:707-728`, `:992-1022`, `:1095-1098`; `Document.m:190-193`, `:240-242`, `:645-654`; `DocumentController.m:208-213`; `PrintingTextView.m:73` | `NSTextLayoutManager`, `NSTextContentStorage`, `ensureLayout(for:)`, `enumerateTextLayoutFragments`; one view per layout manager |
| `-[NSMutableAttributedString readFromURL:options:documentAttributes:error:]` for plain text (works, but hides decoding) | `Document.m:204` | Read `Data`; decode with `String(data:encoding:)` and `NSString.stringEncoding(for:...)` |
| `fileWrapperFromRange:` / `dataFromRange:` for plain text | `Document.m:1224`, `:1226` | `String.data(using:)` plus our own xattr write |
| `NoStringEncoding = 0xFFFFFFFF` sentinel and the 64-bit cleanup | `EncodingManager.h:53-55`; `Controller.m:113-118` | `String.Encoding?` (nil = Automatic) |
| `.scriptSuite` / `.scriptTerminology` scripting files (old format) | `TextEdit.scriptSuite`, `TextEdit.scriptTerminology` | `.sdef` file |
| `HEADER_SEARCH_PATHS` into `Carbon.framework` | `TextEdit.xcodeproj/project.pbxproj:539`, `:578` | Remove |
| Old IB 3 archive nibs (`designable.nib`) | all `.nib` folders | Build windows and menus in code, or new `.xib` files |

---

## 8. The 10 riskiest parts to port

1. **Wrap to page on TextKit 2.** TextEdit puts many page containers on one shared `NSLayoutManager` (`DocumentWindowController.m:459-506`, `:992-1022`). TextKit 2 has one container per layout manager. There is no direct port; we must pick one of the three options in section 5.6.
2. **Silent fallback to TextKit 1.** About 30 call sites touch `layoutManager` or glyphs (section 7). Each one switches the view to TextKit 1 with no error. We need a check (a test or a debug assertion) that the view still uses TextKit 2.
3. **Printing.** Wrap-to-window printing borrows a TextKit 1 layout manager and re-attaches it to the doc's text storage (`Document.m:646-654`). Rewrap-to-fit relayouts on every Print panel change (`PrintingTextView.m:63-77`). Paged printing of a TextKit 2 view needs to be proven early.
4. **Encoding detection on open.** All of it happens inside AppKit (`Document.m:175`, `:204`, `:244-245`). If we write our own, we must match what users expect: xattr, BOM, UTF-8, fallback, and the lossy flag (`:247-250`). Wrong guesses corrupt files on save.
5. **The "encoding no longer fits" flow.** It runs on every edit (`Document.m:998-1047`), shows a sheet, and either opens the Save panel or undoes the edit. The recovery code calls a delegate selector through `objc_msgSend` with a `BOOL` and a raw pointer (`:1079-1139`). That is awkward in Swift and easy to get wrong.
6. **Save encoding state and threads.** `encoding`, `encodingForSaving` and `currentSaveOperation` are shared between the Save panel, autosave, and a background write (`Document.m:884-902`, `:1187-1193`, `:1232-1234`). The two copies solve the race in two different ways. Swift 6 strict concurrency will flag all of it.
7. **Transient document swap with concurrent opening.** Two locks, deferred display, Apple Event checks and main-thread hops (`DocumentController.m:153-266`). `customOpenSettings` is a plain dictionary read and changed from several threads (`:237`, `:334-347`). Modern macOS may also show the Open panel at launch instead of an untitled window.
8. **Sandbox.** No entitlements in either copy. The "Open Selected File" service opens any typed path (`Controller.m:128-155`), which the sandbox blocks. Writing the encoding xattr, Versions and Auto Save all need checking under the sandbox.
9. **UI files cannot be reused.** Every nib is the old IB 3 archive format. The menu (132 items plus 24 separators), Preferences (2 tabs, 28 bindings), encoding accessory, Select Line panel, encodings panel and print accessory must be rebuilt. Menu titles that flip at run time (`Document.m:751-783`) and window restoration of three panels must be redone by hand.
10. **Line endings and BOM round trip.** TextEdit keeps CR/LF/CRLF as is but inserts LF on Return, giving mixed endings (section 4.3). It also drops a UTF-8 BOM on save (section 4.5). QuickEdit should keep both, which is new code with no reference to copy. Window sizing in characters and the scroller-style resize (`DocumentWindowController.m:619-679`, `:884-897`) are a close 11th.
