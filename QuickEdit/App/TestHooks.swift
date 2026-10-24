import Foundation

#if DEBUG
/// Launch-argument hooks for UI tests only; compiled out of Release builds.
///
/// The UI test runner is sandboxed and cannot write the fixture files, so it
/// cannot play "another app changed the file". With
/// `-QETestExternalWrite <path> <text> <seconds>` the app starts a separate
/// `/bin/sh` process after `<seconds>`, and that process (not QuickEdit)
/// writes `<text>` to `<path>` without file coordination, as another editor
/// would.
enum TestHooks {
    static func start(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "-QETestExternalWrite") else { return }
        guard index + 3 < arguments.count, let delay = Double(arguments[index + 3]) else {
            FileHandle.standardError.write(Data("QuickEdit: -QETestExternalWrite wants <path> <text> <seconds>\n".utf8))
            return
        }
        let path = arguments[index + 1], text = arguments[index + 2]
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s' \"$1\" > \"$2\"", "sh", text, path]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    FileHandle.standardError.write(Data("QuickEdit: test write to \(path) exited \(process.terminationStatus)\n".utf8))
                }
            } catch {
                FileHandle.standardError.write(Data("QuickEdit: test write to \(path) failed: \(error)\n".utf8))
            }
        }
    }
}
#endif
