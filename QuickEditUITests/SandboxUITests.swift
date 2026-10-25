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

    /// A large picked file outside the container is cloned into the app's
    /// own temporary folder (M8 V3) and Save As writes all its bytes to a
    /// new file next to it.
    func testLargeOutsideFileIsClonedAndSavesAs() throws {
        let url = try outsideFile("big.txt")
        let size = try XCTUnwrap(try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 50 * 1024 * 1024)
        launch()
        _ = openInOpenPanel(url, timeout: 30)
        let originals = Self.debugContainerTmp.appendingPathComponent("QuickEdit-originals")
        waitUntil(10, "no clone of big.txt in \(originals.path)") {
            let folders = (try? FileManager.default.contentsOfDirectory(atPath: originals.path)) ?? []
            return folders.contains { FileManager.default.fileExists(
                atPath: originals.appendingPathComponent($0).appendingPathComponent("big.txt").path) }
        }
        safePress("s", [.command, .shift, .option]) // Save As… (Cmd+Shift+S is Duplicate)
        fillSavePanel(name: "big-copy", folder: url.deletingLastPathComponent(), addTxtExtension: true)
        let copy = url.deletingLastPathComponent().appendingPathComponent("big-copy.txt")
        waitUntil(30, "big-copy.txt is not \(size) bytes") {
            ((try? FileManager.default.attributesOfItem(atPath: copy.path))?[.size] as? Int) == size
        }
        XCTAssertEqual(try Data(contentsOf: copy).prefix(64), try Data(contentsOf: url).prefix(64))
    }

    /// The -QETestExternalWrite hook's /bin/sh runs inside the app's
    /// sandbox: it may write a picked file outside the container once the
    /// Open panel gave the app access, and the clean window reloads.
    func testOutsideFileReloadsAfterTheTestHooksWrite() throws {
        let url = try outsideFile("reload.txt")
        launch(extraArguments: ["-QETestExternalWrite", url.path, "-QETestExternalWriteText", "after\\n",
                                "-QETestExternalWriteDelay", "40"])
        // The write comes 40 s after launch: the access exists only once the
        // Open panel has opened the file, which took 31 s in a loaded
        // ./build.sh quick run (2026-10-25), so 20 s was too soon.
        let window = openInOpenPanel(url)
        XCTAssertEqual(window.textViews.firstMatch.value as? String, "before\n")
        waitForBytes(url, Array("after\n".utf8), timeout: 45)
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
