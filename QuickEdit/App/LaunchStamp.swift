import AppKit

/// Launch timing for bench/run-bench.sh (contract `launch-stamp`).
/// Does nothing unless QUICKEDIT_LAUNCH_LOG (or FASTPAD_LAUNCH_LOG) names a file.
@MainActor
enum LaunchStamp {
    private static var mainNs: UInt64 = 0
    private static var armed = false

    private static let logPath: String? = {
        let env = ProcessInfo.processInfo.environment
        return env["QUICKEDIT_LAUNCH_LOG"] ?? env["FASTPAD_LAUNCH_LOG"]
    }()

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// Called first thing in main.swift.
    static func markMain() { mainNs = now() }

    /// Called when a document window is key and its text view is first
    /// responder. Waits for the end of the current main-loop turn (after
    /// Core Animation commits the window's first display), then stamps on the
    /// next turn.
    static func firstWindowReady() {
        guard logPath != nil, !armed else { return }
        armed = true
        // Order after Core Animation's commit observer (2000000).
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
                                                          false, 2_100_000) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { write(readyNs: now()) }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private static func write(readyNs: UInt64) {
        guard let logPath else { return }
        let line = "main_abs_ns=\(mainNs) ready_abs_ns=\(readyNs)\n"
        let url = URL(fileURLWithPath: logPath)
        do {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try Data(line.utf8).write(to: url)
            }
        } catch {
            FileHandle.standardError.write(Data("QuickEdit: launch log write failed at \(logPath): \(error)\n".utf8))
        }
    }
}
