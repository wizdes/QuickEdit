import Foundation
import os
import Synchronization

/// M8 speed hooks: `os_signpost` events and intervals, subsystem
/// `dev.yili.QuickEdit`, category `QuickEdit`, compiled into Release too.
/// Read them with `log stream --signpost --predicate 'subsystem == "dev.yili.QuickEdit"'`
/// or Instruments' os_signpost track. When nobody records, each call costs
/// well under a microsecond (SignpostTests measures it).
///
/// Launch, in order: `mainStart`, `menuBuilt`, `firstWindowCreated`,
/// `firstLayout`, `firstKeyAccepted`. Opening a file: the `read` interval
/// (`readStart` to `readEnd`) with `decodeEnd` inside it, then
/// `storageInstalled`. Typing: the "encoding check", "line ending" and
/// "storage edit" intervals.
enum Signposts {
    enum Event: String, CaseIterable, Sendable {
        case mainStart = "main start"
        case menuBuilt = "menu built"
        case firstWindowCreated = "first window created"
        case readStart = "document read start"
        case decodeEnd = "decode end"
        case readEnd = "document read end"
        case storageInstalled = "storage installed"
        case firstLayout = "first layout"
        case firstKeyAccepted = "first key accepted"
    }

    static let signposter = OSSignposter(subsystem: "dev.yili.QuickEdit", category: "QuickEdit")

    /// One event. The names must be static strings for os_signpost, hence the switch.
    static func mark(_ event: Event) {
        #if DEBUG
        record(event)
        #endif
        switch event {
        case .mainStart: signposter.emitEvent("main start")
        case .menuBuilt: signposter.emitEvent("menu built")
        case .firstWindowCreated: signposter.emitEvent("first window created")
        case .readStart: signposter.emitEvent("document read start")
        case .decodeEnd: signposter.emitEvent("decode end")
        case .readEnd: signposter.emitEvent("document read end")
        case .storageInstalled: signposter.emitEvent("storage installed")
        case .firstLayout: signposter.emitEvent("first layout")
        case .firstKeyAccepted: signposter.emitEvent("first key accepted")
        }
    }

    /// The `read` interval around `TextDocument.read(from:ofType:)`.
    static func beginRead() -> OSSignpostIntervalState {
        mark(.readStart)
        return signposter.beginInterval("read")
    }

    static func endRead(_ state: OSSignpostIntervalState) {
        signposter.endInterval("read", state)
        mark(.readEnd)
    }

    /// Typing path (M8 n7): one interval around `body`, named by `name`:
    /// "encoding check" (the inserted characters against the file's
    /// encoding), "line ending" (Return typing the file's line ending).
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    /// The "storage edit" interval: from the text storage's
    /// willProcessEditing to its didProcessEditing, which covers the layout
    /// managers' layout invalidation for the edit.
    static func beginStorageEdit() -> OSSignpostIntervalState {
        signposter.beginInterval("storage edit")
    }

    static func endStorageEdit(_ state: OSSignpostIntervalState) {
        signposter.endInterval("storage edit", state)
    }

    /// Marks an event only the first time it is called in this process
    /// (the launch events).
    static func markOnce(_ event: Event) {
        let first = marked.withLock { $0.insert(event).inserted }
        if first { mark(event) }
    }

    private static let marked = Mutex<Set<Event>>([])

    #if DEBUG
    /// Tests: when not nil, every event is appended here as well.
    static let recorded = Mutex<[Event]?>(nil)

    private static func record(_ event: Event) {
        recorded.withLock { $0?.append(event) }
    }

    /// Tests: forget which launch events were marked, so `markOnce` marks again.
    static func resetOnce() {
        marked.withLock { $0.removeAll() }
    }
    #endif
}
