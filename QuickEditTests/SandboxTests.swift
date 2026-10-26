import AppKit
import XCTest
@testable import QuickEdit

/// Where the unit tests' screenshots go (read by root). The test host is the
/// sandboxed Debug app (M9), which may not write into the repo, so
/// ./build.sh passes a folder in the app's container as QE_SHOTS and copies
/// it to build/shots after the run. Without ./build.sh, the host's own
/// temporary folder, and one line on stderr says so (sandbox review G).
enum TestShots {
    @MainActor private static var saidWhere = false

    @MainActor static var folder: URL {
        if let path = ProcessInfo.processInfo.environment["QE_SHOTS"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("QuickEditShots", isDirectory: true)
        if !saidWhere {
            saidWhere = true
            FileHandle.standardError.write(Data(("QuickEditTests: QE_SHOTS is not set (not run by ./build.sh), so "
                + "screenshots go to \(fallback.path) and are not copied to build/shots\n").utf8))
        }
        return fallback
    }
}

/// M9 n1: the App Sandbox is on in the build the tests use.
@MainActor
final class SandboxTests: XCTestCase {
    /// The test host runs sandboxed: its home folder is its container.
    func testTheTestHostIsSandboxed() {
        let environment = ProcessInfo.processInfo.environment
        XCTAssertNotNil(environment["APP_SANDBOX_CONTAINER_ID"], "the Debug app is not sandboxed")
        XCTAssertTrue(NSHomeDirectory().hasSuffix("/Library/Containers/\(Bundle.main.bundleIdentifier ?? "?")/Data"),
                      "home is \(NSHomeDirectory()), not the container")
    }

    /// The Debug app has its own bundle ID, so tests never use the real
    /// app's container or settings, and it never carries the settings-move
    /// manifest (that would move the user's real settings into it).
    func testDebugBuildKeepsAwayFromTheRealApp() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "dev.yili.QuickEdit.debug")
        XCTAssertNil(Bundle.main.url(forResource: "container-migration", withExtension: "plist"),
                     "the Debug app must not carry container-migration.plist")
    }

    /// A test's own defaults suite leaves no plist file behind once the
    /// test puts the settings back (sandbox review F).
    func testTestDefaultsSuiteLeavesNoFileBehind() {
        let saved = SavedSettings()
        saved.store.set("probe", forKey: "QETestsSuiteProbe")
        CFPreferencesAppSynchronize(saved.suiteName as CFString)
        let file = SavedSettings.suiteFile(saved.suiteName)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the suite was never saved to \(file.path)")
        saved.restore()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "\(file.path) was left behind")
    }

    /// The sandbox keeps the app out of the user's folders it was not given.
    func testWritingOutsideTheContainerIsRefused() {
        let realHome = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? "/Users"
        // A clearly named probe; if the write ever works, it is removed at
        // once, so nothing is left in the user's folders (sandbox review E).
        let outside = URL(fileURLWithPath: realHome)
            .appendingPathComponent("Library/Caches/QuickEditTests-sandbox-probe-delete-me-\(UUID().uuidString).txt")
        defer {
            if FileManager.default.fileExists(atPath: outside.path) {
                do { try FileManager.default.removeItem(at: outside) } catch {
                    XCTFail("the probe \(outside.path) was written and cannot be removed: \(error); delete it by hand")
                }
            }
        }
        XCTAssertThrowsError(try Data("x".utf8).write(to: outside), "the app wrote \(outside.path) outside its container")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    /// The sandboxed Save panel runs in another process and ignores a name
    /// the delegate returns, so with the ".txt" box on the delegate turns
    /// "other file types" off for a bare name (the panel then adds ".txt"
    /// itself) and back on for a name with its own extension.
    func testExtensionDelegateTurnsOtherTypesOffOnlyForABareName() throws {
        let panel = NSSavePanel()
        PlainTextExtensionPanelDelegate.install(on: panel)
        let delegate = try XCTUnwrap(panel.delegate as? PlainTextExtensionPanelDelegate)
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true

        XCTAssertEqual(delegate.panel(panel, userEnteredFilename: "plain", confirmed: true), "plain.txt")
        XCTAssertFalse(panel.allowsOtherFileTypes, "a bare name must make the panel add .txt")
        XCTAssertEqual(delegate.panel(panel, userEnteredFilename: "x.md", confirmed: true), "x.md")
        XCTAssertTrue(panel.allowsOtherFileTypes, "a typed extension must stay allowed")

        // The box off (no allowed types): nothing changes.
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = false
        XCTAssertEqual(delegate.panel(panel, userEnteredFilename: "bare", confirmed: true), "bare")
        XCTAssertFalse(panel.allowsOtherFileTypes)
    }

    /// Autosave in place keeps Versions in the sandbox: after a save, a
    /// second save leaves the first one as an older version of the file
    /// (File > Revert To > Browse All Versions).
    func testSavingKeepsAnOlderVersion() async throws {
        let folder = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/qe-versions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("versions.txt")
        try Data("one\n".utf8).write(to: url)
        let document = try TextDocument(contentsOf: url, ofType: TextDocument.plainTextType)
        defer { document.close() }
        document.textStorage.replaceCharacters(in: NSRange(location: 4, length: 0), with: "two\n")
        document.updateChangeCount(.changeDone)
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: url, ofType: TextDocument.plainTextType, for: .saveOperation) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(error)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\ntwo\n")
        // The version store is written a moment after the save returns.
        var versions: [NSFileVersion] = []
        let deadline = Date().addingTimeInterval(5)
        while versions.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            versions = NSFileVersion.otherVersionsOfItem(at: url) ?? []
        }
        XCTAssertFalse(versions.isEmpty, "no older version of \(url.path) 5 s after a save")
        defer { try? NSFileVersion.removeOtherVersionsOfItem(at: url) }
    }

    /// File > Share has services for a saved file inside the sandbox.
    func testShareOffersServicesForASavedFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qe-share-\(UUID().uuidString).txt")
        try Data("share\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let services = NSSharingService.sharingServices(forItems: [url])
        XCTAssertFalse(services.isEmpty, "no sharing services for a saved file in the sandbox")
    }
}
