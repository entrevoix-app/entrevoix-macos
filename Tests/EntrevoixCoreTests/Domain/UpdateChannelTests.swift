import EntrevoixCore
import XCTest

final class UpdateChannelTests: XCTestCase {
    func testPreferencesDefaultToStableAndRoundTripTheChannel() throws {
        let fresh = AppPreferences()
        XCTAssertEqual(fresh.updateChannel, .stable)

        var preferences = AppPreferences(updateChannel: .development)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded.updateChannel, .development)

        preferences.updateChannel = .releaseCandidate
        XCTAssertEqual(
            try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences)).updateChannel,
            .releaseCandidate
        )
    }

    func testUnknownOrMissingChannelFallsBackToStable() throws {
        let unknown = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data("{\"schemaVersion\":10,\"updateChannel\":\"nightly\"}".utf8)
        )
        XCTAssertEqual(unknown.updateChannel, .stable)

        let missing = try JSONDecoder().decode(AppPreferences.self, from: Data("{\"schemaVersion\":10}".utf8))
        XCTAssertEqual(missing.updateChannel, .stable)
        XCTAssertEqual(AppPreferences.currentSchemaVersion, 14)
    }

    func testSchemaTenPreferencesMigrateToCurrentSchemaWithStableChannel() {
        let legacy = AppPreferences(schemaVersion: 10)
        let migrated = PreferencesMigrator.migrate(
            legacy,
            localizedDefaultPrompt: AppPreferences.defaultCleanupPrompt
        )

        XCTAssertEqual(migrated.schemaVersion, AppPreferences.currentSchemaVersion)
        XCTAssertEqual(migrated.updateChannel, .stable)
    }

    func testOnlyIncreasingRiskRequiresConfirmation() {
        XCTAssertTrue(UpdateChannel.releaseCandidate.requiresConfirmation(beforeChangingFrom: .stable))
        XCTAssertTrue(UpdateChannel.development.requiresConfirmation(beforeChangingFrom: .releaseCandidate))
        XCTAssertFalse(UpdateChannel.releaseCandidate.requiresConfirmation(beforeChangingFrom: .development))
        XCTAssertFalse(UpdateChannel.stable.requiresConfirmation(beforeChangingFrom: .development))
    }
}
