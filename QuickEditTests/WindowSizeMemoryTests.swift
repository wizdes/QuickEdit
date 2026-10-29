import AppKit
import XCTest
@testable import QuickEdit

/// 1.2.3 user request: a window resized by hand sets the size of new
/// windows. The text area, in characters and lines of the new-document
/// font at actual size, is saved to WidthInChars and HeightInChars when a
/// live resize ends.
@MainActor
final class WindowSizeMemoryTests: XCTestCase {
    private var saved: SavedSettings!
    private var documents: [NSDocument] = []

    override func setUp() async throws {
        saved = SavedSettings()
        ScalingScrollView.animatesZoom = false
    }

    override func tearDown() async throws {
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        documents = []
        ScalingScrollView.animatesZoom = true
        saved.restore()
    }

    private func window(_ text: String = "x") throws -> DocumentWindowController {
        let document = TextDocument()
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0),
                                               with: NSAttributedString(string: text, attributes: TextViewFactory.plainTextAttributes()))
        document.makeWindowControllers()
        documents.append(document)
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        controller.window?.orderFront(nil)
        settle(controller)
        return controller
    }

    private func settle(_ controller: DocumentWindowController) {
        controller.window?.layoutIfNeeded()
        controller.window?.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private var font: NSFont { TextViewFactory.plainFont() }

    /// Resizes the window so the text area is `columns` x `rows`, then
    /// ends a live resize as a hand resize would.
    private func resizeByHand(_ controller: DocumentWindowController, columns: Int, rows: Int) {
        let width = CGFloat(columns) * TextViewFactory.xAdvance(of: font)
        controller.resizeWindow(forViewSize: NSSize(width: width,
                                                    height: CGFloat(rows) * TextViewFactory.lineHeight(of: font)))
        settle(controller)
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification,
                                                       object: controller.window))
    }

    private func savedSize() -> (Int, Int) {
        (Defaults.integer(.widthInChars), Defaults.integer(.heightInChars))
    }

    func testFreshWindowReadsBackTheDefaultSize() throws {
        let controller = try window()
        let size = try XCTUnwrap(controller.textSizeInCharacters())
        XCTAssertEqual(size.columns, 90)
        XCTAssertEqual(size.rows, 30)
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
        XCTAssertNil(saved.persisted?[DefaultsKey.widthInChars.rawValue], "an unchanged size writes nothing")
        XCTAssertNil(saved.persisted?[DefaultsKey.heightInChars.rawValue])
    }

    func testHandResizeSavesColumnsAndRows() throws {
        let controller = try window()
        resizeByHand(controller, columns: 72, rows: 20)
        XCTAssertTrue(savedSize() == (72, 20), "saved \(savedSize())")
        XCTAssertEqual(saved.persisted?[DefaultsKey.widthInChars.rawValue] as? Int, 72)
        XCTAssertEqual(saved.persisted?[DefaultsKey.heightInChars.rawValue] as? Int, 20)
    }

    func testNewWindowOpensAtTheSavedSize() throws {
        let first = try window()
        resizeByHand(first, columns: 110, rows: 44)
        let second = try window()
        let size = try XCTUnwrap(second.textSizeInCharacters())
        XCTAssertEqual(size.columns, 110)
        XCTAssertEqual(size.rows, 44)
        XCTAssertEqual(second.window?.frame.size.width ?? 0, first.window?.frame.size.width ?? -1, accuracy: 0.5)
        XCTAssertEqual(second.window?.frame.size.height ?? 0, first.window?.frame.size.height ?? -1, accuracy: 0.5)
    }

    func testFrameChangeWithoutLiveResizeDoesNotSave() throws {
        let controller = try window()
        controller.resizeWindow(forViewSize: NSSize(width: 40 * TextViewFactory.xAdvance(of: font),
                                                    height: 10 * TextViewFactory.lineHeight(of: font)))
        settle(controller)
        XCTAssertTrue(savedSize() == (90, 30), "saved \(savedSize())")
    }

    func testWrapToPageDoesNotSave() throws {
        let controller = try window()
        try XCTUnwrap(controller.document as? TextDocument).hasMultiplePages = true
        settle(controller)
        XCTAssertTrue(controller.hasMultiplePages)
        XCTAssertNil(controller.textSizeInCharacters())
        controller.window?.setFrame(NSRect(x: 100, y: 100, width: 500, height: 400), display: true)
        settle(controller)
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
        XCTAssertTrue(savedSize() == (90, 30), "saved \(savedSize())")
    }

    func testGutterIsNotCountedAsColumns() throws {
        Defaults.store.set(true, forKey: Defaults.showLineNumbersKey)
        Defaults.store.set(true, forKey: Defaults.showDocumentMapKey)
        let controller = try window((1...500).map { "line \($0)" }.joined(separator: "\n"))
        XCTAssertGreaterThan(controller.gutterWidth, 10, "the gutter shows")
        XCTAssertGreaterThan(controller.sideWidth, controller.gutterWidth, "the map shows")
        resizeByHand(controller, columns: 64, rows: 25)
        XCTAssertTrue(savedSize() == (64, 25), "saved \(savedSize())")
    }

    func testZoomedTextSavesActualSizeCharacters() throws {
        let controller = try window()
        controller.scrollView.zoomIn(nil)
        settle(controller)
        XCTAssertEqual(controller.scrollView.magnification, 2, accuracy: 0.01)
        // 120 x 40 characters on screen at 200% are 60 x 20 at actual size.
        resizeByHand(controller, columns: 120, rows: 40)
        XCTAssertTrue(savedSize() == (60, 20), "saved \(savedSize())")
    }
}
