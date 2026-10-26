# QuickEdit

QuickEdit is a plain-text editor for macOS 27. It is a Swift rebuild of Apple's TextEdit sample code, with the rich-text parts taken out. It opens, edits and saves plain text the way TextEdit does, and it starts quickly.

QuickEdit needs a Mac with Apple silicon and macOS 27 or later.

## Install

1. Download `QuickEdit-1.0.dmg` and open it.
2. Drag QuickEdit to the Applications folder.
3. Open QuickEdit from Launchpad or the Applications folder.

The app and the DMG are signed with a Developer ID and notarized by Apple, so macOS opens them without a warning.

## What it does

- Opens and saves plain-text files (`.txt`, Markdown, JSON, source code and any other file macOS calls text). New files are saved as UTF-8.
- Reads and writes the same text encodings as TextEdit, and lets you pick one in the Open and Save panels.
- Find and Replace, Select Line (Cmd+L), spelling and grammar checks, and the Substitutions menu, with TextEdit's default settings.
- Wrap to Window and Wrap to Page, zoom, and a Settings window with TextEdit's New Document and Open and Save options.
- Print (Cmd+P) and Export as PDF both save a PDF. QuickEdit never talks to a printer.
- Opens very large files. A file over 512 MiB opens read-only: you can view it, search it and copy from it.
- Works with the Services menu, the Share menu, Writing Tools and Quick Look.

## What it does not do

- No rich text: no fonts per word, no colors, no images, no tables. QuickEdit never writes RTF or Word files.
- No AppleScript support, and no Services of its own (the Services menu that macOS adds still works).
- No real printing; see the note on Print above.

## Keyboard shortcuts

Every menu command can have its own shortcut. Open QuickEdit > Settings > Keyboard:

1. Click a command's shortcut and press the new keys.
2. If another command or the system already uses those keys, a message under the table says so, and VoiceOver reads it.
3. Use the reset button on a row to put back one shortcut, or Restore Keyboard Defaults to put back all of them.

Recording and reset also work from the keyboard alone.

## Sandbox

QuickEdit runs in the App Sandbox. It can read and write only the files you open or save through its panels, Finder, the Dock or Open Recent. It cannot reach other files on your Mac or the network.

## Known limit when updating

Since QuickEdit 1.0 runs in the sandbox, it keeps its data in its own container. Your settings move there at the first launch. Untitled documents autosaved by an older QuickEdit (before the sandbox) do not come back, and neither do its old window positions. Save any Untitled document you want to keep before you update.

## Build and test

You need Xcode 27 and XcodeGen (`brew install xcodegen`).

```sh
./build.sh            # Release build to build/Release/QuickEdit.app
./build.sh quick      # lint, unit tests and the main UI tests (under 10 minutes)
./build.sh test       # every shell, unit and UI test (about 25 minutes)
```

UI tests take over the keyboard and mouse. Run them with the screen unlocked, and do not type while they run.

## Credits

Rebuilt from Apple's TextEdit sample code. © 2026 Yi Li.
