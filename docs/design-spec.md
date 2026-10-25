# QuickEdit design spec (Doc B)

For builders. Exact values live here. Read `docs/research.md` (speed rules) and `docs/codemap.md` (the old code) before changing anything. Report every departure from this file; root updates it in the same commit as the code.

## 1. Platform and engine
- macOS deployment target 27.0, Apple silicon only (`arm64`). Xcode 27.1, Swift 6.4, Swift 6 language mode, strict concurrency complete.
- AppKit only. No SwiftUI, no third-party packages.
- Text engine: **TextKit 1** (`NSLayoutManager`, `NSTextContainer`, `NSTextStorage`) with `allowsNonContiguousLayout = true` on every layout manager (decision V1 in `docs/decisions.md`). Create text views with `NSTextView(frame:textContainer:)` built from an explicit `NSTextStorage` -> `NSLayoutManager` -> `NSTextContainer` chain, never `NSTextView(frame:)` alone (that makes a TextKit 2 view).
- Bundle ID `dev.yili.QuickEdit`. Product name `QuickEdit`. Version from `project.yml` (`MARKETING_VERSION` 0.<milestone>.0, `CURRENT_PROJECT_VERSION` = commit count).
- App Sandbox: **off until M9** (tests and timing open files anywhere; M9 turns it on with `com.apple.security.files.user-selected.read-write` and re-runs every test). Hardened runtime: on.

## 2. Repo layout
```
project.yml                 XcodeGen spec (the .xcodeproj is generated, never committed)
build.sh                    the one entry point (section 4)
QuickEdit/
  App/        main.swift, AppDelegate.swift, MainMenu.swift, LaunchStamp.swift
  Document/   TextDocument.swift, DocumentController.swift, PlainTextIO.swift
  Window/     DocumentWindowController.swift, TextViewFactory.swift
  Support/    Defaults.swift (every user default key and its registered value)
  Resources/  Info.plist, QuickEdit.entitlements, Assets.xcassets
QuickEditTests/             XCTest unit and file tests (hosted by the app)
QuickEditUITests/           XCUITest end-to-end tests
bench/                      launchbench.swift, run-bench.sh, make-fixtures.sh, fixtures/ (generated, ignored)
reference/                  old sources, read only; build-reference.sh builds them (section 6)
docs/                       plans, state, research, this file
builds/                     milestone zips (ignored by Git; listed in docs/STATE.md)
```
Menus and windows are built in code. No nibs, no storyboards, no `.xib`.

## 3. Modules and their contracts
| Contract id | Owner file | Shape |
| --- | --- | --- |
| `io-plain` | `Document/PlainTextIO.swift` | `enum PlainTextIO { static func decode(_ data: Data) throws -> DecodedText; static func encode(_ text: String, as: DecodedText.Format) throws -> Data }` with `struct DecodedText { var text: String; var format: Format }` and `struct Format: Equatable { var encoding: String.Encoding; var hasBOM: Bool; var lineEnding: LineEnding }`. M1: UTF-8 only (with or without BOM), LF/CRLF/CR detected and kept. Invalid UTF-8 throws `PlainTextIO.Error.notUTF8` (M3 adds other encodings). Pure functions, no AppKit. |
| `doc-model` | `Document/TextDocument.swift` | `final class TextDocument: NSDocument`. Owns one `NSTextStorage`. `read(from data:ofType:)` calls `PlainTextIO.decode` and fills storage with `replaceCharacters` inside `beginEditing/endEditing` while no layout manager is attached. `data(ofType:)` calls `PlainTextIO.encode` with the stored format. `autosavesInPlace = true`. `canConcurrentlyReadDocuments(ofType:) = true`. Type `public.plain-text`. |
| `win-text` | `Window/DocumentWindowController.swift`, `Window/TextViewFactory.swift` | One window per document, a scroll view with a TextKit 1 text view on the document's storage. Plain font = `NSFont.userFixedPitchFont(ofSize: 0)`. Tab stops every 8 spaces of that font's `x` advance (measured with `"x".size(withAttributes:)`, never `defaultLineHeight` via the layout manager). Initial content size = 90 x-advances + 2 x `lineFragmentPadding` wide, 30 x the font's line height (`ascender - descender + leading`, rounded up) tall. Rich text off, `isRichText = false`, `importsGraphics = false`, `usesFontPanel = false`, `usesRuler = false`, `allowsUndo = true`, find bar via `usesFindBar = true`. Spelling and substitution flags from `Defaults` (section 5). |
| `app-menu` | `App/MainMenu.swift` | Builds the full menu bar in code. Titles, key equivalents and actions come from `docs/codemap.md` section 2 rows marked KEEP or CHANGE. Items whose feature lands in a later milestone are present but call a not-yet-implemented action only if the menu item would otherwise be missing from TextEdit's layout; leave them out instead when unsure and list them in the report. |
| `launch-stamp` | `App/LaunchStamp.swift` | If env `QUICKEDIT_LAUNCH_LOG` is set, after the first document window is key and its text view is first responder, on the next main-loop turn after the window's first display, write one line `main_abs_ns=<n> ready_abs_ns=<n>\n` using `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` (main stamp taken at the top of `main.swift`). The harness also honours `FASTPAD_LAUNCH_LOG` for the same purpose; read either. Does nothing when unset. |
| `line-panel` | `Window/LinePanelController.swift` | Select Line panel, built on first use. Sizes from TextEdit's nib: content 253x62, field at (20,20) 138x22, Select button at (162,13) 77x32, minimum content 213x30. Frame autosave name `SelectLine`, restoration id `Line`. Line ends follow `NSString.lineRange(for:)`: LF, CR, CRLF, U+0085, U+2028, U+2029 (not form feed). |
| `defaults` | `Support/Defaults.swift` | One `enum DefaultsKey: String` with every kept key from `docs/codemap.md` section 3, and `static func register()` with the same default values. Called once at launch before any window. |

