import XCTest
@testable import NativeReader

@MainActor
final class ReadingPreferencesTests: XCTestCase {
    func testShelfViewDefaultsToGridAndPersistsBothModes() {
        withDefaults { defaults in
            let preferences = ReadingPreferences(defaults: defaults)
            XCTAssertEqual(preferences.shelfLayout, .grid)
            preferences.shelfLayout = .list
            XCTAssertEqual(ReadingPreferences(defaults: defaults).shelfLayout, .list)
            preferences.shelfLayout = .grid
            XCTAssertEqual(ReadingPreferences(defaults: defaults).shelfLayout, .grid)
        }
    }
    func testPrefetchIsOptInAndPersistsAcrossStores() {
        withDefaults { defaults in
            let preferences = ReadingPreferences(defaults: defaults)
            XCTAssertFalse(preferences.prefetchNextTwo)
            preferences.prefetchNextTwo = true
            XCTAssertTrue(ReadingPreferences(defaults: defaults).prefetchNextTwo)
            preferences.prefetchNextTwo = false
            XCTAssertFalse(ReadingPreferences(defaults: defaults).prefetchNextTwo)
        }
    }
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "reading-preferences-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testPresentationSettingsSurviveNewStoreWithoutWritingProgress() throws {
        try withDefaults { defaults in
            let preferences = ReadingPreferences(defaults: defaults)
            XCTAssertEqual(preferences.style, ReadingStyle())
            defaults.set("untouched", forKey: "progress-sentinel")
            preferences.style.size = 30
            preferences.style.lineSpacing = 10
            preferences.style.paragraphSpacing = 18
            preferences.style.margin = 44
            preferences.style.dark = true
            let reopened = ReadingPreferences(defaults: defaults)
            XCTAssertEqual(reopened.style, preferences.style)
            XCTAssertEqual(defaults.string(forKey: "progress-sentinel"), "untouched")
            let data = try XCTUnwrap(defaults.data(forKey: ReadingPreferences.storageKey))
            XCTAssertEqual(try JSONDecoder().decode(ReadingStyle.self, from: data), preferences.style)
        }
    }

    func testCorruptPreferencesFallBackAndCanBeSavedAgain() {
        withDefaults { defaults in
            defaults.set(Data("invalid json".utf8), forKey: ReadingPreferences.storageKey)
            let preferences = ReadingPreferences(defaults: defaults)
            XCTAssertEqual(preferences.style, ReadingStyle())
            preferences.style.dark = true
            XCTAssertTrue(ReadingPreferences(defaults: defaults).style.dark)
        }
    }

    func testInvalidLayoutValuesUseDefaultsWhileKeepingValidAppearance() throws {
        try withDefaults { defaults in
            var invalid = ReadingStyle()
            invalid.size = -100
            invalid.margin = 10000
            invalid.lineSpacing = -1
            invalid.paragraphSpacing = 31
            invalid.fontName = "Missing-Font-For-Regression"
            invalid.dark = true
            defaults.set(try JSONEncoder().encode(invalid), forKey: ReadingPreferences.storageKey)
            var expected = ReadingStyle()
            expected.dark = true
            XCTAssertEqual(ReadingPreferences(defaults: defaults).style, expected)
        }
    }
}
