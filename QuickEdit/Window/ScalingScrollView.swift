import AppKit

/// The window's scroll view in both wrap modes, with zoom through
/// NSScrollView magnification. Port of reference/apple/ScalingScrollView.m.
final class ScalingScrollView: NSScrollView, NSMenuItemValidation {
    /// TextEdit's range: 25% to 1600% (ScalingScrollView.m:55-60).
    static let minimumScale: CGFloat = 0.25
    static let maximumScale: CGFloat = 16.0

    /// The menu zooms animate, as in TextEdit. Unit tests turn this off so
    /// each step lands at once.
    static var animatesZoom = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowsMagnification = true
        minMagnification = Self.minimumScale
        maxMagnification = Self.maximumScale
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ScalingScrollView is built in code") }

    var scaleFactor: CGFloat {
        get { magnification }
        set { magnification = newValue }
    }

    /// Zoom In doubles; from just under to just over 50% it snaps to 100%
    /// (ScalingScrollView.m:80-84).
    static func zoomInScale(from scale: CGFloat) -> CGFloat {
        min((scale > 0.4 && scale < 0.6) ? 1.0 : scale * 2.0, maximumScale)
    }

    /// Zoom Out halves; from just under to just over 200% it snaps to 100%
    /// (ScalingScrollView.m:86-90).
    static func zoomOutScale(from scale: CGFloat) -> CGFloat {
        max((scale > 1.8 && scale < 2.2) ? 1.0 : scale / 2.0, minimumScale)
    }

    private func zoom(to scale: CGFloat) {
        if Self.animatesZoom {
            animator().magnification = scale
        } else {
            magnification = scale
        }
    }

    @objc func zoomToActualSize(_ sender: Any?) {
        zoom(to: 1.0)
    }

    @objc func zoomIn(_ sender: Any?) {
        zoom(to: Self.zoomInScale(from: magnification))
    }

    @objc func zoomOut(_ sender: Any?) {
        zoom(to: Self.zoomOutScale(from: magnification))
    }

    /// Zoom In stops at 1600% and Zoom Out at 25%. TextEdit leaves both on
    /// and the step does nothing; QuickEdit greys them out at the limit.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(zoomIn(_:)): return magnification < Self.maximumScale - 0.0001
        case #selector(zoomOut(_:)): return magnification > Self.minimumScale + 0.0001
        case #selector(zoomToActualSize(_:)): return true
        default: return true
        }
    }

    /// The text area's size. NSScrollView's own value leaves out the
    /// vertical ruler (the line-number gutter, 1.2.0), which takes its
    /// width from the clip view; this one does not.
    override var contentSize: NSSize {
        var size = super.contentSize
        if hasVerticalRuler, rulersVisible, let ruler = verticalRulerView {
            size.width = max(0, size.width - ruler.requiredThickness)
        }
        return size
    }

    /// The line-number gutter (1.2.0) is left out: it only helps the eye,
    /// VoiceOver reads the text itself, and as a ruler with no action it
    /// fails the accessibility audit ("Action is missing", measured
    /// 2026-10-26). Marking the ruler as no accessibility element instead
    /// made AppKit report no children at all, so the text view vanished.
    override func accessibilityChildren() -> [Any]? {
        guard let children = super.accessibilityChildren(), let ruler = verticalRulerView else {
            return super.accessibilityChildren()
        }
        return children.filter { ($0 as AnyObject) !== ruler }
    }

    /// AppKit turns off live-resize content preservation for NSScrollView
    /// subclasses; turn it back on (ScalingScrollView.m:94-96).
    override var preservesContentDuringLiveResize: Bool { drawsBackground }
}
