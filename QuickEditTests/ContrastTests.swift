import AppKit
import XCTest
@testable import QuickEdit

/// User decision U8: the accessibility audit skips contrast, so this test
/// checks it. Every text label and control text in the document window
/// (Wrap to Window and Wrap to Page), every Settings tab and the Select
/// Line panel has a contrast ratio of 4.5:1 or better (WCAG 2 for normal
/// text) against the background it is drawn on, in light and dark mode.
///
/// The view tree is walked. Each text color is resolved in the view's own
/// effective appearance (the pages stay light in dark mode). The
/// background is the nearest view behind the text that draws one; for a
/// view inside a tab view it is also the tab view's own fill, read from a
/// drawing of the tab view; table cells are checked on both alternating
/// row colors and the selected-row color. Left out, as WCAG allows or as
/// macOS draws them: disabled controls, placeholder text, empty strings,
/// images, and the tab view's own tab labels.
@MainActor
final class ContrastTests: XCTestCase {
    private var saved: SavedSettings!
    private var windows: [NSWindow] = []
    private var documents: [NSDocument] = []

    override func setUp() async throws {
        saved = SavedSettings()
    }

    override func tearDown() async throws {
        for document in documents {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        for window in windows { window.close() }
        documents = []
        windows = []
        saved.restore()
    }

    // MARK: Color math

    /// sRGB components of `color` resolved in `appearance`.
    private static func rgba(_ color: NSColor, in appearance: NSAppearance) -> [CGFloat] {
        var result: [CGFloat] = [0, 0, 0, 1]
        appearance.performAsCurrentDrawingAppearance {
            guard let s = color.usingColorSpace(.sRGB) else { return }
            result = [s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent]
        }
        return result
    }

    private static func luminance(_ c: [CGFloat]) -> CGFloat {
        let l = c.prefix(3).map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
    }

    /// The WCAG ratio of `text` over `background`, alpha blended; a see-
    /// through background is first blended over `base`.
    static func ratio(_ text: [CGFloat], over background: [CGFloat], base: [CGFloat]) -> CGFloat {
        let bg = (0..<3).map { background[$0] * background[3] + base[$0] * (1 - background[3]) }
        let fg = (0..<3).map { text[$0] * text[3] + bg[$0] * (1 - text[3]) }
        let a = luminance(fg), b = luminance(bg)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    // MARK: Walking the view tree

    private struct Sample {
        let place: String
        let color: NSColor
        /// Each already resolved to sRGB.
        let backgrounds: [(String, [CGFloat])]
        let appearance: NSAppearance
    }

    private var samples: [Sample] = []
    /// The window background, resolved, under see-through backgrounds.
    private var base: [CGFloat] = [1, 1, 1, 1]

    /// The backgrounds `view` is drawn on, from the views behind it.
    private func backgrounds(behind view: NSView, tabFills: [ObjectIdentifier: [CGFloat]]) -> [(String, [CGFloat])] {
        var current: NSView? = view.superview
        while let v = current {
            let appearance = v.effectiveAppearance
            if let field = v as? NSTextField, field.drawsBackground, let color = field.backgroundColor {
                return [("text field background", Self.rgba(color, in: appearance))]
            }
            if let text = v as? NSTextView, text.drawsBackground {
                return [("text view background", Self.rgba(text.backgroundColor, in: appearance))]
            }
            if let clip = v as? NSClipView, clip.drawsBackground {
                return [("clip view background", Self.rgba(clip.backgroundColor, in: appearance))]
            }
            if let box = v as? NSBox, box.boxType == .custom, !box.isTransparent {
                return [("box fill", Self.rgba(box.fillColor, in: appearance))]
            }
            if v is MultiplePageView {
                return [("page", Self.rgba((v as! MultiplePageView).marginColor, in: appearance))]
            }
            if let tabs = v as? NSTabView, let fill = tabFills[ObjectIdentifier(tabs)] {
                return [("tab view fill", fill),
                        ("window background", Self.rgba(.windowBackgroundColor, in: appearance))]
            }
            current = v.superview
        }
        return [("window background", base)]
    }

    /// The text colors of an attributed string (its foreground runs),
    /// `fallback` where a run has none.
    private func colors(of text: NSAttributedString, fallback: NSColor) -> [NSColor] {
        var result: [NSColor] = []
        guard text.length > 0 else { return result }
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let run = (text.string as NSString).substring(with: range)
            if run.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            result.append((value as? NSColor) ?? fallback)
        }
        return result
    }

    private func collect(_ view: NSView, tabFills: [ObjectIdentifier: [CGFloat]], rowBackgrounds: [(String, [CGFloat])]?,
                         path: String) {
        guard !view.isHidden else { return }
        let place = path + "/" + String(describing: type(of: view))
            + (view.identifier.map { "(\($0.rawValue))" } ?? "")
        let backs = { rowBackgrounds ?? self.backgrounds(behind: view, tabFills: tabFills) }
        switch view {
        case let table as NSTableView:
            collectTable(table, tabFills: tabFills, path: place)
            return
        case let text as NSTextView where !text.isFieldEditor:
            let own: [(String, [CGFloat])] = text.drawsBackground
                ? [("text view background", Self.rgba(text.backgroundColor, in: text.effectiveAppearance))] : backs()
            for color in colors(of: text.textStorage ?? NSAttributedString(), fallback: text.textColor ?? .textColor)
                + [text.textColor ?? .textColor] {
                samples.append(Sample(place: place, color: color, backgrounds: own, appearance: text.effectiveAppearance))
            }
        case let field as NSTextField:
            guard field.isEnabled, !field.stringValue.isEmpty else { break }
            let own: [(String, [CGFloat])] = field.drawsBackground && field.backgroundColor != nil
                ? [("field background", Self.rgba(field.backgroundColor!, in: field.effectiveAppearance))]
                : (field.isEditable || field.isBezeled
                   ? [("text background", Self.rgba(.textBackgroundColor, in: field.effectiveAppearance))] : backs())
            for color in colors(of: field.attributedStringValue, fallback: field.textColor ?? .labelColor) {
                samples.append(Sample(place: place + " \"\(field.stringValue.prefix(30))\"", color: color,
                                      backgrounds: own, appearance: field.effectiveAppearance))
            }
        case let popUp as NSPopUpButton:
            guard popUp.isEnabled, !popUp.titleOfSelectedItem.isNilOrEmpty else { break }
            samples.append(Sample(place: place + " \"\(popUp.titleOfSelectedItem ?? "")\"", color: .controlTextColor,
                                  backgrounds: [("control", Self.rgba(.controlColor, in: popUp.effectiveAppearance))],
                                  appearance: popUp.effectiveAppearance))
        case let button as NSButton:
            guard button.isEnabled, !button.title.isEmpty else { break }
            let fallback = button.contentTintColor ?? .controlTextColor
            let titleColors = colors(of: button.attributedTitle, fallback: fallback)
            // A bordered push button draws its title on its own bezel.
            let bezel = button.isBordered && [.push, .flexiblePush].contains(button.bezelStyle)
            let own: [(String, [CGFloat])] = bezel
                ? [("button bezel", Self.rgba(.controlColor, in: button.effectiveAppearance))] : backs()
            for color in titleColors {
                samples.append(Sample(place: place + " \"\(button.title.prefix(30))\"", color: color, backgrounds: own,
                                      appearance: button.effectiveAppearance))
            }
        default:
            break
        }
        for sub in view.subviews {
            collect(sub, tabFills: tabFills, rowBackgrounds: rowBackgrounds, path: place)
        }
    }

    /// Every row's cells, on each row color the table can draw behind them.
    private func collectTable(_ table: NSTableView, tabFills: [ObjectIdentifier: [CGFloat]], path: String) {
        let appearance = table.effectiveAppearance
        var rowColors: [(String, [CGFloat])] = table.usesAlternatingRowBackgroundColors
            ? NSColor.alternatingContentBackgroundColors.enumerated().map {
                ("row color \($0.offset)", Self.rgba($0.element, in: appearance)) }
            : [("table background", Self.rgba(table.backgroundColor, in: appearance))]
        rowColors.append(("selected row (window not key)",
                          Self.rgba(.unemphasizedSelectedContentBackgroundColor, in: appearance)))
        for column in table.tableColumns where !column.isHidden {
            let header = column.headerCell
            samples.append(Sample(place: path + " header \"\(header.stringValue)\"",
                                  color: header.textColor ?? .headerTextColor,
                                  backgrounds: [("header", Self.rgba(.controlBackgroundColor, in: appearance)),
                                                ("window background", Self.rgba(.windowBackgroundColor, in: appearance))],
                                  appearance: appearance))
        }
        for row in 0..<table.numberOfRows {
            for column in 0..<table.numberOfColumns {
                guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) else { continue }
                collect(cell, tabFills: tabFills, rowBackgrounds: rowColors, path: path + "[row \(row)]")
            }
        }
    }

