import AppKit
import XCTest
@testable import QuickEdit

/// M5 n1: View > Actual Size, Zoom In and Zoom Out on ScalingScrollView
/// (reference/apple/ScalingScrollView.m, docs/codemap.md 5.4).
@MainActor
final class ZoomTests: XCTestCase {
    private var windows: [NSWindow] = []
    /// A text view does not keep its storage alive; this does.
    private var storages: [NSTextStorage] = []

    override func setUp() async throws {
        ScalingScrollView.animatesZoom = false
    }

    override func tearDown() async throws {
        ScalingScrollView.animatesZoom = true
        for window in windows { window.close() }
        windows = []
        storages = []
    }

    /// A scroll view around a text view, in an offscreen window.
    private func makeScrollView() -> (ScalingScrollView, NSTextView) {
        let size = NSSize(width: 400, height: 300)
        let scrollView = ScalingScrollView(frame: NSRect(origin: .zero, size: size))
        let storage = NSTextStorage(string: "zoom me", attributes: TextViewFactory.plainTextAttributes())
        let textView = TextViewFactory.makeTextView(storage: storage, size: size)
        scrollView.documentView = textView
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.makeFirstResponder(textView)
        windows.append(window)
        storages.append(storage)
        return (scrollView, textView)
    }

    private func viewMenu() throws -> NSMenu {
        try XCTUnwrap(MainMenu.build().item(withTitle: "View")?.submenu, "no View menu")
    }

    private func item(_ title: String) throws -> NSMenuItem {
        try XCTUnwrap(viewMenu().item(withTitle: title), "no View > \(title)")
    }

    /// Sends the item's action up the responder chain from the text view,
    /// the way the menu does from the key window's first responder.
    private func choose(_ item: NSMenuItem, from textView: NSTextView, file: StaticString = #filePath, line: UInt = #line) {
        guard let action = item.action else { return XCTFail("\(item.title) has no action", file: file, line: line) }
        XCTAssertTrue(textView.tryToPerform(action, with: item), "\(item.title) was not handled", file: file, line: line)
    }

    private func isEnabled(_ item: NSMenuItem, in scrollView: ScalingScrollView) -> Bool {
        scrollView.validateMenuItem(item)
    }

