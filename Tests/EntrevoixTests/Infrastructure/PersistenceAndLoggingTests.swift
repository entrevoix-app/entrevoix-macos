import Foundation
import XCTest
import EntrevoixCore
import EntrevoixAppleAdapters
@testable import Entrevoix

final class PersistenceAndLoggingTests: XCTestCase {
    func testLegacyPreferencesAreCopiedWithoutOverwritingEntrevoixValues() throws {
        let suite = "EntrevoixMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var legacyPreferences = AppPreferences()
        legacyPreferences.sttLanguage = .french
        let legacyData = try JSONEncoder().encode(legacyPreferences)
        let currentData = try JSONEncoder().encode(AppPreferences())
        let legacyDomain: [String: Any] = [
            LegacyMurmureMigration.legacyPreferencesKey: legacyData,
            "KeyboardShortcuts_dictation": "legacy-shortcut"
        ]
        defaults.set(currentData, forKey: LegacyMurmureMigration.currentPreferencesKey)

        LegacyMurmureMigration.run(defaults: defaults, legacyDomain: legacyDomain)

        XCTAssertEqual(defaults.data(forKey: LegacyMurmureMigration.currentPreferencesKey), currentData)
        XCTAssertEqual(defaults.string(forKey: "KeyboardShortcuts_dictation"), "legacy-shortcut")
        XCTAssertTrue(defaults.bool(forKey: LegacyMurmureMigration.completionKey))
    }

    func testLegacyPreferencesMigrationIsIdempotent() {
        let suite = "EntrevoixMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyDomain: [String: Any] = ["KeyboardShortcuts_cancel": "escape"]

        LegacyMurmureMigration.run(defaults: defaults, legacyDomain: legacyDomain)
        defaults.set("new-value", forKey: "KeyboardShortcuts_cancel")
        LegacyMurmureMigration.run(defaults: defaults, legacyDomain: ["KeyboardShortcuts_cancel": "old-value"])

        XCTAssertEqual(defaults.string(forKey: "KeyboardShortcuts_cancel"), "new-value")
    }

    func testFreshInstallMigrationCreatesOnlyItsCompletionMarker() {
        let suite = "EntrevoixMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        LegacyMurmureMigration.run(defaults: defaults, legacyDomain: [:])

        XCTAssertNil(defaults.data(forKey: LegacyMurmureMigration.currentPreferencesKey))
        XCTAssertTrue(defaults.bool(forKey: LegacyMurmureMigration.completionKey))
    }

    func testUserDefaultsStoreSaveResetAndInvalidData() {
        withStore { store, defaults in
            guard case .loaded(let initial) = store.load() else {
                return XCTFail("Expected default preferences")
            }
            XCTAssertEqual(initial, AppPreferences())

            var preferences = AppPreferences(schemaVersion: 1)
            preferences.sttLanguage = .french
            store.save(preferences)
            guard case .loaded(let loaded) = store.load() else {
                return XCTFail("Expected valid preferences")
            }
            XCTAssertEqual(loaded.sttLanguage, .french)
            XCTAssertEqual(loaded.schemaVersion, AppPreferences.currentSchemaVersion)

            defaults.set(Data("not-json".utf8), forKey: "entrevoix.preferences")
            guard case .recovered(let recovered) = store.load() else {
                return XCTFail("Expected preferences recovery")
            }
            XCTAssertEqual(recovered, AppPreferences())
            XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))
            XCTAssertEqual(try? Data(contentsOf: recoveryURL), Data("not-json".utf8))

            store.reset()
            XCTAssertNil(defaults.data(forKey: "entrevoix.preferences"))
        }
    }

    func testFuturePreferencesAreRejectedWithoutOverwrite() throws {
        try withStore { store, defaults in
            var preferences = AppPreferences(schemaVersion: AppPreferences.currentSchemaVersion + 1)
            preferences.sttLanguage = .automatic
            let originalData = try JSONEncoder().encode(preferences)
            defaults.set(originalData, forKey: "entrevoix.preferences")

            guard case .incompatible(let schemaVersion) = store.load() else {
                return XCTFail("Expected future schema to be rejected")
            }
            XCTAssertEqual(schemaVersion, AppPreferences.currentSchemaVersion + 1)
            XCTAssertEqual(defaults.data(forKey: "entrevoix.preferences"), originalData)
        }
    }

    @MainActor
    func testLogStorePreservesOrderAndClears() {
        let store = AppLogStore()
        store.log("first")
        store.log("second")

        XCTAssertEqual(store.entries.map(\.message), ["first", "second"])
        XCTAssertNotEqual(store.entries[0].id, store.entries[1].id)
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    private var recoveryURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("entrevoix-recovery-\(name).json")
    }

    private func withStore(_ body: (UserDefaultsPreferencesStore, UserDefaults) throws -> Void) rethrows {
        let suite = "EntrevoixTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: recoveryURL)
        }
        try body(UserDefaultsPreferencesStore(defaults: defaults, recoveryURL: recoveryURL), defaults)
    }
}
