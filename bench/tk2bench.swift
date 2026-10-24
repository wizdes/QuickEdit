// M8 n5: TextKit 1 vs TextKit 2 benchmark for vote V1 (docs/decisions.md).
// Standalone: no QuickEdit code. Build with `xcrun swiftc -O`; bench/tk2bench.sh drives it.
//
// Worker mode (one engine, one fixture, one fresh process):
//   tk2bench --worker tk1|tk2 --file <path> --run <n> [--typing 200] [--type-budget-s 120] [--mem-cap-mib 4096]
//   Prints `ROW,<engine>,<fixture>,<run>,<metric>,<value>` lines on stdout.
// Summary mode:
//   tk2bench --summarize <csv>   prints medians per engine, fixture and metric.
//
// Each timed step is: the edit, then layout of the visible rect, then a display
// pass (`window.displayIfNeeded()` plus `CATransaction.flush()`). The three parts
// are also reported on their own. `draws_*` counts calls to the text view's
// `draw(_:)`, so a run shows whether AppKit really drew (it may not while the
// screen is locked or the window is hidden). TextKit 2 draws text in fragment
// layers, so its `draws_*` count can be lower than TextKit 1's for the same work.

import AppKit
import QuartzCore
import Darwin

@inline(__always) func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b &- a) / 1_000_000.0 }
func eprint(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func fail(_ s: String) -> Never { eprint("FAILED: " + s); exit(1) }

/// Current and lifetime-peak physical footprint in MiB (task_info TASK_VM_INFO).
func footprint() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { fail("task_info returned \(kr)") }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted()
    let rank = max(1, Int((p * Double(s.count)).rounded(.up)))
    return s[min(rank, s.count) - 1]
}

final class CountingTextView: NSTextView {
    var draws = 0
    override func draw(_ dirtyRect: NSRect) { draws += 1; super.draw(dirtyRect) }
}

// MARK: - summary mode

func summarize(_ path: String) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    var values: [String: [Double]] = [:]   // "fixture|metric|engine" -> samples
    var fixtures: [String] = [], metrics: [String] = []
    for line in text.split(separator: "\n").dropFirst() {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 5, let v = Double(f[4]) else { fail("bad CSV line: \(line)") }
        let (engine, fixture, metric) = (f[0], f[1], f[3])
        if !fixtures.contains(fixture) { fixtures.append(fixture) }
        if !metrics.contains(metric) { metrics.append(metric) }
        values["\(fixture)|\(metric)|\(engine)", default: []].append(v)
    }
    func cell(_ k: String) -> String {
        guard let xs = values[k], !xs.isEmpty else { return "-" }
        let med = percentile(xs, 0.5)
        if xs.count == 1 { return String(format: "%.2f", med) }
        return String(format: "%.2f [%.2f-%.2f] n=%d", med, xs.min()!, xs.max()!, xs.count)
    }
    let pad = { (s: String, w: Int) in s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
    print("median [min-max] over runs; times in ms, memory in MiB")
    for fx in fixtures {
        print("\n== \(fx)")
        print(pad("metric", 22) + pad("TextKit 1", 34) + "TextKit 2")
        for m in metrics where values["\(fx)|\(m)|tk1"] != nil || values["\(fx)|\(m)|tk2"] != nil {
            print(pad(m, 22) + pad(cell("\(fx)|\(m)|tk1"), 34) + cell("\(fx)|\(m)|tk2"))
        }
    }
}

// MARK: - worker mode

var engine = "", file = "", run = 0, typing = 200
var typeBudgetS = 120.0, memCapMiB = 4096.0
var args = Array(CommandLine.arguments.dropFirst()); var ai = 0
func nextArg() -> String { ai += 1; guard ai < args.count else { fail("missing value after \(args[ai - 1])") }; return args[ai] }
while ai < args.count {
    switch args[ai] {
    case "--summarize": summarize(nextArg()); exit(0)
    case "--worker": engine = nextArg()
    case "--file": file = nextArg()
    case "--run": run = Int(nextArg()) ?? 0
    case "--typing": typing = Int(nextArg()) ?? 200
    case "--type-budget-s": typeBudgetS = Double(nextArg()) ?? 120
    case "--mem-cap-mib": memCapMiB = Double(nextArg()) ?? 4096
    default: fail("unknown argument \(args[ai])")
    }
    ai += 1
}
guard engine == "tk1" || engine == "tk2", !file.isEmpty, typing > 0 else {
    fail("usage: tk2bench --worker tk1|tk2 --file <path> --run <n> [--typing 200] | --summarize <csv>")
}
let fixtureName = (file as NSString).lastPathComponent

