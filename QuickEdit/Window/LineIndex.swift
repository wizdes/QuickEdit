import AppKit

/// Where each logical line of a window's text starts (1.2.0), for the
/// line-number gutter and the document map. A line ends where
/// `NSString.lineRange(for:)` and Select Line end it: LF, CR, CRLF, U+0085,
/// U+2028, U+2029 (LineScanner). A text that ends with a line end has an
/// empty last line, as editors number it.
///
/// The index is built only as far as something asks, so a 1 GB file is
/// never scanned at open. A short gap is scanned at once; a long one in
/// slices of at most `sliceSeconds` on later turns of the run loop, after
/// each of which `onProgress` runs. Edits patch it: the shift of the
/// later starts is kept as one pending delta that only moves when the
/// next edit is elsewhere (cost: the starts between the two places), and a
/// new or removed line end adds one array insert or removal. A paste
/// longer than `syncGap` drops the index from there on and lets the idle
/// scan rebuild it. Large files (over 50 MB) get no index at all: the
/// window hides the gutter and the map and resets it (8 bytes a line).
@MainActor
final class LineIndex {
    /// Main-thread time one idle slice may take.
    static let sliceSeconds = 0.008
    /// A gap up to this many characters is scanned at once when asked.
    static let syncGap = 1 << 18
    private static let chunkLength = 1 << 15

    private let storage: NSTextStorage
    /// Called after an idle slice found more line starts.
    var onProgress: (() -> Void)?

    /// Known line starts, ascending; `starts[0]` is 0. Entries from
    /// `pendingIndex` on still need `pendingDelta` added.
    private var starts: [Int] = [0]
    private var pendingIndex = 1
    private var pendingDelta = 0
    /// Every line start at or below this character index is in `starts`.
    private(set) var scannedTo = 0
    /// A character index an idle scan is working toward, if any.
    private var idleTarget: Int?
    private var idleTimer: Timer?
    private var isStopped = false
    /// A reload is replacing the text: no scanning, no answers, and no
    /// reads of the text at all (it may be changing on another thread).
    private(set) var isPaused = false
    /// The line count estimate when the pause began, answered meanwhile.
    private var pausedEstimate = 1
    /// Counts resets and pauses, so an `onProgress` queued before one of
    /// them is dropped.
    private var generation = 0
    /// Digits of the line count last told to `onProgress`.
    private var reportedDigits = 1

    init(storage: NSTextStorage) {
        self.storage = storage
    }

    /// The whole text is scanned (false while paused: not known then).
    var isComplete: Bool { !isPaused && scannedTo >= storage.length }

    /// Line starts found so far (all of them once complete).
    var knownLineCount: Int { starts.count }

    /// The line count once complete; before that, the known count scaled
    /// to the whole text.
    var estimatedLineCount: Int {
        if isPaused { return pausedEstimate }
        if isComplete || scannedTo == 0 { return starts.count }
        let scale = Double(storage.length) / Double(scannedTo)
        return max(starts.count, Int((Double(starts.count) * scale).rounded(.up)))
    }

    private func start(_ index: Int) -> Int {
        index >= pendingIndex ? starts[index] + pendingDelta : starts[index]
    }

