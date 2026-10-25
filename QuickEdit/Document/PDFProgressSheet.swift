import AppKit

/// The sheet a long PDF write shows (M8 n6): "Exporting “name” as PDF…",
/// a progress bar and Cancel. It shows only when the write is still running
/// after `delay`, so short writes show nothing. While shown, a timer reads
/// the job's progress 10 times a second; it stops with the sheet.
@MainActor
final class PDFProgressSheet: NSObject {
    /// How long a write runs before the sheet shows (the M8 brief: "for
    /// anything over 1 s"). Tests set 0.
    static var delay: TimeInterval = 1.0

    private let job: PDFJob
    let panel: NSPanel
    private let progress: NSProgressIndicator
    private let label: NSTextField
    private let cancelButton: NSButton
    private var showTimer: Timer?
    private var progressTimer: Timer?
    private weak var parent: NSWindow?
    private var finished = false

    init(job: PDFJob, title: String) {
        self.job = job
        // Standard alert-sheet sizes: 20 pt edges, a 13 pt label, a
        // regular bar, a regular push button.
        let content = NSRect(x: 0, y: 0, width: 380, height: 112)
        panel = NSPanel(contentRect: content, styleMask: [.titled, .docModalWindow], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 20, y: 76, width: 340, height: 17)
        label.lineBreakMode = .byTruncatingMiddle
        progress = NSProgressIndicator(frame: NSRect(x: 20, y: 48, width: 340, height: 20))
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.frame = NSRect(x: 278, y: 12, width: 88, height: 32)
        cancelButton.keyEquivalent = "\u{1B}"
        super.init()
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        let view = NSView(frame: content)
        view.addSubview(label)
        view.addSubview(progress)
        view.addSubview(cancelButton)
        panel.contentView = view
    }

    /// Shows the sheet on `window` after `delay`, if the write still runs.
    /// No window: nothing shows (the write still runs and can be cancelled
    /// by closing the document).
    func schedule(on window: NSWindow?) {
        guard let window else { return }
        parent = window
        let timer = Timer(timeInterval: Self.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        }
        showTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func show() {
        showTimer = nil
        guard !finished, let parent else { return }
        progress.doubleValue = job.fraction
        parent.beginSheet(panel)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.progress.doubleValue = self.job.fraction
            }
        }
        progressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func cancel(_ sender: Any?) {
        job.cancel()
        cancelButton.isEnabled = false
        label.stringValue = "Cancelling\u{2026}"
    }

    /// The write ended (done, failed or cancelled): stop the timers and
    /// take the sheet down.
    func finish() {
        finished = true
        showTimer?.invalidate()
        showTimer = nil
        progressTimer?.invalidate()
        progressTimer = nil
        if let parent, panel.sheetParent === parent {
            parent.endSheet(panel)
        }
        panel.orderOut(nil)
    }
}
