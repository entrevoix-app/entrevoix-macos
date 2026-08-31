import Foundation
import XCTest
@testable import Entrevoix

final class RecordingRetentionStoreTests: XCTestCase {
    func testMissingValueDefaultsToTrue() {
        withDefaults { defaults in
            let store = UserDefaultsRecordingRetentionPreferencesStore(defaults: defaults)

            XCTAssertTrue(store.loadDeleteAudioAfterTranscription())
        }
    }

    func testStoredFalseLoadsFalse() {
        withDefaults { defaults in
            defaults.set(false, forKey: UserDefaultsRecordingRetentionPreferencesStore.key)
            let store = UserDefaultsRecordingRetentionPreferencesStore(defaults: defaults)

            XCTAssertFalse(store.loadDeleteAudioAfterTranscription())
        }
    }

    func testStoredTrueLoadsTrue() {
        withDefaults { defaults in
            defaults.set(true, forKey: UserDefaultsRecordingRetentionPreferencesStore.key)
            let store = UserDefaultsRecordingRetentionPreferencesStore(defaults: defaults)

            XCTAssertTrue(store.loadDeleteAudioAfterTranscription())
        }
    }

    func testInvalidNonBoolValueDefaultsToTrue() {
        withDefaults { defaults in
            defaults.set("false", forKey: UserDefaultsRecordingRetentionPreferencesStore.key)
            let store = UserDefaultsRecordingRetentionPreferencesStore(defaults: defaults)

            XCTAssertTrue(store.loadDeleteAudioAfterTranscription())
        }
    }

    @MainActor
    func testStoreLoadsAndPersistsChangedValue() {
        withDefaults { defaults in
            let preferencesStore = UserDefaultsRecordingRetentionPreferencesStore(defaults: defaults)
            let store = RecordingRetentionStore(preferencesStore: preferencesStore)

            XCTAssertTrue(store.deleteAudioAfterTranscription)
            store.setDeleteAudioAfterTranscription(false)

            XCTAssertFalse(store.deleteAudioAfterTranscription)
            XCTAssertFalse(preferencesStore.loadDeleteAudioAfterTranscription())
        }
    }

    @MainActor
    func testStoreDoesNotPersistUnchangedValue() {
        let preferencesStore = RecordingRetentionPreferencesStoreSpy(value: true)
        let store = RecordingRetentionStore(preferencesStore: preferencesStore)

        store.setDeleteAudioAfterTranscription(true)

        XCTAssertEqual(preferencesStore.savedValues, [])
    }

    func testRetentionSaveDoesNotCreateOrMutateExistingPreferencesPayload() {
        withDefaults { defaults in
            let originalPayload = Data("existing-preferences".utf8)
            defaults.set(originalPayload, forKey: "entrevoix.preferences")
            let store = UserDefaultsRecordingRetentionPreferencesStore(defaults: defaults)

            store.saveDeleteAudioAfterTranscription(false)

            XCTAssertEqual(defaults.data(forKey: "entrevoix.preferences"), originalPayload)
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "RecordingRetentionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }
}

private final class RecordingRetentionPreferencesStoreSpy: RecordingRetentionPreferencesStoring {
    let value: Bool
    private(set) var savedValues: [Bool] = []

    init(value: Bool) {
        self.value = value
    }

    func loadDeleteAudioAfterTranscription() -> Bool {
        value
    }

    func saveDeleteAudioAfterTranscription(_ enabled: Bool) {
        savedValues.append(enabled)
    }
}