    /// The color a tab view fills its content with, read from a drawing
    /// of the whole window frame (a tab view drawn alone comes out clear):
    /// a pixel inside its content area that no subview covers.
    private func tabFill(of tabs: NSTabView) throws -> [CGFloat] {
        let frameView = try XCTUnwrap(tabs.window?.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let content = tabs.contentRect
        let covered = (tabs.selectedTabViewItem?.view?.subviews ?? []).map {
            tabs.convert($0.frame, from: $0.superview)
        }
        let scaleX = CGFloat(rep.pixelsWide) / frameView.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / frameView.bounds.height
        for y in stride(from: content.minY + 8, to: content.maxY - 8, by: 3) {
            for x in stride(from: content.minX + 8, to: content.maxX - 8, by: 3) {
                let point = NSPoint(x: x, y: y)
                if covered.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) { continue }
                let inFrame = frameView.convert(point, from: tabs)
                // Bitmap rows start at the top.
                let row = frameView.isFlipped ? inFrame.y : frameView.bounds.height - inFrame.y
                guard let color = rep.colorAt(x: Int(inFrame.x * scaleX), y: Int(row * scaleY))?.usingColorSpace(.sRGB)
                else { continue }
                XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01, "the window drawing is see-through at \(point)")
                return [color.redComponent, color.greenComponent, color.blueComponent, 1]
            }
        }
        XCTFail("no uncovered pixel in the tab view")
        return base
    }

    /// Checks every text sample in `window`, in light and dark mode.
    private func check(_ window: NSWindow, _ name: String, prepare: () throws -> Void = {}) throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearanceName)
            try prepare()
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            base = Self.rgba(window.backgroundColor, in: content.effectiveAppearance)
            var fills: [ObjectIdentifier: [CGFloat]] = [:]
            func findTabs(_ view: NSView) throws {
                if let tabs = view as? NSTabView { fills[ObjectIdentifier(tabs)] = try tabFill(of: tabs) }
                for sub in view.subviews { try findTabs(sub) }
            }
            try findTabs(content)
            samples = []
            collect(content, tabFills: fills, rowBackgrounds: nil, path: name)
            XCTAssertFalse(samples.isEmpty, "\(name): no text found")
            for sample in samples {
                let text = Self.rgba(sample.color, in: sample.appearance)
                for (backName, back) in sample.backgrounds {
                    let value = Self.ratio(text, over: back, base: base)
                    XCTAssertGreaterThanOrEqual(value, 4.5, String(format: "%@ (%@): %@ on %@ is %.2f:1",
                                                                   sample.place, appearanceName.rawValue,
                                                                   sample.color.description, backName, value))
                }
            }
        }
        window.appearance = nil
    }

    // MARK: The windows the audit covers

    func testDocumentWindowTextHasEnoughContrast() throws {
        let document = try XCTUnwrap(try NSDocumentController.shared.makeUntitledDocument(
            ofType: TextDocument.plainTextType) as? TextDocument)
        documents.append(document)
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? DocumentWindowController)
        document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Contrast check\n")
        let window = try XCTUnwrap(controller.window)
        try check(window, "document (Wrap to Window)")
        document.hasMultiplePages = true
        try check(window, "document (Wrap to Page)")
    }

    func testEverySettingsTabHasEnoughContrast() throws {
        let controller = SettingsWindowController()
        let window = controller.loadSettingsWindowIfNeeded()
        windows.append(window)
        let tabs = try XCTUnwrap(controller.tabView)
        for index in 0..<tabs.numberOfTabViewItems {
            tabs.selectTabViewItem(at: index)
            try check(window, "Settings > " + tabs.tabViewItem(at: index).label)
        }
        // The Keyboard tab while recording and after a refusal: the hint,
        // the warning and a changed row are on screen then.
        let tab = try XCTUnwrap(controller.keyboardTab)
        let menu = MainMenu.build()
        let print = try XCTUnwrap(Shortcuts.commandItems(in: menu).first { $0.command.id == "file.print" }).command
        let live = try XCTUnwrap(NSApp.mainMenu)
        Shortcuts.set(KeyShortcut("p", [.command, .shift]), for: print, applyingTo: live)
        defer { Shortcuts.restoreDefaults(applyingTo: live) }
        tab.reload()
        tabs.selectTabViewItem(at: tabs.numberOfTabViewItems - 1)
        tab.startRecording("file.save")
        try check(window, "Settings > Keyboard (recording)")
        try check(window, "Settings > Keyboard (refusal)") { tab.handle(.candidate(KeyShortcut("o"))) }
        tab.endRecording()
    }

    func testSelectLinePanelHasEnoughContrast() throws {
        let controller = LinePanelController()
        let panel = controller.loadPanelIfNeeded()
        windows.append(panel)
        try XCTUnwrap(controller.lineField).stringValue = "12"
        try check(panel, "Select Line")
    }

    /// The math itself: black on white is 21:1, mid gray on white about 4.5:1.
    func testContrastMath() {
        XCTAssertEqual(Self.ratio([0, 0, 0, 1], over: [1, 1, 1, 1], base: [1, 1, 1, 1]), 21, accuracy: 0.01)
        XCTAssertEqual(Self.ratio([0.463, 0.463, 0.463, 1], over: [1, 1, 1, 1], base: [1, 1, 1, 1]), 4.5, accuracy: 0.1)
        XCTAssertEqual(Self.ratio([0, 0, 0, 0], over: [1, 1, 1, 1], base: [1, 1, 1, 1]), 1, accuracy: 0.01)
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
