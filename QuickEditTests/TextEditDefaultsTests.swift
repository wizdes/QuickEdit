import AppKit
import XCTest
@testable import QuickEdit

/// M10 n4 (docs/parity.md P32, P33): the registered Spelling and Grammar
/// and Substitutions values match TextEdit's (reference/apple/Controller.m
/// :79-88, docs/codemap.md section 3). "System" means the value comes from
/// the Mac's own setting, as TextEdit reads it from NSSpellChecker.
@MainActor
final class TextEditDefaultsTests: XCTestCase {
    private func registered(_ key: DefaultsKey) -> Bool? {
        Defaults.registeredValues()[key.rawValue] as? Bool
    }

    /// 1.2.0 (Sublime Text defaults): spelling and auto-correct are off,
    /// where TextEdit has spelling on and auto-correct from the system.
    func testSpellingAndGrammarMatchTextEdit() {
        XCTAssertEqual(registered(.checkSpellingWhileTyping), false, "1.2.0: check spelling while typing off")
        XCTAssertEqual(registered(.checkGrammarWithSpelling), false, "TextEdit: grammar NO")
        XCTAssertEqual(registered(.correctSpellingAutomatically), false, "1.2.0: auto-correct off")
    }

    func testSubstitutionsMatchTextEdit() {
        XCTAssertEqual(registered(.smartCopyPaste), true, "TextEdit: Smart Copy/Paste YES")
        XCTAssertEqual(registered(.smartQuotes), false, "TextEdit: Smart Quotes NO")
        XCTAssertEqual(registered(.smartDashes), false, "TextEdit: Smart Dashes NO")
        XCTAssertEqual(registered(.dataDetectors), false, "TextEdit: Data Detectors NO")
        XCTAssertEqual(registered(.textReplacement), NSSpellChecker.isAutomaticTextReplacementEnabled,
                       "TextEdit: Text Replacement from the system setting")
    }

    /// The values above reach a settings store that has nothing saved.
    func testRegisterPutsTheValuesInAnEmptyStore() throws {
        let name = "dev.yili.QuickEditTests.TextEditDefaults-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        let saved = Defaults.store
        Defaults.store = suite
        defer { Defaults.store = saved }
        Defaults.register()
        let keys: [DefaultsKey] = [.checkSpellingWhileTyping, .checkGrammarWithSpelling, .correctSpellingAutomatically,
                                   .smartCopyPaste, .smartQuotes, .smartDashes, .dataDetectors, .textReplacement]
        for key in keys {
            XCTAssertEqual(suite.bool(forKey: key.rawValue), registered(key), key.rawValue)
        }
    }
}