func emit(_ metric: String, _ value: Double) {
    print("ROW,\(engine),\(fixtureName),\(run),\(metric),\(String(format: "%.3f", value))")
    fflush(stdout)
}

@MainActor final class Bench: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var textView: CountingTextView!
    var tk1LM: NSLayoutManager?        // TextKit 1 only; never touch textView.layoutManager on TextKit 2
    var tk1Container: NSTextContainer?

    func applicationDidFinishLaunching(_ n: Notification) {
        DispatchQueue.main.async { self.go(); exit(0) }
    }

    func makeWindow() {
        let font = NSFont.userFixedPitchFont(ofSize: 0) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let xAdvance = ("x" as NSString).size(withAttributes: [.font: font]).width
        let lineH = (font.ascender - font.descender + font.leading).rounded(.up)
        let padding: CGFloat = 5   // NSTextContainer default lineFragmentPadding
        let content = NSSize(width: (90 * xAdvance + 2 * padding).rounded(.up), height: 30 * lineH)
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: content),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: content))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let size = scroll.contentSize
        let frame = NSRect(origin: .zero, size: size)

        if engine == "tk1" {
            let storage = NSTextStorage()
            let lm = NSLayoutManager()
            lm.allowsNonContiguousLayout = true
            storage.addLayoutManager(lm)
            let tc = NSTextContainer(size: NSSize(width: size.width, height: .greatestFiniteMagnitude))
            tc.widthTracksTextView = true
            lm.addTextContainer(tc)
            textView = CountingTextView(frame: frame, textContainer: tc)
            tk1LM = lm; tk1Container = tc
        } else {
            textView = CountingTextView(usingTextLayoutManager: true)
            textView.frame = frame
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.size = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        }
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        scroll.documentView = textView
        window.contentView = scroll
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(textView)
        window.displayIfNeeded()
        emit("font_size", Double(font.pointSize))
    }

    var tk2Kept: Bool { textView.textLayoutManager != nil }

    /// Lays out the text view's visible rect: TextKit 1 `ensureLayout(forBoundingRect:)`,
    /// TextKit 2 `textViewportLayoutController.layoutViewport()`.
    func layoutVisible() {
        if let lm = tk1LM, let tc = tk1Container {
            var r = textView.visibleRect
            r.origin.x -= textView.textContainerOrigin.x
            r.origin.y -= textView.textContainerOrigin.y
            lm.ensureLayout(forBoundingRect: r, in: tc)
        } else {
            guard let tlm = textView.textLayoutManager else { fail("TextKit 2 view lost its textLayoutManager (fell back to TextKit 1)") }
            tlm.textViewportLayoutController.layoutViewport()
        }
    }

    func displayPass() {
        window.layoutIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    /// Runs `edit`, then visible layout, then a display pass. Returns (edit, layout, display) ms.
    func timed(_ edit: () -> Void) -> (Double, Double, Double) {
        let t0 = nowNs(); edit()
        let t1 = nowNs(); layoutVisible()
        let t2 = nowNs(); displayPass()
        let t3 = nowNs()
        return (ms(t0, t1), ms(t1, t2), ms(t2, t3))
    }

    func idle(_ s: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }

    func memory(_ phase: String) {
        let m = footprint()
        emit("mem_\(phase)_mib", m.now)
        emit("peak_\(phase)_mib", m.peak)
    }

    func go() {
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        emit("screen_locked", locked ? 1 : 0)
        makeWindow()
        idle(0.2)
        emit("window_visible", window.occlusionState.contains(.visible) ? 1 : 0)
        memory("start")

        // Read and decode outside the timed open: both engines get the same String.
        let r0 = nowNs()
        guard let data = FileManager.default.contents(atPath: file),
              let string = String(data: data, encoding: .utf8) else { fail("cannot read \(file) as UTF-8") }
        let attrs: [NSAttributedString.Key: Any] = [.font: textView.font!, .foregroundColor: NSColor.textColor]
        emit("read_ms", ms(r0, nowNs()))

        // Open: put the text into the storage, lay out the first screen, display.
        var d = textView.draws
        let (oe, ol, od) = timed {
            let ts = textView.textStorage!
            ts.beginEditing()
            ts.replaceCharacters(in: NSRange(location: 0, length: ts.length), with: string)
            ts.setAttributes(attrs, range: NSRange(location: 0, length: ts.length))
            ts.endEditing()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        emit("open_ms", oe + ol + od); emit("open_set_ms", oe); emit("open_layout_ms", ol); emit("open_display_ms", od)
        emit("draws_open", Double(textView.draws - d))
        memory("open")
        let len = textView.textStorage!.length
        emit("chars", Double(len))
        idle(0.2)

        // Jump to end: select the last character and scroll it into view.
        d = textView.draws
        let (je, jl, jd) = timed {
            let last = NSRange(location: len - 1, length: 1)
            textView.setSelectedRange(last)
            textView.scrollRangeToVisible(last)
        }
        emit("jump_ms", je + jl + jd); emit("jump_scroll_ms", je); emit("jump_layout_ms", jl); emit("jump_display_ms", jd)
        emit("draws_jump", Double(textView.draws - d))
        let vis = textView.visibleRect
        emit("jump_at_end", textView.bounds.maxY - vis.maxY < 4 * (textView.font!.boundingRectForFont.height) ? 1 : 0)
        emit("doc_height_px", Double(textView.bounds.height))
        memory("jump")
        idle(0.2)

        // Typing at the end: one character per insertText, each followed by layout and display.
        textView.setSelectedRange(NSRange(location: len, length: 0))
        displayPass()
        d = textView.draws
        var samples: [Double] = []
        // Stop early, and say so, if typing runs past the time budget or the footprint
        // passes the memory cap: on this 8 GiB Mac a runaway engine otherwise fills
        // swap until the kernel kills it (seen with TextKit 2 on the long line).
        var stop = 0   // 0 all keys typed, 1 time budget, 2 memory cap
        let typeStart = nowNs()
        for i in 0..<typing {
            let ch = i % 40 == 39 ? " " : String(UnicodeScalar(UInt8(97 + i % 26)))
            let (e, l, dp) = timed { textView.insertText(ch, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            samples.append(e + l + dp)
            idle(0.001)   // untimed: let deferred work run between keystrokes, as idle time would
            if ms(typeStart, nowNs()) > typeBudgetS * 1000 { stop = 1; break }
            if footprint().now > memCapMiB { stop = 2; break }
        }
        emit("type_keys_done", Double(samples.count))
        emit("type_stop_reason", Double(stop))
        emit("type_total_s", ms(typeStart, nowNs()) / 1000)
        if stop != 0 {
            eprint("WARNING: \(engine) \(fixtureName): typing stopped after \(samples.count) of \(typing) keys (" +
                   (stop == 1 ? "time budget \(typeBudgetS) s" : "memory cap \(memCapMiB) MiB") + "); typing numbers cover those keys only")
        }
        guard textView.textStorage!.length == len + samples.count else {
            fail("typing: expected \(len + samples.count) chars, have \(textView.textStorage!.length)")
        }
        emit("type_p50_ms", percentile(samples, 0.5))
        emit("type_p95_ms", percentile(samples, 0.95))
        emit("type_max_ms", samples.max()!)
        emit("type_mean_ms", samples.reduce(0, +) / Double(samples.count))
        emit("draws_type", Double(textView.draws - d))
        memory("type")
        emit("tk2_kept", tk2Kept ? 1 : 0)
        if engine == "tk2" && !tk2Kept { fail("TextKit 2 view fell back to TextKit 1 during the run") }
        if engine == "tk1" && tk2Kept { fail("TextKit 1 view has a textLayoutManager") }
        window.close()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let bench = Bench()
    app.delegate = bench
    app.run()
}
