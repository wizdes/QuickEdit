import AppKit

/// Records one new shortcut for the Settings > Keyboard tab.
///
/// While it records, a local event monitor sees every key press in the app
/// before the menu bar and the windows do, and swallows it: Cmd+O then
/// becomes the candidate shortcut instead of opening the Open panel. A
/// mouse click anywhere ends the recording and still reaches its target.
@MainActor
final class ShortcutRecorder {
    /// What one key event means while recording.
    enum Outcome: Equatable {
        /// Esc with no modifiers: stop, change nothing.
        case cancel
        /// Delete or Forward Delete with no modifiers: the command gets no shortcut.
        case remove
        /// A key with its modifiers, to be checked and saved.
        case candidate(KeyShortcut)
        /// Only modifiers are down (shown in the field while held).
        case modifiers(NSEvent.ModifierFlags)
    }

    /// Hardware key codes (Carbon kVK_*) of keys whose characters do not
    /// name them the way AppKit menus do.
    private static let keyCodeKeys: [UInt16: String] = [
        53: "\u{1B}",                                     // Escape
        36: "\r", 76: "\u{03}",                            // Return, Enter
        48: "\t",                                         // Tab
        49: " ",                                          // Space
        51: "\u{08}",                                     // Delete (backspace)
        117: functionKey(NSDeleteFunctionKey),            // Forward Delete
        123: functionKey(NSLeftArrowFunctionKey), 124: functionKey(NSRightArrowFunctionKey),
        125: functionKey(NSDownArrowFunctionKey), 126: functionKey(NSUpArrowFunctionKey),
        115: functionKey(NSHomeFunctionKey), 119: functionKey(NSEndFunctionKey),
        116: functionKey(NSPageUpFunctionKey), 121: functionKey(NSPageDownFunctionKey),
    ]

    private static func functionKey(_ value: Int) -> String {
        String(Character(UnicodeScalar(UInt32(value))!))
    }

    /// The outcome of `event`, or nil for an event that means nothing here
    /// (a key with no character, such as a bare Fn).
    static func outcome(for event: NSEvent) -> Outcome? {
        let modifiers = event.modifierFlags.intersection(KeyShortcut.modifierMask)
        if event.type == .flagsChanged { return .modifiers(modifiers) }
        guard event.type == .keyDown else { return nil }
        let key: String
        if let named = keyCodeKeys[event.keyCode] {
            key = named
        } else if let ignoring = event.charactersIgnoringModifiers, ignoring.unicodeScalars.count == 1,
                  let scalar = ignoring.unicodeScalars.first, (0xF700...0xF8FF).contains(scalar.value) {
            // F1 to F35 and the other function keys, as AppKit menus spell them.
            key = ignoring
        } else if let base = event.characters(byApplyingModifiers: []), !base.isEmpty {
            // The key as typed with no modifiers, so Shift+Cmd+; is ";" plus
            // Shift and Option+Cmd+A is "a" plus Option.
            key = base.lowercased()
        } else {
            return nil
        }
        guard key.unicodeScalars.count == 1 else { return nil }
        if modifiers.isEmpty {
            if key == "\u{1B}" { return .cancel }
            if key == "\u{08}" || key == functionKey(NSDeleteFunctionKey) { return .remove }
        }
        return .candidate(KeyShortcut(key, modifiers))
    }

    /// Called with each outcome while recording.
    private let handler: (Outcome) -> Void
    /// Called when a click ends the recording.
    private let onClick: () -> Void
    private var monitor: Any?

    init(handler: @escaping (Outcome) -> Void, onClick: @escaping () -> Void) {
        self.handler = handler
        self.onClick = onClick
    }

    var isRecording: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown,
                                                              .rightMouseDown]) { [weak self] event in
            // Local monitors run on the main thread; NSEvent is not
            // Sendable, so it is handed over unchecked.
            nonisolated(unsafe) let event = event
            nonisolated(unsafe) var result: NSEvent? = event
            MainActor.assumeIsolated {
                if let self { result = self.handle(event) }
            }
            return result
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            stop()
            onClick()
            return event
        default:
            if let outcome = Self.outcome(for: event) { handler(outcome) }
            return nil
        }
    }
}
