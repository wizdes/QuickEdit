import XCTest

/// M9 n1: file paths that change under the App Sandbox. The sandboxed Save
/// panel runs in another process, so QuickEdit's ".txt" rule now works
/// through the panel's own extension handling; these check it still asks
/// before replacing a file.
@MainActor
final class SandboxUITests: QuickEditUITestCase {
    /// Saving "plain" with the ".txt" box on, where "plain.txt" already
    /// exists, asks before replacing it; Cancel keeps the file's bytes.
    func testBareNameWithTxtBoxAsksBeforeReplacingTheTxtFile() throws {
        let folder = try fixtureFolder("ext-replace")
        let existing = folder.appendingPathComponent("plain.txt")
        let kept = Array("keep me\n".utf8)
        XCTAssertEqual(bytes(existing), kept)

        launch()
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.click()
        safeType("new")
        safePress("s", .command)
        let sheet = savePanel()
        let nameField = sheet.textFields.firstMatch
        nameField.click()
        safePress("a", .command, on: nameField)
        safeType("plain")
        let checkbox = sheet.checkBoxes["If no extension is provided, use \u{201C}.txt\u{201D}."]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5), "no .txt checkbox")
        let isOn = (checkbox.value as? Int ?? (checkbox.value as? NSNumber)?.intValue ?? 0) == 1
        if !isOn { checkbox.click() }
        safePress("g", [.command, .shift])
        let goTo = sheet.sheets.firstMatch.exists ? sheet.sheets.firstMatch : sheet
        _ = goTo.textFields.firstMatch.waitForExistence(timeout: 5)
        safeType(folder.path)
        safePress(.return, [])
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        safePress(.return, [])

        let replace = app.buttons["Replace"].firstMatch
        XCTAssertTrue(replace.waitForExistence(timeout: 10), "no question before replacing plain.txt")
        safePress(.escape, []) // Cancel on the replace question
        XCTAssertTrue(replace.waitForNonExistence(timeout: 5), "the replace question did not close")
        if sheet.exists { safePress(.escape, []) }
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Save panel did not close")

        XCTAssertEqual(bytes(existing), kept, "plain.txt was replaced after Cancel")
        XCTAssertNil(bytes(folder.appendingPathComponent("plain")), "a bare \"plain\" was saved")
    }

    /// The real sandbox case: a file OUTSIDE the app's container, which the
    /// app may use only because the user picked it. Opened with the Open
    /// panel, edited and saved; after a relaunch Open Recent reopens it and
    /// a second save still works (the access is remembered).
    func testOutsideFilePickedInOpenPanelSavesAndReopensFromOpenRecent() throws {
        let url = try outsideFile("user.txt")
        waitForBytes(url, Array("outside\n".utf8))

        launch()
        let window = openInOpenPanel(url)
        XCTAssertEqual(text, "outside\n")
        safePress(.downArrow, .command)
        safeType("one")
        safePress("s", .command)
        waitForBytes(url, Array("outside\none".utf8))

        safePress("q", .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "QuickEdit did not quit")

        launch()
        chooseMenu("File", "Open Recent")
        // Files with the same name from earlier runs are in the list too;
        // macOS then adds the folder name: "user.txt — <folder>".
        let recent = app.menuBars.menuBarItems["File"].menuItems["Open Recent"]
        let folder = url.deletingLastPathComponent().lastPathComponent
        let item = recent.menuItems.matching(NSPredicate(
            format: "title == 'user.txt' OR (title BEGINSWITH 'user.txt' AND title ENDSWITH %@)", folder)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "user.txt is not in Open Recent after a relaunch; it lists "
                      + "\(recent.menuItems.allElementsBoundByIndex.map(\.title))")
        item.click()
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Open Recent did not reopen user.txt")
        waitUntil(10, "the reopened window shows the saved text") {
            (window.textViews.firstMatch.value as? String) == "outside\none"
        }
        window.textViews.firstMatch.click()
        safePress(.downArrow, .command)
        safeType(" two")
        safePress("s", .command)
        waitForBytes(url, Array("outside\none two".utf8))
    }

    /// Window restoration of a picked file outside the container: quit with
    /// windows kept, relaunch, the window and its text come back. With saved
    /// state read, a QuickEdit that last quit with no windows opens none
    /// (measured 2026-10-25), so the first launch opens a fixture from the
    /// container to have a window. Closes every window before the last quit,
    /// so no saved window is left for later runs.
    func testOutsideFilePickedInOpenPanelComesBackAfterRelaunch() throws {
        let url = try outsideFile("restore.txt")
        let start = try fixtureFolder("sandbox-restore").appendingPathComponent("start.txt")
        launch(opening: start.path, keepsWindows: true)
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "title BEGINSWITH 'start'")).firstMatch
            .waitForExistence(timeout: 10), "start.txt did not open")
        _ = openInOpenPanel(url)
        RunLoop.current.run(until: Date().addingTimeInterval(3.0)) // let state save
        safePress("q", .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "QuickEdit did not quit")

        launch(keepsWindows: true)
        let window = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'restore'")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15),
                      "titles: \(app.windows.allElementsBoundByIndex.map(\.title))")
        waitUntil(10, "the restored window shows the file's text") {
            (window.textViews.firstMatch.value as? String) == "restored from outside\n"
        }
        for _ in 0..<3 where app.windows.count > 0 {
            safePress("w", .command)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertEqual(app.windows.count, 0, "windows left open: \(app.windows.allElementsBoundByIndex.map(\.title))")
        safePress("q", .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    /// Save, Revert and Export as PDF on a picked file outside the
    /// container: the Open panel's access covers the save and the revert,
    /// and the PDF Save panel's covers the new PDF next to it.
    func testOutsideFileSavesRevertsAndExportsAPDF() throws {
        let url = try outsideFile("life.txt")
        launch()
        _ = openInOpenPanel(url)
        safePress(.downArrow, .command)
        safeType("A")
        safePress("s", .command)
        waitForBytes(url, Array("life\nA".utf8))
        safeType("B")
        app.menuBars.menuBarItems["File"].click()
        let revertTo = app.menuBars.menuBarItems["File"].menuItems["Revert To"]
        XCTAssertTrue(revertTo.waitForExistence(timeout: 5), "no Revert To submenu")
        revertTo.hover()
        let last = revertTo.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Last'")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 5), "items: \(revertTo.menuItems.allElementsBoundByIndex.map(\.title))")
        last.click()
        let sheet = app.sheets.firstMatch
        if sheet.waitForExistence(timeout: 2), sheet.buttons["Revert"].exists { sheet.buttons["Revert"].click() }
        waitUntil(10, "the window shows \(text.debugDescription) after Revert") { self.text == "life\nA" }
        XCTAssertEqual(bytes(url), Array("life\nA".utf8))

        chooseMenu("File", "Export as PDF\u{2026}")
        fillSavePanel(name: "life-export", folder: url.deletingLastPathComponent())
        let pdf = url.deletingLastPathComponent().appendingPathComponent("life-export.pdf")
        waitUntil(10, "no PDF at \(pdf.path)") {
            (try? Data(contentsOf: pdf))?.starts(with: Array("%PDF".utf8)) ?? false
        }
    }

    /// Reopen with an encoding: the Open panel's encoding choice decodes a
    /// picked file outside the container (UTF-8 bytes read as Windows
    /// Latin 1 show "caf\u{C3}\u{A9}").
    func testOutsideFileOpensWithTheChosenEncoding() throws {
        let url = try outsideFile("latin.txt")
        launch()
        let window = openInOpenPanel(url, encoding: "Western (Windows Latin 1)")
        XCTAssertEqual(window.textViews.firstMatch.value as? String, "caf\u{C3}\u{A9}\n")
    }

    /// The read-only limit for the large-file tests: 50 MiB, so the 55 MB
    /// big.txt opens read-only and Save As copies its clone
    /// (TextDocument.originalForCopy), as a file over 512 MiB does.
    private static let lowReadOnlyLimit = ["-QETestReadOnlyLimitBytes", String(50 * 1024 * 1024)]

    /// Opens the large outside file read-only (lowered limit) and waits for
    /// its clone in the app's own temporary folder (M8 V3).
    private func openLargeOutsideFileReadOnly() throws -> URL {
        let url = try outsideFile("big.txt")
        let size = try XCTUnwrap(try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 50 * 1024 * 1024)
        launch(extraArguments: Self.lowReadOnlyLimit)
        _ = openInOpenPanel(url, timeout: 30)
        let originals = Self.debugContainerTmp.appendingPathComponent("QuickEdit-originals")
        waitUntil(10, "no clone of big.txt in \(originals.path)") {
            let folders = (try? FileManager.default.contentsOfDirectory(atPath: originals.path)) ?? []
            return folders.contains { FileManager.default.fileExists(
                atPath: originals.appendingPathComponent($0).appendingPathComponent("big.txt").path) }
        }
        return url
    }

    /// Waits until `copy` has every byte of `original`, then compares all.
    private func waitForSameBytes(_ copy: URL, as original: URL, timeout: TimeInterval = 30) throws {
        let size = try XCTUnwrap(try? FileManager.default.attributesOfItem(atPath: original.path)[.size] as? Int)
        waitUntil(timeout, "\(copy.lastPathComponent) is not \(size) bytes") {
            ((try? FileManager.default.attributesOfItem(atPath: copy.path))?[.size] as? Int) == size
        }
        XCTAssertTrue(try Data(contentsOf: copy) == Data(contentsOf: original), "\(copy.lastPathComponent) differs from the original")
    }

    /// A large picked file outside the container is cloned into the app's
    /// own temporary folder (M8 V3); read-only, Save As writes the clone's
    /// bytes, all of them, to a new file next to it, and a second Save As
    /// writes them over a file that is already there (after Replace). One
    /// open for both: a second Open panel over the folder, with two 55 MB
    /// files in it, once missed the file for over 30 s.
    func testLargeOutsideFileIsClonedAndSavesAs() throws {
        let url = try openLargeOutsideFileReadOnly()
        safePress("s", [.command, .shift, .option]) // Save As… (Cmd+Shift+S is Duplicate)
        fillSavePanel(name: "big-copy", folder: url.deletingLastPathComponent(), addTxtExtension: true)
        try waitForSameBytes(url.deletingLastPathComponent().appendingPathComponent("big-copy.txt"), as: url)

        let target = url.deletingLastPathComponent().appendingPathComponent("big-target.txt")
        XCTAssertEqual(bytes(target), Array("old target\n".utf8))
        safePress("s", [.command, .shift, .option])
        fillSavePanel(name: "big-target", folder: url.deletingLastPathComponent(), addTxtExtension: true,
                      replacing: true)
        try waitForSameBytes(target, as: url)
    }

    /// Export as PDF over a PDF that is already there, in the outside folder.
    func testOutsideFileExportsAPDFOverAnExistingPDF() throws {
        let url = try outsideFile("pdf-source.txt")
        let pdf = url.deletingLastPathComponent().appendingPathComponent("existing.pdf")
        XCTAssertEqual(bytes(pdf), Array("not a pdf yet\n".utf8))
        launch()
        _ = openInOpenPanel(url)
        chooseMenu("File", "Export as PDF\u{2026}")
        fillSavePanel(name: "existing", folder: url.deletingLastPathComponent(), replacing: true)
        waitUntil(15, "existing.pdf is not a PDF") {
            (try? Data(contentsOf: pdf))?.starts(with: Array("%PDF".utf8)) ?? false
        }
    }

    /// Save As with another extension, on a picked outside file: the new
    /// file has the text, the old one keeps its bytes.
    func testOutsideFileSavesAsWithAnotherExtension() throws {
        let url = try outsideFile("ext.txt")
        launch()
        _ = openInOpenPanel(url)
        safePress("s", [.command, .shift, .option])
        fillSavePanel(name: "ext.md", folder: url.deletingLastPathComponent(), addTxtExtension: false)
        // QuickEdit asks whether to keep ".md" or use ".txt" (TextEdit's question).
        let keep = app.buttons.matching(NSPredicate(format: "title BEGINSWITH 'Use'")).matching(
            NSPredicate(format: "title CONTAINS '.md'")).firstMatch
        if keep.waitForExistence(timeout: 3) { keep.click() }
        waitForBytes(url.deletingLastPathComponent().appendingPathComponent("ext.md"), Array("extension\n".utf8))
        XCTAssertEqual(bytes(url), Array("extension\n".utf8))
    }

    /// Autosave writes a picked outside file, and an older version kept by
    /// Versions can be read back (File > Revert To > Browse All Versions
    /// is a full-screen UI; the test reads the version through Revert To's
    /// "Last Saved" item instead, which comes from the same version store).
    func testOutsideFileAutosavesAndAnOlderVersionComesBack() throws {
        let url = try outsideFile("versions.txt")
        launch()
        _ = openInOpenPanel(url)
        safePress(.downArrow, .command)
        safeType("one")
        safePress("s", .command)
        waitForBytes(url, Array("v1\none".utf8))
        safeType(" two")
        // Autosave in place (QuickEdit's autosavesInPlace): the file gets the
        // edit with no Save. Up to about 30 s on a loaded Mac.
        waitForBytes(url, Array("v1\none two".utf8), timeout: 45)
        app.menuBars.menuBarItems["File"].click()
        let revertTo = app.menuBars.menuBarItems["File"].menuItems["Revert To"]
        XCTAssertTrue(revertTo.waitForExistence(timeout: 5), "no Revert To submenu")
        revertTo.hover()
        let items = revertTo.menuItems.allElementsBoundByIndex.map(\.title)
        let older = revertTo.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Last Opened' OR title BEGINSWITH 'Last Saved'")).firstMatch
        XCTAssertTrue(older.waitForExistence(timeout: 5), "Revert To lists \(items)")
        older.click()
        let sheet = app.sheets.firstMatch
        if sheet.waitForExistence(timeout: 2), sheet.buttons["Revert"].exists { sheet.buttons["Revert"].click() }
        waitUntil(10, "no older version came back; text \(text.debugDescription), menu \(items)") {
            self.text == "v1\none" || self.text == "v1\n"
        }
    }

    /// The -QETestExternalWrite hook's /bin/sh runs inside the app's
    /// sandbox: it may write a picked file outside the container once the
    /// Open panel gave the app access, and the clean window reloads.
    func testOutsideFileReloadsAfterTheTestHooksWrite() throws {
        let url = try outsideFile("reload.txt")
        // The access exists only once the Open panel has opened the file
        // (31 s once in a loaded run). The hook writes 1 s after the window
        // is open with its caret at the end (-QETestExternalWriteAfterCaretAtEnd),
        // and the test moves the caret only after it read the old text.
        launch(extraArguments: ["-QETestExternalWrite", url.path, "-QETestExternalWriteText", "after\\n",
                                "-QETestExternalWriteDelay", "1", "-QETestExternalWriteAfterCaretAtEnd", "YES"])
        let window = openInOpenPanel(url)
        XCTAssertEqual(window.textViews.firstMatch.value as? String, "before\n")
        XCTAssertEqual(bytes(url), Array("before\n".utf8), "the hook wrote before the caret moved")
        safePress(.downArrow, .command)
        waitForBytes(url, Array("after\n".utf8), timeout: 15)
        waitUntil(6, "the window did not reload") {
            (window.textViews.firstMatch.value as? String) == "after\n"
        }
    }

    // MARK: Helpers

    /// The Debug app's temporary folder, inside its container.
    private static var debugContainerTmp: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? "/Users"
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Containers/\(quickEditBundleID)/Data/tmp", isDirectory: true)
    }

    /// A file build.sh made outside every container (QE_OUTSIDE).
    private func outsideFile(_ name: String) throws -> URL {
        guard let root = ProcessInfo.processInfo.environment["QE_OUTSIDE"] else {
            XCTFail("QE_OUTSIDE is not set. Run the UI tests with ./build.sh test.")
            throw NSError(domain: "QuickEditUITests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "QE_OUTSIDE is not set"])
        }
        let url = URL(fileURLWithPath: root).appendingPathComponent(name)
        XCTAssertFalse(url.path.contains("/Library/Containers/"), "the fixture must be outside every container")
        XCTAssertNotNil(bytes(url), "missing \(url.path)")
        return url
    }

    /// File > Open (Cmd+O), optionally an encoding in the panel's pop-up,
    /// Go to Folder with the full path, Open: the user picks the file, which
    /// gives the sandboxed app access to it.
    private func openInOpenPanel(_ url: URL, encoding: String? = nil, timeout: TimeInterval = 10) -> XCUIElement {
        safePress("o", .command)
        // On macOS 27 the Open panel is a window titled "Open".
        let openWindow = app.windows["Open"]
        XCTAssertTrue(openWindow.waitForExistence(timeout: 10) || app.sheets.firstMatch.exists
                      || app.dialogs.firstMatch.exists, "no Open panel")
        if let encoding {
            let panel = openWindow.exists ? openWindow
                : (app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch)
            let popUp = panel.popUpButtons["openEncoding"]
            XCTAssertTrue(popUp.waitForExistence(timeout: 5), "no encoding pop-up")
            popUp.click()
            let item = popUp.menuItems[encoding]
            XCTAssertTrue(item.waitForExistence(timeout: 5), "no item \(encoding)")
            item.click()
        }
        safePress("g", [.command, .shift])
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        safeType(url.path)
        safePress(.return, [])
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        safePress(.return, [])
        let stem = url.deletingPathExtension().lastPathComponent
        let window = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", stem)).firstMatch
        // The panel can miss the Return while it still loads the folder
        // (seen once with the 55 MB file there): press it again while the
        // panel is still open and no window came.
        for _ in 0..<2 where !window.waitForExistence(timeout: 3) && openWindow.exists {
            safePress(.return, [])
        }
        XCTAssertTrue(window.waitForExistence(timeout: timeout),
                      "no window titled \(stem); titles: \(app.windows.allElementsBoundByIndex.map { $0.title })")
        return window
    }
}
