# Parity with TextEdit (plain text)

Each row is one behavior QuickEdit must match or deliberately change. Status is one of: "same (tests)", "better (why; tests)", or "left out on purpose (decision or reason)"; "NEEDS TEST" or "GAP" marks a row that still needs work. "Ref" points at `docs/codemap.md` or the old source. The M10 sweep checks every row against the system TextEdit on macOS 27.

## M1: open, edit, save
| ID | Behavior | Ref | Status |
| --- | --- | --- | --- |
| P1 | File > New opens an empty plain-text window (Cmd+N). | menu File | same (OpenTypeSaveTests/testNewDocumentSaveAs, MainMenuTests/testMenuBar) |
| P2 | File > Open (Cmd+O) opens .txt and any `public.plain-text` file. | codemap 4.1 | same (OpenTypeSaveTests/testOpenPanelOpensFile, M2ReviewFixTests/testJSONHTMLAndExtensionlessFilesOpenAsPlainText, ReviewFixTests/testMarkdownFileOpensAsPlainTextAndSaves) |
| P3 | Typing, Save (Cmd+S) writes UTF-8; bytes on disk equal the text. | codemap 4.5 | same (DocumentFileTests/testReadChangeWriteBytes, DocumentFileTests/testNewDocumentSavesUTF8WithoutBOM, OpenTypeSaveTests/testOpenTypeSaveExistingFile) |
| P4 | Untitled docs save via a Save panel with "If no extension is provided, use .txt" (default on). | codemap 4.4 | same (ReviewFixTests/testExtensionCheckboxKeepsTypedNameAndMatchesTextEdit, PlainTextExtensionPanelTests/testBareNameGetsTxtOnlyWhenTheBoxIsOn, OpenTypeSaveTests/testSavePanelExtensionCheckboxOnAddsTxt, OpenTypeSaveTests/testSavePanelExtensionCheckboxOffAddsNothing); small known difference in POST_MVP.md: a name like `notes.v2` gets no .txt |
| P5 | Close (Cmd+W) on a dirty doc asks to save; Quit (Cmd+Q) keeps autosaved docs. | NSDocument | same (DocumentLifeTests/testClosingAnEditedUntitledDocumentAsksAndDeleteCloses, DocumentLifeTests/testClosingANamedEditedDocumentSavesWithoutAsking, OpenTypeSaveTests/testSaveBoundaryUndoAndQuitKeepsEdits); as in TextEdit with autosave, only an untitled document asks |
| P6 | New windows are 90 characters x 30 lines of the plain font. | defaults WidthInChars/HeightInChars | same (ReviewFixTests/testNewWindowShowsThirtyLinesAndNinetyColumns, MainMenuTests/testRenderUntitledWindow) |
| P7 | Plain font is the user fixed-pitch font; tab stops every 8 spaces. | Document.m:331 | same (SettingsTests/testPlainTextFontIsStoredAsTheUserFixedPitchFont, DocumentFileTests/testWindowControllerUsesDocumentStorageAndPlainFont) |
| P8 | Undo and Redo (Cmd+Z, Shift+Cmd+Z); Cut, Copy, Paste, Delete, Select All. | menu Edit | same (EditActionsTests/testCutCopyPasteDeleteUndoRedoChangeTextPasteboardAndUndoState, MainMenuTests/testEditMenuTreeMatchesCodemap, FindAndLineTests/testCopyPasteUndoRedoCutInTheKeyWindow) |