## 4. Commands
All run from the repo root. Each prints its result and exits non-zero on failure.
- `./build.sh` : `xcodegen generate` then a Release build to `build/Release/QuickEdit.app`. Signs with `Developer ID Application: Yi Li (8Q5V8XK85Y)` when the keychain is open, else ad-hoc (`-`) and prints `SIGNING: ad-hoc (keychain locked)`.
- `./build.sh test` : Debug build plus `xcodebuild test` for `QuickEditTests` and `QuickEditUITests`. Prints the executed count; zero tests executed, any skipped test, or any retry counts as failure (exit 1). Use `-derivedDataPath build/DerivedData` and `-scheme QuickEdit`.
- `./build.sh unit` : only `QuickEditTests` (no UI, works with the screen locked).
- `./build.sh dist M<n>` : `./build.sh`, then `ditto -c -k --keepParent` to `builds/QuickEdit-M<n>.zip`; then notarize with `xcrun notarytool submit --wait --keychain-profile fastpad-notary` and `xcrun stapler staple` if the keychain is open, else prints `NOTARIZE: skipped (keychain locked)`.
- `bench/run-bench.sh [runs]` : launch race, QuickEdit vs `/System/Applications/TextEdit.app` (and `build/reference/TextEditReference.app` when present), interleaved, 2 warm-ups, default 5 runs, CSV to `build/bench-<time>/results.csv`.
- `reference/build-reference.sh` : section 6.

## 5. Defaults (registered values)
Kept keys and values from `docs/codemap.md` section 3: `ShowPageBreaks` NO, `AddExtensionToNewPlainTextFiles` YES, `WidthInChars` 90, `HeightInChars` 30, `PlainTextEncoding` none (Automatic), `PlainTextEncodingForWrite` none, `TabWidth` 8, `CheckSpellingWhileTyping` YES, `CheckGrammarWithSpelling` NO, `CorrectSpellingAutomatically` system value, `SmartCopyPaste` YES, `SmartQuotes` NO, `SmartDashes` NO, `DataDetectors` NO, `TextReplacement` system value, `AutosavingDelay` 30, `NumberPagesWhenPrinting` NO, `WrapToFitWhenPrinting` YES, `Encodings` (array, M3).

## 6. Reference build
`reference/build-reference.sh` copies `reference/apple` to `${TMPDIR}/qe-ref-src`, converts the six binary-plist `English.lproj/*.strings` files to UTF-8 text `.strings`, sets `fileEncoding = 4` in the copied `project.pbxproj`, builds with `ARCHS=arm64 VALID_ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- SYMROOT=<repo>/build/reference-sym OBJROOT=${TMPDIR}/qe-ref-obj`, renames the product to `build/reference/TextEditReference.app`, sets its `CFBundleIdentifier` to `dev.yili.TextEditReference`, re-signs ad-hoc, and fails unless `Contents/MacOS/TextEdit` exists. It never edits `reference/`.

## 7. Speed rules (every milestone)
1. Nothing proportional to document size runs on the main thread while typing.
2. Files are read and decoded off the main thread (`canConcurrentlyReadDocuments`); storage is filled before a layout manager is attached.
3. Launch creates only the menu bar and the first window. Panels and the Settings window are made on first use.
4. Never call `ensureLayout` for the whole document, never ask the layout manager for the full glyph count while typing.
5. No timers, display links or polling at idle.
6. Release settings: `SWIFT_OPTIMIZATION_LEVEL = -O`, `SWIFT_COMPILATION_MODE = wholemodule`, `DEAD_CODE_STRIPPING = YES`.

## 8. Tests
- Unit and file tests in `QuickEditTests`: real files in `FileManager.default.temporaryDirectory`, byte-for-byte checks with `Data` equality.
- UI tests in `QuickEditUITests` launch the app with `-ApplePersistenceIgnoreState YES` and `-NSQuitAlwaysKeepsWindows NO`, and open files passed by launch argument `-QEOpenPath <path>` (the app opens that path at launch when present; this argument exists for tests only).
- Every bug fix lands with a test that fails before the fix.
