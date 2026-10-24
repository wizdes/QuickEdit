// Fastpad launch benchmark — interleaved (round-robin), two-clock.
// Copied for QuickEdit from ~/work/Projects/Fastpad/bench/launchbench.swift on 2026-10-23; it now also sets QUICKEDIT_LAUNCH_LOG.
//
// Derived from the M0 research harness (launchbench2). Review-driven rules:
//  * Interleaved rounds: load drift charges every app equally.
//  * Explicit discard rules, ALL logged, never silent:
//      - warmup rounds (first-after-codesign lives there)
//      - samples < 50ms  -> MISFIRE (pre-existing window / quit not settled)
//  * Two clocks, one domain: harness t0 and the app's keystroke-ready stamp
//    are both CLOCK_UPTIME_RAW absolute, so click->keystroke-ready is a true
//    cross-process measurement for Fastpad. Competitors report window-visible
//    only (their internals aren't observable); the acceptance bar is
//    OUR keystroke-ready < THEIR window-visible.
//
// Usage: launchbench [--runs N] [--warmups N] [--csv out.csv] \
//        [--ready-log Label]... [--arg Label=value]...  Label=/path/App.app ...
//   --ready-log marks a target whose FASTPAD_LAUNCH_LOG should be read for
//   ready_abs_ns (Fastpad builds only). Repeatable: proof 1b interleaves the
//   SAME app launched blank against the same app launched with a 5GB file as
//   its argument, and both need their ready stamp.
//   --arg passes a launch argument to one target (repeat for more than one).
//   Two targets may share a bundle id — rounds are strictly sequential and
//   each target is quit before the next runs, so they never overlap.

import AppKit
import CoreGraphics
import Darwin

@inline(__always) func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b &- a) / 1_000_000.0 }
func eprint(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func loadAvg() -> Double {
    var l = [Double](repeating: 0, count: 3)
    return getloadavg(&l, 3) > 0 ? l[0] : -1
}

final class Target {
    let label: String, url: URL, bid: String
    var windowSamples: [Double] = []
    var readySamples: [Double] = []
    var discards: [(round: Int, value: Double, reason: String)] = []
    /// Runs where the window appeared but the ready stamp never did — counted
    /// per target, since more than one target can carry a ready log.
    var readyMissing = 0
    init(label: String, url: URL, bid: String) { self.label = label; self.url = url; self.bid = bid }

    func running() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bid)
    }
    func quitAndWait(_ deadline: Double = 12.0) {
        for a in running() { a.terminate() }
        let s = nowNs()
        while !running().isEmpty && ms(s, nowNs()) < deadline * 1000 { usleep(20_000) }
        for a in running() {
            eprint("  ! \(bid) ignored terminate; SIGKILL \(a.processIdentifier)")
            a.forceTerminate()
        }
        let s2 = nowNs()
        while !running().isEmpty && ms(s2, nowNs()) < 5000 { usleep(20_000) }
    }
}

var runs = 15, warmups = 2, pollUs: UInt32 = 500
var holdS = 0.8, settleS = 1.2, timeoutS = 30.0
let misfireThresholdMs = 50.0
var csvPath: String? = nil
var readyLogLabels: Set<String> = []
var targetArgs: [String: [String]] = [:]
var specs: [String] = []

var argv = Array(CommandLine.arguments.dropFirst()); var i = 0
while i < argv.count {
    let a = argv[i]; func next() -> String { i += 1; return argv[i] }
    switch a {
    case "--runs": runs = Int(next())!
    case "--warmups": warmups = Int(next())!
    case "--hold": holdS = Double(next())!
    case "--settle": settleS = Double(next())!
    case "--poll-us": pollUs = UInt32(next())!
    case "--csv": csvPath = next()
    case "--ready-log": readyLogLabels.insert(next())
    case "--arg":
        let kv = next().split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { eprint("--arg wants Label=value"); exit(2) }
        targetArgs[kv[0], default: []].append(kv[1])
    default: specs.append(a) // "Label=/path/to/App.app"
    }
    i += 1
}

var targets: [Target] = []
for s in specs {
    let parts = s.split(separator: "=", maxSplits: 1).map(String.init)
    let path = parts.count == 2 ? parts[1] : parts[0]
    let url = URL(fileURLWithPath: path)
    guard let b = Bundle(url: url), let bid = b.bundleIdentifier else {
        eprint("cannot read bundle id: \(path)"); exit(2)
    }
    targets.append(Target(label: parts.count == 2 ? parts[0] : url.deletingPathExtension().lastPathComponent,
                          url: url, bid: bid))
}
guard !targets.isEmpty else {
    eprint("usage: launchbench [flags] Label=/path/App.app ...")
    exit(2)
}