## M2: document life
| ID | Behavior | Ref | Status |
| --- | --- | --- | --- |
| P10 | Autosave in place; edits survive a quit with no prompt. | Document.m:831 | same (DocumentFileTests/testAsyncWritingIsOnAndBytesExact, DocumentLifeTests/testClosingANamedEditedDocumentSavesWithoutAsking, OpenTypeSaveTests/testSaveBoundaryUndoAndQuitKeepsEdits) |
| P11 | File > Duplicate (Shift+Cmd+S), Rename…, Move To…, Revert To > Last Saved / Browse All Versions. | codemap menu File | same (MainMenuTests/testFileMenuItemsInOrder, ShortcutTests/testSaveAsStaysAnAlternateOnlyWhileItPairsWithDuplicate, DocumentLifeTests/testDuplicateRenameAndMoveTo, DocumentLifeTests/testRevertToLastSaved, SandboxTests/testSavingKeepsAnOlderVersion); Save As is the Option alternate of Duplicate; Browse All Versions is proven only by the kept versions, no test opens it |
| P12 | Save All. | menu File | same (MainMenuTests/testFileMenuItemsInOrder); kept, as in TextEdit 1.9; the item goes to AppKit's `saveAllDocuments:`, no test runs it |
| P13 | Open Recent and Clear Menu. | menu File | same (MainMenuTests/testOpenRecentFillsFromRecentDocuments, MainMenuTests/testRealFileMenuHasOneOpenRecent, WindowsAndMenusTests/testOpenRecentListsAnOpenedFile) |
| P14 | Locked file: edits prompt "Unlock" or "Duplicate". | NSDocument | same (DocumentLifeTests/testLockedFileOffersDuplicateAndKeepsBytes) |
| P15 | File changed by another app: reloads when clean, warns when dirty. | NSDocument | same (DocumentLifeTests/testFileChangedByAnotherAppReloadsWhenNotEdited, DocumentLifeTests/testFileChangedByAnotherAppIsNotReloadedOverAnEdit, M2ReviewFixTests/testDateOnlyChangeDoesNotReloadAndKeepsUndo, ExternalChangeTests/testCleanDocumentReloads, ExternalChangeTests/testEditedDocumentShowsConflictOnSave); reloads about 3 s after the write (macOS notice delay) and compares content, not dates |
| P16 | Windows, selection and scroll position restored after relaunch. | DocumentWindowController.m:619-637 | better (also restores the selection and first visible line; TextEdit 1.9 restores only the scroller style; DocumentLifeTests/testSelectionAndScrollAreRestored, M2ReviewFixTests/testRestoredScrollPutsTheSavedLineAtTheTop, RestorationTests/testRelaunchRestoresFileAndSelection) |
| P17 | Opening a file from an empty untitled window replaces that window (transient document). | DocumentController.m:153-266 | same (DocumentLifeTests/testOpeningAFileReplacesTheTransientWindowInPlace, DocumentLifeTests/testEditedUntitledWindowIsNotReplaced, TransientWindowTests/testOpenReplacesTheLaunchWindowInPlace, TransientWindowTests/testTypedUntitledWindowIsKept) |
| P18 | Export as PDF… | Edit.nib:315 | better (U1: the PDF Save panel also has the two print options, and QuickEdit draws the PDF itself, so the print system is never asked; PrintTests/testPrintAndExportGiveTheSamePages, PrintTests/testWritingAPDFNeverTouchesNSPrintInfo, PDFOutputUITests/testExportAsPDFMenuItem) |

