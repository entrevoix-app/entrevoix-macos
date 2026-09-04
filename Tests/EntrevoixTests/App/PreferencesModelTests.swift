import Foundation
import XCTest
@testable import Entrevoix
import EntrevoixCore

final class PreferencesStoreTests: XCTestCase {
    @MainActor
    func testPreferencesAndSecretsHaveIndependentPersistence() {
        let store = PreferencesStoreSpy()
        let keychain = SecretStoreSpy()
        let model = PreferencesStore(
            preferencesStore: store,
            keychain: keychain,
            initialPreferences: configuredPreferences()
        )

        var updated = model.preferences
        updated.playFeedbackSounds.toggle()
        model.update(updated, to: .immediate)

        XCTAssertEqual(store.saved.count, 1)
        XCTAssertTrue(keychain.saves.isEmpty)

        model.updateSTTAPIKey("secret", to: .debounced)
        XCTAssertTrue(keychain.saves.isEmpty)
        model.flushPendingWrites()

        XCTAssertTrue(keychain.saves.last?.values.contains("secret") == true)
        XCTAssertEqual(store.saved.last?.cleanupPromptMode, .localizedDefault)
    }

    @MainActor
    func testDebouncedWritesCanBeFlushedAndSuperseded() {
        let store = PreferencesStoreSpy()
        let keychain = SecretStoreSpy()
        let model = PreferencesStore(
            preferencesStore: store,
            keychain: keychain,
            initialPreferences: configuredPreferences()
        )

        var first = model.preferences
        first.playFeedbackSounds = false
        model.update(first)
        var second = first
        second.launchAtLogin = true
        model.update(second)

        XCTAssertTrue(store.saved.isEmpty)
        model.flushPendingWrites()

        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.saved.first?.launchAtLogin, true)
        XCTAssertEqual(store.saved.first?.playFeedbackSounds, false)
    }

    @MainActor
    func testKeychainFailureIsGenericAndDoesNotExposeSecret() {
        let store = PreferencesStoreSpy()
        let keychain = SecretStoreSpy()
        keychain.saveError = AppStubError.failure
        let model = PreferencesStore(
            preferencesStore: store,
            keychain: keychain,
            initialPreferences: configuredPreferences()
        )

        model.updateSTTAPIKey("super-secret", to: .immediate)

        XCTAssertEqual(model.persistenceError, .keychainSaveFailed)
        XCTAssertFalse(String(describing: model.persistenceError).contains("super-secret"))
    }

    func testFreshPreferencesEnableAudioProcessingAndPreserveExistingAudioChoices() throws {
        let fresh = AppPreferences()
        XCTAssertTrue(fresh.trimLeadingAndTrailingSilence)
        XCTAssertTrue(fresh.reduceLongInternalPauses)

        let existing = AppPreferences(
            schemaVersion: AppPreferences.currentSchemaVersion,
            trimLeadingAndTrailingSilence: false,
            reduceLongInternalPauses: false
        )
        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(existing))

        XCTAssertEqual(restored.schemaVersion, existing.schemaVersion)
        XCTAssertFalse(restored.trimLeadingAndTrailingSilence)
        XCTAssertFalse(restored.reduceLongInternalPauses)
    }

    func testFreshPreferencesUseAutomaticInsertionAndPreserveExistingDeliveryChoice() throws {
        XCTAssertEqual(AppPreferences().outputMode, .paste)

        let existing = AppPreferences(
            schemaVersion: AppPreferences.currentSchemaVersion,
            outputMode: .clipboard
        )
        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(existing))

        XCTAssertEqual(restored.schemaVersion, existing.schemaVersion)
        XCTAssertEqual(restored.outputMode, .clipboard)
    }
}

private func configuredPreferences() -> AppPreferences {
    let configuration = ProviderConfiguration.openAITranscription
    let profile = RemoteProviderProfile(id: configuration.id, kind: .openAICompatible, name: configuration.name, baseURL: configuration.baseURL, authentication: configuration.authentication, customHeaderName: configuration.customHeaderName, timeout: configuration.timeout, stt: STTCapability(path: configuration.path, model: configuration.model))
    return AppPreferences(providerCatalog: [.remote(profile)], selectedSTTProviderID: .remote(profile.id))
}