    /// The first index whose start is above `location` (so the line
    /// holding `location` is that index minus 1).
    private func upperBound(_ location: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if start(mid) <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The first index whose start is at or above `location`.
    private func lowerBound(_ location: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if start(mid) < location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Makes `pendingIndex` equal `index` without changing any start:
    /// the starts between the old and the new place take or give back the
    /// pending delta. Costs the distance between the two places.
    private func movePending(to index: Int) {
        let index = min(max(index, 0), starts.count)
        if pendingDelta != 0 {
            if index > pendingIndex {
                for i in pendingIndex..<index { starts[i] += pendingDelta }
            } else if index < pendingIndex {
                for i in index..<pendingIndex { starts[i] -= pendingDelta }
            }
        }
        pendingIndex = index
    }

    // MARK: Questions

    /// The 0-based line holding character `location` (the text length
    /// means the last line), or nil when the index has not reached it
    /// yet; a scan toward it is then under way.
    func line(containing location: Int) -> Int? {
        guard !isPaused else { return nil }
        let location = min(max(0, location), storage.length)
        guard reach(location) else { return nil }
        return upperBound(location) - 1
    }

    /// Where 0-based `line` starts, or nil when that line does not exist
    /// or is not reached yet (a scan toward it is then under way, unless
    /// the text is complete).
    func lineStart(_ line: Int) -> Int? {
        guard line >= 0, !isPaused else { return nil }
        if line < starts.count { return start(line) }
        if isComplete { return nil }
        // One short step now; the rest on idle turns (where the line is
        // is not known, so toward the end).
        scan(until: min(storage.length, scannedTo + Self.syncGap), deadline: nil)
        if line < starts.count { return start(line) }
        if !isComplete { scheduleIdleScan(toward: storage.length) }
        return nil
    }

    /// Line starts in `range` (character indexes), in order, as far as
    /// the index reaches; `complete` is false when it stopped short.
    func lineStarts(in range: NSRange) -> (starts: [Int], complete: Bool) {
        guard !isPaused else { return ([], false) }
        let end = min(NSMaxRange(range), storage.length)
        let reached = reach(end)
        var result: [Int] = []
        var i = lowerBound(range.location)
        while i < starts.count {
            let s = start(i)
            if s > end || (s == end && end < storage.length) { break }
            result.append(s)
            i += 1
        }
        return (result, reached)
    }

    /// True when every line start up to `location` is known. A short gap
    /// is scanned now; a long one is started on idle turns.
    @discardableResult
    func reach(_ location: Int) -> Bool {
        guard !isPaused else { return false }
        if location <= scannedTo || isComplete { return true }
        if location - scannedTo <= Self.syncGap {
            scan(until: location, deadline: nil)
            return true
        }
        // On to the end, in idle slices: the map and the gutter's width
        // want the whole count anyway.
        scheduleIdleScan(toward: storage.length)
        return false
    }

    // MARK: Scanning

    /// Scans forward from `scannedTo` until it passes `location` or, with
    /// a deadline, until the time is up (checked once per chunk).
    private func scan(until location: Int, deadline: UInt64?) {
        guard !isPaused else { return }
        // New starts go after every known one, so they belong to the
        // pending part: store them without the pending delta.
        let pending = pendingDelta
        let string = storage.string as NSString
        let length = string.length
        let target = min(location, length)
        let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: Self.chunkLength)
        defer { buffer.deallocate() }
        var position = scannedTo
        while position < target {
            // Read no further than asked: an edit's rescan is a few
            // characters, not a whole chunk.
            let n = min(Self.chunkLength, target - position)
            string.getCharacters(buffer, range: NSRange(location: position, length: n))
            var i = 0
            while i < n {
                let c = buffer[i]
                // Fast path: most characters are above CR and are not NEL, LS or PS.
                if c > 0x0D && c != 0x85 && (c & 0xFFFE) != 0x2028 { i += 1; continue }
                if c != 0x0A && c != 0x0D && c != 0x85 && c != 0x2028 && c != 0x2029 { i += 1; continue }
                var next = position + i + 1
                if c == 0x0D && next < length {
                    let following = i + 1 < n ? buffer[i + 1] : string.character(at: next)
                    if following == 0x0A { next += 1; i += 1 }
                }
                starts.append(next - pending)
                i += 1
            }
            position += max(n, i)
            if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline { break }
        }
        scannedTo = min(position, length)
        noteLineCountDigits()
    }

    /// A scan made while drawing can also change the line count's number
    /// of digits; the gutter then needs another width. `onProgress` is
    /// called on the next turn, never in the middle of a draw or an edit.
    private func noteLineCountDigits() {
        let digits = String(estimatedLineCount).count
        guard digits != reportedDigits else { return }
        reportedDigits = digits
        let queuedIn = generation
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                // Dropped after a pause or a reset: the gutter is redrawn
                // when the index starts again.
                guard let self, !self.isPaused, self.generation == queuedIn else { return }
                self.onProgress?()
            }
        }
    }

    private func scheduleIdleScan(toward location: Int) {
        idleTarget = max(idleTarget ?? 0, location)
        guard idleTimer == nil, !isStopped, !isPaused else { return }
        let timer = Timer(timeInterval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.idleSlice() }
        }
        idleTimer = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    private func idleSlice() {
        idleTimer = nil
        guard let target = idleTarget, !isStopped, !isPaused else { return }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(Self.sliceSeconds * 1e9)
        let before = starts.count
        scan(until: target, deadline: deadline)
        if scannedTo >= min(target, storage.length) {
            idleTarget = nil
        } else {
            scheduleIdleScan(toward: target)
        }
        if starts.count != before || idleTarget == nil { onProgress?() }
    }

    /// The window closed: no more idle slices.
    func stop() {
        isStopped = true
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// A reload starts replacing the text, maybe on another thread: no
    /// idle slice runs and nothing reads the text until `resume()`.
    func pause() {
        if !isPaused { pausedEstimate = estimatedLineCount }
        generation += 1
        isPaused = true
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// The reload is over: start again from nothing on the new text.
    func resume() {
        isPaused = false
        reset()
    }

    /// The whole text was replaced outside the edit notifications, or
    /// nothing shows the index: start again from nothing.
    func reset() {
        generation += 1
        starts = [0]
        pendingIndex = 1
        pendingDelta = 0
        scannedTo = 0
        reportedDigits = 1
        idleTarget = nil
        idleTimer?.invalidate()
        idleTimer = nil
    }

    // MARK: Edits

    /// The storage replaced `editedRange.length - changeInLength`
    /// characters at `editedRange.location` with `editedRange.length` new
    /// ones (NSTextStorage's didProcessEditing values). Returns true when
    /// the edit added or removed a line start (the gutter's numbers move
    /// then); false when it only changed text inside a line.
    @discardableResult
    func edit(editedRange: NSRange, changeInLength delta: Int) -> Bool {
        guard !isPaused else { return false }
        let location = editedRange.location
        let newLength = editedRange.length
        let oldLength = newLength - delta
        guard location <= scannedTo else { return false } // not scanned yet: nothing to patch
        let oldEnd = location + oldLength
        let low = lowerBound(max(location, 1))
        if oldEnd >= scannedTo || newLength > Self.syncGap {
            // The edit reaches the end of what is known, or pastes a lot:
            // drop the starts from it on. A short rest is scanned now
            // (typing at the end stays cheap); a long one on idle turns.
            movePending(to: low)
            let oldScannedTo = scannedTo
            let removed = starts.count - low
            starts.removeSubrange(low..<starts.count)
            pendingIndex = starts.count
            pendingDelta = 0
            // Every start up to location - 1 is still known; the scan
            // reads that character again (it may end a line).
            scannedTo = max(0, location - 1)
            let wanted = min(storage.length, max(location + newLength, oldScannedTo + delta))
            let frontier = min(wanted, scannedTo + Self.syncGap)
            scan(until: frontier, deadline: nil)
            if frontier < wanted {
                scheduleIdleScan(toward: storage.length)
                return true
            }
            var added = 0
            for i in low..<starts.count where starts[i] <= frontier { added += 1 }
            return added != removed
        }
        let high = upperBound(oldEnd)
        let found = newStarts(from: location, length: newLength)
        // The starts after the edit carry the pending delta from `high`
        // on; those below are exact, so the new ones go in as they are.
        movePending(to: high)
        if found.count != high - low || low != high {
            starts.replaceSubrange(low..<high, with: found)
        }
        pendingIndex = low + found.count
        pendingDelta += delta
        scannedTo += delta
        return found.count != high - low
    }

    /// Line starts in [location, location + length] of the edited text,
    /// read from one character before it (a CR there may pair with an LF).
    /// At most `syncGap` characters (longer edits take the drop path).
    private func newStarts(from location: Int, length: Int) -> [Int] {
        let string = storage.string as NSString
        let total = string.length
        let end = min(location + length, total)
        let first = max(0, location - 1)
        guard first < end else { return [] }
        var buffer = [unichar](repeating: 0, count: end - first)
        buffer.withUnsafeMutableBufferPointer { pointer in
            string.getCharacters(pointer.baseAddress!, range: NSRange(location: first, length: end - first))
        }
        var result: [Int] = []
        var i = 0
        while i < buffer.count {
            let c = buffer[i]
            if c > 0x0D && c != 0x85 && (c & 0xFFFE) != 0x2028 { i += 1; continue }
            if c != 0x0A && c != 0x0D && c != 0x85 && c != 0x2028 && c != 0x2029 { i += 1; continue }
            var next = first + i + 1
            if c == 0x0D && next < total {
                let following = i + 1 < buffer.count ? buffer[i + 1] : string.character(at: next)
                if following == 0x0A { next += 1 }
            }
            if next >= location && next <= location + length && next > 0 { result.append(next) }
            i = next - first
        }
        return result
    }

    /// Scans the whole text now (tests and measurements only).
    func scanAll() {
        guard !isPaused else { return }
        scan(until: storage.length, deadline: nil)
    }
}
