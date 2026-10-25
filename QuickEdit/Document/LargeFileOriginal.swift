import Foundation

/// An APFS clone of a large file, taken before the file is read (M8
/// review rows 14 and 28). The window's text is decoded from the clone,
/// never from the file itself, so the text, Save As and Save To of a file
/// too large to edit, and the "did the file change?" check of a reload all
/// see the same bytes, whatever another app does to the file meanwhile.
/// A clone shares the file's disk blocks until one side changes: it costs
/// no copy, no disk space and no memory. Its extended attributes (the
/// encoding tag) are cloned with it.
///
/// Clones live in `<temp>/QuickEdit-originals/<pid>-<start>-<uuid>/`,
/// where `<start>` is the process's start time, so a later process that
/// gets the same number does not keep a dead folder (review row 38). The
/// folder is removed when this object goes (the document closes, or a
/// reload or save takes a newer clone) and, for a crashed or killed
/// QuickEdit, at the next launch (`removeStaleFolders`).
///
/// A clone needs APFS and the same volume as the temp folder (the startup
/// disk). When the file cannot be cloned (another volume, a network or
/// FAT disk), there is no clone: `clone(_:)` returns nil and the caller
/// reads the file itself. A file too large to edit then has no Save As or
/// Save To (review row 29).
final class LargeFileOriginal: Sendable {
    /// The clone (or a file QuickEdit wrote itself) in its own folder.
    let file: URL
    private let folder: URL

    private init(file: URL, folder: URL) {
        self.file = file
        self.folder = folder
    }

    deinit { removeFolder() }

    /// The parent of every QuickEdit clone folder.
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("QuickEdit-originals", isDirectory: true)
    }

    #if DEBUG
    /// Tests: act as if the volume cannot clone.
    nonisolated(unsafe) static var failCloneForTests = false
    #endif

    /// Clones `url`. Nil when its volume cannot clone it (the reason goes
    /// to stderr); the bytes are never copied.
    static func clone(_ url: URL) -> LargeFileOriginal? {
        let folder: URL
        do {
            folder = try makeFolder()
        } catch {
            FileHandle.standardError.write(Data("QuickEdit: cannot make a folder for a clone of \(url.path): \(error)\n".utf8))
            return nil
        }
        let clone = folder.appendingPathComponent(url.lastPathComponent)
        var cloned = false
        #if DEBUG
        if !failCloneForTests { cloned = clonefile(url.path, clone.path, 0) == 0 }
        #else
        cloned = clonefile(url.path, clone.path, 0) == 0
        #endif
        if cloned { return LargeFileOriginal(file: clone, folder: folder) }
        let reason = String(cString: strerror(errno))
        try? FileManager.default.removeItem(at: folder)
        FileHandle.standardError.write(Data("QuickEdit: cannot clone \(url.path) (\(reason)); it is read from the file itself\n".utf8))
        return nil
    }

    /// Bytes that came from no file (`read(from: Data)`): written once to
    /// the folder, so they cost disk, not memory.
    static func keep(_ data: Data, name: String) throws -> LargeFileOriginal {
        let folder = try makeFolder()
        let file = folder.appendingPathComponent(name)
        do {
            try data.write(to: file)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return LargeFileOriginal(file: file, folder: folder)
    }

    /// Writes the kept bytes to `url` (a new file; an old one is replaced).
    /// A clone again when it can, else a copy (FileManager clones on APFS).
    func write(to url: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: url.path) {
            let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                        appropriateFor: url, create: true)
            defer { try? files.removeItem(at: staging) }
            let staged = staging.appendingPathComponent(url.lastPathComponent)
            try files.copyItem(at: file, to: staged)
            _ = try files.replaceItemAt(url, withItemAt: staged)
        } else {
            try files.copyItem(at: file, to: url)
        }
    }

    /// The kept bytes, mapped.
    func bytes() throws -> Data {
        try Data(contentsOf: file, options: .mappedIfSafe)
    }

    /// The `com.apple.TextEncoding` tag the file had when it was cloned.
    var encodingTag: String? { PlainTextIO.readAttribute(of: file) }

    /// True when `other` holds the same bytes and the same encoding tag
    /// (review row 32). Reads both through mappings, so it costs time, not
    /// memory. Any thread.
    func hasSameContent(as other: LargeFileOriginal) -> Bool {
        guard encodingTag == other.encodingTag,
              let mine = try? bytes(), let theirs = try? other.bytes(), mine.count == theirs.count else { return false }
        return mine.withUnsafeBytes { a in
            theirs.withUnsafeBytes { b in
                a.count == 0 || memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0
            }
        }
    }

    func removeFolder() {
        do {
            try FileManager.default.removeItem(at: folder)
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        } catch {
            FileHandle.standardError.write(Data("QuickEdit: could not remove \(folder.path): \(error)\n".utf8))
        }
    }

    /// A process's start time in microseconds since 1970 (from the
    /// kernel's process table); nil when the process does not exist.
    static func startTime(of pid: pid_t) -> UInt64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_starttime
        return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
    }

    /// This process's folder name prefix: `<pid>-<start>-`.
    private static let ownPrefix: String = {
        let pid = getpid()
        return "\(pid)-\(startTime(of: pid) ?? 0)-"
    }()

    private static func makeFolder() throws -> URL {
        let folder = root.appendingPathComponent(ownPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// At launch: removes the folders of QuickEdit processes that are gone
    /// (crashed or killed before they could remove their own). A folder
    /// stays only while a process with its number AND its start time runs
    /// (another copy, a test host); a reused number has another start time
    /// (review row 38). Names in any other form are removed. Returns the
    /// folders removed.
    @discardableResult
    static func removeStaleFolders(in root: URL = root) -> [URL] {
        let files = FileManager.default
        guard let folders = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var removed: [URL] = []
        for folder in folders {
            let parts = folder.lastPathComponent.split(separator: "-", maxSplits: 2)
            if parts.count == 3, let pid = Int32(parts[0]), let start = UInt64(parts[1]),
               let running = startTime(of: pid), running == start {
                continue
            }
            do {
                try files.removeItem(at: folder)
                removed.append(folder)
            } catch {
                FileHandle.standardError.write(Data("QuickEdit: could not remove \(folder.path): \(error)\n".utf8))
            }
        }
        return removed
    }
}
