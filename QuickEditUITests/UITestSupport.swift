import XCTest

/// Shared setup for QuickEdit UI tests.
///
/// The UI test runner is sandboxed (it may read any path but write only in its
/// own container), so `./build.sh test` makes the fixture files and folders and
/// passes their path as TEST_RUNNER_QE_FIXTURES. The app is not sandboxed and
/// saves into those folders; the tests only read them.
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
    @discardableResult
    func launch(opening path: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        if let path { app.launchArguments += ["-QEOpenPath", path] }
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

    /// In an open Save panel: optionally set the ".txt" checkbox, type the name,
    /// go to `folder` with Cmd+Shift+G, and press Save.
    func fillSavePanel(name: String, folder: URL, addTxtExtension: Bool? = nil,
                       file: StaticString = #filePath, line: UInt = #line) {
        let sheet = savePanel(file: file, line: line)
        if let addTxtExtension {
            let checkbox = sheet.checkBoxes["If no extension is provided, use \u{201C}.txt\u{201D}."]
            XCTAssertTrue(checkbox.waitForExistence(timeout: 5), "no .txt checkbox", file: file, line: line)
            let isOn = (checkbox.value as? Int ?? (checkbox.value as? NSNumber)?.intValue ?? 0) == 1
            if isOn != addTxtExtension { checkbox.click() }
            let nameField = sheet.textFields.firstMatch
            nameField.click()
            nameField.typeKey("a", modifierFlags: .command)
        }
        app.typeText(name)
        app.typeKey("g", modifierFlags: [.command, .shift])
        let goTo = sheet.sheets.firstMatch.exists ? sheet.sheets.firstMatch : sheet
        _ = goTo.textFields.firstMatch.waitForExistence(timeout: 5)
        app.typeText(folder.path)
        app.typeKey(.return, modifierFlags: [])
        // Let the panel settle on the folder, then press Save.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Save panel did not close", file: file, line: line)
    }

    func attachScreenshot(_ name: String, _ screenshot: XCUIScreenshot) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