    func testViewMenuItems() throws {
        let menu = try viewMenu()
        // 1.2.0 added Show Line Numbers and Show Document Map.
        XCTAssertEqual(menu.items.map(\.title), ["Actual Size", "Zoom In", "Zoom Out", "", "Show Line Numbers",
                                                 "Show Document Map", "", "Enter Full Screen"])
        XCTAssertTrue(menu.items[3].isSeparatorItem)
        XCTAssertTrue(menu.items[6].isSeparatorItem)
        let fullScreen = menu.items[7]
        XCTAssertEqual(fullScreen.action, #selector(NSWindow.toggleFullScreen(_:)))
        XCTAssertEqual(fullScreen.keyEquivalent, "f")
        XCTAssertEqual(fullScreen.keyEquivalentModifierMask, [.command, .control])
        let actual = try item("Actual Size"), zoomIn = try item("Zoom In"), zoomOut = try item("Zoom Out")
        XCTAssertEqual(actual.action, #selector(ScalingScrollView.zoomToActualSize(_:)))
        XCTAssertEqual(actual.keyEquivalent, "0")
        XCTAssertEqual(actual.keyEquivalentModifierMask, [.command])
        // TextEdit's nib: "." and "," with Shift+Cmd, shown as Cmd+> and Cmd+<.
        XCTAssertEqual(zoomIn.action, #selector(ScalingScrollView.zoomIn(_:)))
        XCTAssertEqual(zoomIn.keyEquivalent, ".")
        XCTAssertEqual(zoomIn.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(zoomOut.action, #selector(ScalingScrollView.zoomOut(_:)))
        XCTAssertEqual(zoomOut.keyEquivalent, ",")
        XCTAssertEqual(zoomOut.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(MainMenu.build().items.map(\.title),
                       ["QuickEdit", "File", "Edit", "Format", "View", "Window", "Help"])
    }

    func testScrollViewLimits() {
        let (scrollView, _) = makeScrollView()
        XCTAssertTrue(scrollView.allowsMagnification)
        XCTAssertEqual(scrollView.minMagnification, 0.25)
        XCTAssertEqual(scrollView.maxMagnification, 16.0)
        XCTAssertEqual(scrollView.magnification, 1.0)
    }

    /// 100 -> 200 -> 400 -> 800 -> 1600 (Zoom In off), then down to 25 (Zoom Out off).
    func testMenuStepsUpToTheLimitAndBackDown() throws {
        let (scrollView, textView) = makeScrollView()
        let zoomIn = try item("Zoom In"), zoomOut = try item("Zoom Out")
        var seen: [CGFloat] = [scrollView.magnification]
        while isEnabled(zoomIn, in: scrollView) && seen.count < 10 {
            choose(zoomIn, from: textView)
            seen.append(scrollView.magnification)
        }
        XCTAssertEqual(seen, [1, 2, 4, 8, 16])
        XCTAssertFalse(isEnabled(zoomIn, in: scrollView), "Zoom In stays on at 1600%")
        XCTAssertTrue(isEnabled(zoomOut, in: scrollView))

        seen = [scrollView.magnification]
        while isEnabled(zoomOut, in: scrollView) && seen.count < 10 {
            choose(zoomOut, from: textView)
            seen.append(scrollView.magnification)
        }
        // 2 -> 1 is the snap rule, which here gives the plain halving.
        XCTAssertEqual(seen, [16, 8, 4, 2, 1, 0.5, 0.25])
        XCTAssertFalse(isEnabled(zoomOut, in: scrollView), "Zoom Out stays on at 25%")
        XCTAssertTrue(isEnabled(zoomIn, in: scrollView))

        choose(zoomIn, from: textView)
        choose(zoomIn, from: textView)
        choose(try item("Actual Size"), from: textView)
        XCTAssertEqual(scrollView.magnification, 1.0)
    }

    /// Zoom In from 40%-60% (open) lands on 100%; Zoom Out from 180%-220% too.
    func testSnapRules() {
        XCTAssertEqual(ScalingScrollView.zoomInScale(from: 0.45), 1.0)
        XCTAssertEqual(ScalingScrollView.zoomInScale(from: 0.5), 1.0)
        XCTAssertEqual(ScalingScrollView.zoomInScale(from: 0.59), 1.0)
        XCTAssertEqual(ScalingScrollView.zoomInScale(from: 0.4), 0.8, accuracy: 1e-9)
        XCTAssertEqual(ScalingScrollView.zoomInScale(from: 0.6), 1.2, accuracy: 1e-9)
        XCTAssertEqual(ScalingScrollView.zoomInScale(from: 0.25), 0.5)
        XCTAssertEqual(ScalingScrollView.zoomInScale(from: 10), 16, "never past 1600%")

        XCTAssertEqual(ScalingScrollView.zoomOutScale(from: 1.9), 1.0)
        XCTAssertEqual(ScalingScrollView.zoomOutScale(from: 2.0), 1.0)
        XCTAssertEqual(ScalingScrollView.zoomOutScale(from: 2.19), 1.0)
        XCTAssertEqual(ScalingScrollView.zoomOutScale(from: 1.8), 0.9, accuracy: 1e-9)
        XCTAssertEqual(ScalingScrollView.zoomOutScale(from: 2.2), 1.1, accuracy: 1e-9)
        XCTAssertEqual(ScalingScrollView.zoomOutScale(from: 0.3), 0.25, "never under 25%")
    }

    /// A pinch can leave any value; the menu steps from there.
    func testMenuStepsFromAPinchedValue() throws {
        let (scrollView, textView) = makeScrollView()
        scrollView.magnification = 0.55
        choose(try item("Zoom In"), from: textView)
        XCTAssertEqual(scrollView.magnification, 1.0)
        scrollView.magnification = 3.0
        choose(try item("Zoom Out"), from: textView)
        XCTAssertEqual(scrollView.magnification, 1.5, accuracy: 1e-9)
    }

    /// Document windows use the scaling scroll view.
    func testDocumentWindowScrollsWithScalingScrollView() throws {
        let document = TextDocument()
        document.makeWindowControllers()
        defer { document.close() }
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        // Since 1.2.0 the scroll view sits in a container beside the map.
        XCTAssertTrue(controller.scrollView.superview === controller.window?.contentView)
        choose(try item("Zoom In"), from: controller.textView)
        XCTAssertEqual(controller.scrollView.magnification, 2.0)
    }
}