let readyLogPath = NSTemporaryDirectory() + "fastpad-bench-ready-\(getpid()).log"

func windowRows() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                kCGNullWindowID) as? [[String: Any]]) ?? []
}

struct RunResult {
    var windowMs: Double
    var readyMs: Double? // click -> keystroke-ready (ready-log target only)
}

func oneRun(_ t: Target) -> RunResult? {
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    cfg.addsToRecentItems = false
    cfg.createsNewApplicationInstance = false
    let wantsReady = readyLogLabels.contains(t.label)
    // Cleared for EVERY target, not only the one being read: two Fastpad
    // targets share the log path, so a stale line from the previous run would
    // be scored as this one's.
    try? FileManager.default.removeItem(atPath: readyLogPath)
    cfg.arguments = targetArgs[t.label] ?? []
    // Identical environment for EVERY target — cfg.environment replaces the
    // launched process's environment, so setting it only for one app would be
    // an uncontrolled asymmetry in the exact comparison being scored.
    // QuickEdit reads QUICKEDIT_LAUNCH_LOG (or FASTPAD_LAUNCH_LOG); both name the same file.
    cfg.environment = ["FASTPAD_LAUNCH_LOG": readyLogPath, "QUICKEDIT_LAUNCH_LOG": readyLogPath]
    var lpid: Int32 = -1
    let sem = DispatchSemaphore(value: 0)
    let t0 = nowNs()
    NSWorkspace.shared.openApplication(at: t.url, configuration: cfg) { app, _ in
        if let app = app { lpid = app.processIdentifier }
        sem.signal()
    }
    var t1: UInt64 = 0, pid: Int32 = -1
    let deadline = t0 &+ UInt64(timeoutS * 1e9)
    poll: while nowNs() < deadline {
        if pid < 0 {
            if lpid > 0 { pid = lpid } else if let a = t.running().first { pid = a.processIdentifier }
        }
        if pid > 0 {
            for w in windowRows() {
                guard (w[kCGWindowOwnerPID as String] as? Int).map({ Int32($0) }) == pid,
                      (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
                if let al = w[kCGWindowAlpha as String] as? Double, al <= 0.01 { continue }
                guard let b = w[kCGWindowBounds as String] as? [String: Any],
                      let wd = b["Width"] as? Double, let ht = b["Height"] as? Double,
                      wd >= 120, ht >= 80 else { continue }
                t1 = nowNs(); break poll
            }
        }
        usleep(pollUs)
    }
    _ = sem.wait(timeout: .now() + 5)
    if t1 == 0 { return nil }
    var result = RunResult(windowMs: ms(t0, t1), readyMs: nil)

    if wantsReady {
        // The ready stamp lands with (or a frame after) the first text frame;
        // poll the log briefly.
        let readyDeadline = nowNs() &+ UInt64(3e9)
        while nowNs() < readyDeadline {
            if let content = try? String(contentsOfFile: readyLogPath, encoding: .utf8),
               let line = content.split(separator: "\n").first(where: { $0.hasPrefix("main_abs_ns=") }),
               let readyField = line.split(separator: " ").first(where: { $0.hasPrefix("ready_abs_ns=") }),
               let readyNs = UInt64(readyField.dropFirst("ready_abs_ns=".count)) {
                result.readyMs = ms(t0, readyNs)
                break
            }
            usleep(5_000)
        }
    }
    return result
}

// ---------------------------------------------------------------- run

eprint("interleaved: \(targets.map(\.label).joined(separator: ", "))")
eprint(String(format: "warmups=%d runs=%d misfire<%.0fms load1=%.2f",
              warmups, runs, misfireThresholdMs, loadAvg()))
for t in targets {
    if !t.running().isEmpty {
        eprint("NOTE: \(t.label) was already running at bench start — quitting it; its restore state is whatever it was.")
    }
    t.quitAndWait()
}
Thread.sleep(forTimeInterval: settleS)

func wantsReady(_ t: Target) -> Bool { readyLogLabels.contains(t.label) }

func benchRound(_ round: Int, label: String, measured: Bool) {
    var row = String(format: "round %2d %@ %@", round, label, measured ? "     " : "[warm]")
    for t in targets {
        // Replenish rounds only re-measure targets still short of n.
        if measured && label == "[extra]" && t.windowSamples.count >= runs {
            continue
        }
        if let r = oneRun(t) {
            if !measured {
                row += String(format: "  %@=%6.1f(w)", t.label, r.windowMs)
            } else if r.windowMs < misfireThresholdMs {
                // A sub-50ms "launch" is physically impossible (the measured
                // blank-app floor is ~150ms across four stacks): it means a
                // pre-existing window was detected, i.e. the run is invalid —
                // not merely fast. Logged, counted, and replenished below so
                // discards never shrink n.
                t.discards.append((round, r.windowMs, "misfire<\(misfireThresholdMs)ms"))
                row += String(format: "  %@=%6.1f(DISCARD)", t.label, r.windowMs)
            } else {
                t.windowSamples.append(r.windowMs)
                if wantsReady(t) {
                    if let rd = r.readyMs {
                        t.readySamples.append(rd)
                        row += String(format: "  %@=%6.1f(rdy %.1f)", t.label, r.windowMs, rd)
                    } else {
                        t.readyMissing += 1
                        row += String(format: "  %@=%6.1f(rdy MISSING)", t.label, r.windowMs)
                    }
                } else {
                    row += String(format: "  %@=%6.1f", t.label, r.windowMs)
                }
            }
        } else {
            t.discards.append((round, -1, "timeout"))
            row += "  \(t.label)=TIMEOUT"
        }
        Thread.sleep(forTimeInterval: holdS)
        t.quitAndWait()
        Thread.sleep(forTimeInterval: settleS)
    }
    eprint(row + String(format: "   [load %.2f]", loadAvg()))
}

for round in 1...(warmups + runs) {
    benchRound(round, label: "/\(warmups + runs)", measured: round > warmups)
}
// Replenishment: discards and timeouts must not shrink the sample count —
// run extra interleaved rounds (bounded) until every target has n samples.
var extra = 0
while extra < 8 && targets.contains(where: { $0.windowSamples.count < runs }) {
    extra += 1
    benchRound(warmups + runs + extra, label: "[extra]", measured: true)
}
if targets.contains(where: { $0.windowSamples.count < runs }) {
    eprint("WARNING: sample count below n=\(runs) after \(extra) replenish rounds — reported n is honest, see CSV")
}

func stats(_ samples: [Double]) -> (n: Int, med: Double, min: Double, max: Double, mean: Double, sd: Double)? {
    let s = samples.sorted()
    guard !s.isEmpty else { return nil }
    let med = s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    let mean = s.reduce(0, +) / Double(s.count)
    let sd = s.count > 1 ? (s.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(s.count - 1)).squareRoot() : 0
    return (s.count, med, s.first!, s.last!, mean, sd)
}

eprint("")
var out = "label,metric,n,median_ms,min_ms,max_ms,mean_ms,sd_ms,discards\n"
for t in targets {
    if let w = stats(t.windowSamples) {
        out += String(format: "%@,window_visible,%d,%.1f,%.1f,%.1f,%.1f,%.1f,%d\n",
                      t.label, w.n, w.med, w.min, w.max, w.mean, w.sd, t.discards.count)
        eprint(String(format: "%-14@ window-visible n=%d median %6.1f  min %6.1f  max %6.1f  sd %5.1f  discards=%d",
                      t.label as NSString, w.n, w.med, w.min, w.max, w.sd, t.discards.count))
    }
    if let r = stats(t.readySamples) {
        out += String(format: "%@,keystroke_ready,%d,%.1f,%.1f,%.1f,%.1f,%.1f,%d\n",
                      t.label, r.n, r.med, r.min, r.max, r.mean, r.sd, t.readyMissing)
        eprint(String(format: "%-14@ KEYSTROKE-READY n=%d median %6.1f  min %6.1f  max %6.1f  sd %5.1f  missing=%d",
                      t.label as NSString, r.n, r.med, r.min, r.max, r.sd, t.readyMissing))
    }
    for d in t.discards {
        eprint("  discarded: \(t.label) round \(d.round) \(String(format: "%.1f", d.value))ms (\(d.reason))")
    }
}
print(out, terminator: "")
if let c = csvPath { try? out.write(toFile: c, atomically: true, encoding: .utf8) }
try? FileManager.default.removeItem(atPath: readyLogPath)