## M3: encodings and line endings
| ID | Behavior | Ref | Status |
| --- | --- | --- | --- |
| P20 | Open panel shows "Plain Text Encoding" with Automatic first; start value from settings. | codemap 4.1 | same (EncodingDocumentTests/testOpenPopUpHasAutomaticFirstThenTextEditsList, EncodingDocumentTests/testOpenPanelStartsAtThePlainTextEncodingDefault, EncodingPanelTests/testOpenPanelEncodingChoiceAppliesToTheFile) |
| P21 | Automatic order: `com.apple.TextEncoding` xattr, BOM, UTF-8, then the system default C-string encoding (Mac Roman here); no guessing. | codemap 4.2, vote V2 | same (EncodingTests/testEveryFixtureMatchesTheOracleAndRoundTrips, EncodingTests/testNonUTF8BytesUseTheSystemEncodingWithNoGuess, EncodingTests/testStaleAttributeRefusesTheFile, M6EncodingTests/testRow2MalformedBOMFilesReadAsAppKitReadsThem) |
| P22 | A chosen encoding that does not fit shows "could not be opened". | codemap 4.2 | same (EncodingTests/testOpenWithAChosenEncodingThatDoesNotFitShowsAppKitsError, EncodingTests/testFailedOpenThroughTheControllerLeavesNoDocument) |
| P23 | Save panel encoding popup; encodings that cannot hold the text are disabled. | codemap 4.4 | same (EncodingDocumentTests/testSavePanelDisablesEncodingsThatCannotHoldTheText, EncodingPanelTests/testSavePanelEncodingChangeWritesThatEncoding) |
| P24 | Save writes the `com.apple.TextEncoding` xattr. | codemap 4.5 | same (EncodingDocumentTests/testSaveWritesTheTextEncodingAttribute, EncodingTests/testAttributeValueMatchesAppKit) |
| P25 | Editing into a character the encoding cannot hold shows "can no longer be saved using its original … encoding"; OK opens Save panel, Cancel undoes. | codemap 4.6 | same (EncodingDocumentTests/testCancelUndoesOnlyTheEditThatDidNotFit, EncodingDocumentTests/testOKOpensTheSavePanelAndASaveKeepsTheEdit, EncodingDocumentTests/testRealAlertTextsMatchTextEdit, EncodingPanelTests/testEncodingNoLongerFitsSheetCancelUndoes) |
| P26 | Lossy-loaded file warns before overwrite (Duplicate / Cancel / Overwrite). | codemap 4.6 | same (EncodingDocumentTests/testFirstEditOfALossyFileAsksAndCancelUndoes, EncodingDocumentTests/testOverwriteLetsTheFileBeWritten, EncodingDocumentTests/testDuplicateMakesACopyAndLeavesTheFileAlone, EncodingDocumentTests/testRealAlertTextsMatchTextEdit) |
| P27 | CR, LF and CRLF kept as found. | codemap 4.3 | better (Return types the file's own line ending; TextEdit types LF; EncodingDocumentTests/testReturnTypesTheDocumentsLineEnding, DocumentFileTests/testCRLFFileSaveKeepsCRLF, PlainTextIOTests/testMixedEndingsKeptAsFound, EncodingPanelTests/testReturnInACRLFFileKeepsCRLF) |
| P28 | UTF-8 BOM kept on save. | codemap 4.5 | better (TextEdit drops the BOM; DocumentFileTests/testBOMFileSaveKeepsBOM, PlainTextIOTests/testUTF8WithBOMKeepsBOM) |
| P29 | Customize Encodings List… panel. | EncodingManager.m:271 | same (EncodingDocumentTests/testCustomizePanelIsBuiltInCodeWithACheckboxPerEncoding, EncodingDocumentTests/testListChangeRefillsPopUpsAndRevertRestoresTheDefault) |

## M4: find and editing tools
| ID | Behavior | Ref | Status |
| --- | --- | --- | --- |
| P30 | Find bar (Cmd+F), Find and Replace (Opt+Cmd+F), Find Next/Previous (Cmd+G / Shift+Cmd+G), Use Selection for Find (Cmd+E), Jump to Selection (Cmd+J). | menu Edit > Find | same (MainMenuTests/testEditMenuTreeMatchesCodemap, EditActionsTests/testFindShowsTheFindBarOfTheDocumentWindow, EditActionsTests/testJumpToSelectionScrollsTheSelectionIntoView, FindAndLineTests/testTypingInFindBarFindsAMatch, FindAndLineTests/testUseSelectionThenFindNextAndWrap, FindAndLineTests/testFindPreviousAndWrap, FindAndLineTests/testReplaceAllIgnoringCase) |
| P31 | Select Line… (Cmd+L) panel: a line number or range. | LinePanelController | same (LinePanelTests/testParseAcceptsTextEditForms, LinePanelTests/testRelativeForms, LinePanelTests/testErrorsUseTextEditMessages, FindAndLineTests/testSelectLineSelectsTheLine, FindAndLineTests/testSelectLineRejectsBadEntry); one difference: QuickEdit also beeps on a bad entry (LinePanelController.swift:139), TextEdit does not |
| P32 | Spelling and Grammar submenu, check while typing (default on), grammar (off), autocorrect (system). | menu Edit | same (TextEditDefaultsTests/testSpellingAndGrammarMatchTextEdit, TextEditDefaultsTests/testRegisterPutsTheValuesInAnEmptyStore, MainMenuTests/testEditMenuTreeMatchesCodemap, EditActionsTests/testEachToggleFlipsItsTextViewFlag, EditActionsTests/testCheckDocumentNowSelectsTheFirstMisspelling); values checked against reference/apple/Controller.m:79-81 |
| P33 | Substitutions: Smart Copy/Paste (on), Smart Quotes (off), Smart Dashes (off), Text Replacement (system), Data Detectors (test). | menu Edit | same (TextEditDefaultsTests/testSubstitutionsMatchTextEdit, TextEditDefaultsTests/testRegisterPutsTheValuesInAnEmptyStore, EditActionsTests/testEachToggleFlipsItsTextViewFlag, EditActionsTests/testDataDetectorsMarksTextWithoutChangingIt); values checked against reference/apple/Controller.m:83-88 (Data Detectors off, as in TextEdit) |
| P34 | Transformations: Upper, Lower, Capitalize. | menu Edit | same (EditActionsTests/testTransformationsChangeTheSelectedText) |
| P35 | Speech: Start and Stop Speaking. | menu Edit | same (EditActionsTests/testStartAndStopSpeakingDriveTheSpeechSynthesizer); flaky in full runs, listed in POST_MVP.md |
| P36 | Complete (Opt+Esc). | menu Edit | same (EditActionsTests/testCompleteAsksForCompletionsOfTheWordBeforeTheCaret) |
| P37 | Prevent Editing toggle. | menu Format | same (EditActionsTests/testPreventEditingMakesTheViewReadOnlyAndBack, PageModeTests/testPreventEditingCoversEveryPage) |

## M5: layout and view
| ID | Behavior | Ref | Status |
| --- | --- | --- | --- |
| P40 | Wrap to Page / Wrap to Window (Shift+Cmd+W), menu title flips. | codemap 5 | same (PageModeTests/testMenuItemAndTitleFlip, PageModeTests/testToggleKeepsTextSelectionUndoAndEditedState, LayoutTests/testWrapToPageAddsPagesAndZooms) |
| P41 | Wrap to Page draws white pages with gray frames and gaps; pages follow Page Setup. | codemap 5.3 | same (PageModeTests/testPageGeometry, PageModeTests/testPagesAreAddedAsLayoutReachesThemAndRemovedWhenEmpty, PaperSizeTests/testWrapToPageUsesTheSetting, LayoutTests/testDarkModeKeepsTextReadable; gray frames seen only in the PageModeTests/testRenderBothModesAtThreeScales images); pages follow Settings > Paper size, not Page Setup (U1) |
| P42 | Zoom: Actual Size (Cmd+0), Zoom In (Cmd+>), Zoom Out (Cmd+<), steps 25%-1600%, pinch. | codemap 5.4 | same (ZoomTests/testViewMenuItems, ZoomTests/testScrollViewLimits, ZoomTests/testMenuStepsUpToTheLimitAndBackDown, ZoomTests/testMenuStepsFromAPinchedValue, LayoutTests/testWrapToPageAddsPagesAndZooms) |
| P43 | Full screen, window tabs, dark mode. | system | same (LayoutTests/testFullScreenOnAndOff, LayoutTests/testMergeAllWindowsMakesTabs, LayoutTests/testDarkModeKeepsTextReadable, PageModeTests/testWindowsTabAutomatically) |
| P44 | Window keeps text width when the scroller style changes. | DocumentWindowController.m:619 | same (PageModeTests/testScrollerStyleChangeKeepsTextWidth) |

## M6: settings
| ID | Behavior | Ref | Status |
| --- | --- | --- | --- |
| P50 | Settings window (Cmd+,): New Document tab (size, font, wrap to page, spelling and substitution defaults). | codemap 3 | same (SettingsTests/testWindowHasTextEditsTwoTabsAndPlainControls, SettingsTests/testEveryCheckboxWritesItsDefault, SettingsTests/testSizeFieldsWriteTheirDefaults, SettingsTests/testRenderTabs); TextEdit's tabs minus rich-text controls, plus Paper size (M7) and a Keyboard tab (U2) |
| P51 | Open and Save tab: encodings for open and save, add .txt. (Autosave delay has no UI in TextEdit.) | codemap 3 | same (SettingsTests/testEncodingPopUpsWriteTheirDefaults, SettingsTests/testWindowHasTextEditsTwoTabsAndPlainControls) |
| P52 | Settings survive relaunch and apply to the next new window only. | codemap 3 note | same (SettingsTests/testEveryCheckboxWritesItsDefault, SettingsApplyTests/testWidthAndFontApplyToTheNextWindowOnly, SettingsApplyTests/testHeightAppliesToTheNextWindowOnly, SettingsApplyTests/testSpellingAndSubstitutionsApplyToTheNextWindowOnly, SettingsApplyTests/testWrapToPageAppliesToTheNextNewWindowOnly); like TextEdit, toggling Wrap to Page or reverting an open window picks up a new font for new typing |

## M7: printing and PDF
| ID | Behavior | Ref | Status |
| --- | --- | --- | --- |
| P60 | Print (Cmd+P) with "Print header and footer" (off) and "Rewrap contents to fit page" (on, wrap-to-window only). | codemap 5.5 | left out on purpose (U1: no Print panel and no printer; Cmd+P saves a PDF instead, with both options and TextEdit's defaults in its Save panel; PrintAccessoryTests/testDefaultsAreHeaderOffAndRewrapOn, PrintAccessoryTests/testSavePanelShowsBothOptionsInWrapToWindow, PrintTests/testTextStartsAtTheOneInchMargins, PrintTests/testPrintRequestFromOutsideOpensThePDFPanel, PDFOutputUITests/testCommandPSavesAPDFWithoutThePrintPanel) |
| P61 | Page Setup (Shift+Cmd+P). | menu File | left out on purpose (U1: Page Setup made the print helper search the local network; the paper size moved to Settings; MainMenuTests/testMenuBarHasNoPageSetupOrPrintItems) |
| P62 | Export as PDF matches Print output. | codemap 6 | same (PrintTests/testPrintAndExportGiveTheSamePages) |

## M9: system parts
| ID | Behavior | Ref | Status |
| --- | --- | --- | --- |
| P70 | AppleScript: open, get/set text, save, close. | TextEdit.scriptSuite | left out on purpose (U3: no AppleScript) |
| P71 | Services menu works with the selection. | Controller.m:128 | same (SystemPartsTests/testServicesSendAndReceivePlainText); the system Services menu works; QuickEdit's own Services are left out (U3) |
| P72 | Drag a file onto the Dock icon or window opens it. | system | same (SystemPartsTests/testFileDroppedOnTheWindowOpens, SystemPartsTests/testOpenDocumentsEventLikeTheDocksOpensTheFile) |
| P73 | Share menu, Writing Tools, VoiceOver reads the text. | system | same (SystemPartsTests/testShareIsOffUntilTheDocumentHasAFile, SandboxTests/testShareOffersServicesForASavedFile, SystemPartsTests/testWritingToolsGivePlainTextAndAreOffForAFileTooLargeToEdit, AccessibilityAuditTests/testDocumentWindowHasNoAuditIssues); VoiceOver is checked by the accessibility audit only (U8), no test listens to VoiceOver |

## Left out on purpose
Rich text and everything in the Format > Font and Format > Text menus; Make Rich Text; Show Properties; Attach Files; Link; Insert submenu; Smart Links; Hyphenation; Vertical Layout; Lists; Tables; RTF, RTFD, HTML, Word and ODT. Reason: user decision 1 (plain text only).
