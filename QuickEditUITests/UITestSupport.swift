import XCTest

/// Shared setup for QuickEdit UI tests.
///
/// The UI test runner is sandboxed (it may read any path but write only in its
/// own container), so `./build.sh test` makes the fixture files and folders and
/// passes their path as TEST_RUNNER_QE_FIXTURES. The app is sandboxed too
/// (M9), so the fixtures live in the Debug app's own container
/// (~/Library/Containers/dev.yili.QuickEdit.debug/Data/tmp), where it may
/// read and save without a Save or Open panel; the tests only read them.
@MainActor
class QuickEditUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        if let app, app.state != .notRunning {
            app.terminate()
        }
    }

    /// The fixture folder for one test, made by build.sh.
    func fixtureFolder(_ name: String) throws -> URL {
        guard let root = ProcessInfo.processInfo.environment["QE_FIXTURES"] else {
            XCTFail("QE_FIXTURES is not set. Run the UI tests with ./build.sh test, which makes the fixtures.")
            throw NSError(domain: "QuickEditUITests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "QE_FIXTURES is not set"])
        }
        let url = URL(fileURLWithPath: root).appendingPathComponent(name, isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                      "missing fixture folder \(url.path)")
        return url
    }

    /// Launches QuickEdit the way Doc B section 8 says, optionally opening a file.
    /// `keepsWindows` is for the restoration test only: it reads and writes
    /// saved window state (`-ApplePersistenceIgnoreState NO`,
    /// `-NSQuitAlwaysKeepsWindows YES`).
    @discardableResult
    func launch(opening path: String? = nil, keepsWindows: Bool = false,
                extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = keepsWindows
            ? ["-ApplePersistenceIgnoreState", "NO", "-NSQuitAlwaysKeepsWindows", "YES"]
            : ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        if let path { app.launchArguments += ["-QEOpenPath", path] }
        app.launchArguments += extraArguments
        app.launch()
        self.app = app
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "no window after launch")
        return app
    }

    var textView: XCUIElement { app.textViews.firstMatch }

    var text: String { (textView.value as? String) ?? "" }

    /// Polls the file until its bytes equal `expected`, for up to `timeout` seconds.
    func waitForBytes(_ url: URL, _ expected: [UInt8], timeout: TimeInterval = 10,
                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [UInt8]?
        while Date() < deadline {
            if let data = try? Data(contentsOf: url) {
                last = Array(data)
                if last == expected { return }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("bytes at \(url.path) are \(last.map { String(decoding: $0, as: UTF8.self).debugDescription } ?? "missing"), "
                + "expected \(String(decoding: expected, as: UTF8.self).debugDescription)", file: file, line: line)
    }

    /// The Save panel sheet on the front window.
    func savePanel(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "no Save panel", file: file, line: line)
        return sheet
    }

    /// In an open Save panel: type the name, then optionally set the ".txt"
    /// checkbox, go to `folder` with Cmd+Shift+G, and press Save. The name is
    /// typed BEFORE the checkbox changes, as a person does, so a checkbox that
    /// overwrites the typed name fails the test (M1 review row 3).
    func fillSavePanel(name: String, folder: URL, addTxtExtension: Bool? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
        let sheet = savePanel(file: file, line: line)
        if let addTxtExtension {
            let nameField = sheet.textFields.firstMatch
            nameField.click()
            safePress("a", .command, on: nameField)
            safeType(name)
            let checkbox = sheet.checkBoxes["If no extension is provided, use \u{201C}.txt\u{201D}."]
            XCTAssertTrue(checkbox.waitForExistence(timeout: 5), "no .txt checkbox", file: file, line: line)
            let isOn = (checkbox.value as? Int ?? (checkbox.value as? NSNumber)?.intValue ?? 0) == 1
            if isOn != addTxtExtension { checkbox.click() }
            XCTAssertEqual(nameField.value as? String, name, "the .txt checkbox changed the typed name",
                           file: file, line: line)
        } else {
            safeType(name)
        }
        safePress("g", [.command, .shift])
        let goTo = sheet.sheets.firstMatch.exists ? sheet.sheets.firstMatch : sheet
        _ = goTo.textFields.firstMatch.waitForExistence(timeout: 5)
        safeType(folder.path)
        safePress(.return, [])
        // Let the panel settle on the folder, then press Save.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        safePress(.return, [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Save panel did not close", file: file, line: line)
    }

    func attachScreenshot(_ name: String, _ screenshot: XCUIScreenshot) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits until `condition` holds, for up to `timeout` seconds.
    func waitUntil(_ timeout: TimeInterval, _ message: @autoclosure () -> String,
                   file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool) {
        let predicate = NSPredicate { _, _ in condition() }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)],
                                    timeout: timeout)
        XCTAssertEqual(result, .completed, message(), file: file, line: line)
    }

    /// Chooses File > <title> (or a nested item) with the mouse.
    func chooseMenu(_ path: String...) {
        var element: XCUIElement = app.menuBars.menuBarItems[path[0]]
        element.click()
        for title in path.dropFirst() {
            element = element.menuItems[title]
            XCTAssertTrue(element.waitForExistence(timeout: 5), "no menu item \(title)")
            element.click()
        }
    }

    /// Bytes of a fixture file, or nil.
    func bytes(_ url: URL) -> [UInt8]? { (try? Data(contentsOf: url)).map(Array.init) }
}
