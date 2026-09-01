import EntrevoixCore
import Foundation
import XCTest
@testable import Entrevoix

final class IncompatibleStartupActionTests: XCTestCase {
    @MainActor
    func testUpdateChecksForUpdatesOnceWithoutChangingFuturePreferences() throws {
        let persistentStore = try futurePreferencesStore()
        let updater = IncompatibleStartupUpdateSpy()
        let handler = IncompatibleStartupActionHandler(
            preferencesStore: persistentStore,
            updater: updater,
            terminate: {}
        )

        handler.handle(.update)

        XCTAssertEqual(updater.checkCount, 1)
        XCTAssertEqual(persistentStore.data, persistentStore.originalData)
    }

    @MainActor
    func testQuitTerminatesOnceWithoutChangingFuturePreferences() throws {
        let persistentStore = try futurePreferencesStore()
        let updater = IncompatibleStartupUpdateSpy()
        var terminationCount = 0
        let handler = IncompatibleStartupActionHandler(
            preferencesStore: persistentStore,
            updater: updater,
            terminate: { terminationCount += 1 }
        )

        handler.handle(.quit)

        XCTAssertEqual(terminationCount, 1)
        XCTAssertEqual(persistentStore.data, persistentStore.originalData)
    }

    @MainActor
    func testOpenAnywayReturnsDefaultPreferencesAndKeepsFuturePreferencesIsolatedFromSavesAndReset() throws {
        let persistentStore = try futurePreferencesStore()
        let handler = IncompatibleStartupActionHandler(
            preferencesStore: persistentStore,
            updater: IncompatibleStartupUpdateSpy(),
            terminate: {}
        )

        let result = handler.handle(.openAnyway)

        guard case .ready(let preferences, let sessionPreferencesStore) = result else {
            return XCTFail("Expected Open Anyway to launch a ready app")
        }
        XCTAssertEqual(preferences, AppPreferences())

        var changedPreferences = preferences
        changedPreferences.sttLanguage = .french
        sessionPreferencesStore.save(changedPreferences)
        sessionPreferencesStore.reset()

        XCTAssertEqual(persistentStore.data, persistentStore.originalData)
    }

    private func futurePreferencesStore() throws -> FuturePreferencesStoreSpy {
        var preferences = AppPreferences(schemaVersion: AppPreferences.currentSchemaVersion + 1)
        preferences.sttLanguage = .french
        return try FuturePreferencesStoreSpy(data: JSONEncoder().encode(preferences))
    }
}

private final class FuturePreferencesStoreSpy: PreferencesStoring {
    let originalData: Data
    private(set) var data: Data

    init(data: Data) {
        originalData = data
        self.data = data
    }

    func load() -> PreferencesLoadResult {
        .incompatible(schemaVersion: AppPreferences.currentSchemaVersion + 1)
    }

    func save(_ preferences: AppPreferences) {
        data = (try? JSONEncoder().encode(preferences)) ?? data
    }

    func reset() {
        data = Data()
    }
}

@MainActor
private final class IncompatibleStartupUpdateSpy: ApplicationUpdating {
    private(set) var checkCount = 0

    func start(channel: UpdateChannel) {}
    func setChannel(_ channel: UpdateChannel) {}
    func checkForUpdates() { checkCount += 1 }
}
