import Foundation
import XCTest
@testable import EntrevoixCore

final class PersistenceAndLoggingTests: XCTestCase {
    func testFreshPreferencesStartWithAnEmptyProviderCatalog() {
        let preferences = AppPreferences()
        XCTAssertTrue(preferences.providerCatalog.isEmpty)
        XCTAssertNil(preferences.selectedSTTProviderID)
        XCTAssertNil(preferences.selectedTTTProviderID)
        XCTAssertFalse(preferences.cleanupEnabled)
    }

    func testCodexProviderRoundTripsWithItsSelectedModelAndCannotBeAnSTTProfile() throws {
        let preferences = AppPreferences(
            providerCatalog: [.codex(CodexProviderProfile(model: .gpt56Luna))],
            selectedTTTProviderID: .codex,
            cleanupEnabled: true
        )

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))

        XCTAssertEqual(decoded.provider(for: .codex)?.codexProfile?.model, .gpt56Luna)
        XCTAssertNil(decoded.remoteProfile(for: .codex))
        XCTAssertNil(decoded.selectedSTTProviderID)
        XCTAssertEqual(decoded.selectedTTTProviderID, .codex)
        XCTAssertTrue(decoded.cleanupEnabled)
    }

    func testSchemaEightPreferencesMigrateToTwoSelectedCompatibleProfiles() throws {
        let sttID = UUID()
        let tttID = UUID()
        let json = """
        {"schemaVersion":8,"stt":{"id":"\(sttID.uuidString)","name":"Old STT","baseURL":"https://stt.example","path":"audio/transcriptions","model":"stt-model","authentication":"bearer","customHeaderName":"Authorization","timeout":20},"cleanupProvider":{"id":"\(tttID.uuidString)","name":"Old TTT","baseURL":"https://ttt.example","path":"chat/completions","model":"ttt-model","authentication":"apiKey","customHeaderName":"X-Key","timeout":30},"cleanupFormat":"chatCompletions","cleanupEnabled":true}
        """
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(preferences.selectedSTTProviderID, .remote(sttID))
        XCTAssertEqual(preferences.selectedTTTProviderID, .remote(tttID))
        XCTAssertEqual(preferences.remoteProfile(for: .remote(sttID))?.stt?.model, "stt-model")
        XCTAssertEqual(preferences.remoteProfile(for: .remote(tttID))?.ttt?.format, .chatCompletions)
        XCTAssertTrue(preferences.cleanupEnabled)
    }

    func testSchemaEightCollisionAllocatesACleanupIdentifierAndRecordsSecretCopy() throws {
        let sharedID = UUID()
        let json = """
        {"schemaVersion":8,"stt":{"id":"\(sharedID.uuidString)","name":"STT","baseURL":"https://example.com","path":"audio/transcriptions","model":"stt","authentication":"bearer","customHeaderName":"Authorization","timeout":20},"cleanupProvider":{"id":"\(sharedID.uuidString)","name":"TTT","baseURL":"https://example.com","path":"responses","model":"ttt","authentication":"bearer","customHeaderName":"Authorization","timeout":20}}
        """
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))
        let cleanupID = try XCTUnwrap(preferences.selectedTTTProviderID?.remoteID)
        XCTAssertNotEqual(cleanupID, sharedID)
        XCTAssertEqual(preferences.secretMigrationCopies[cleanupID], sharedID)
    }
    func testPreferencesDefaultsAndRoundTrip() throws {
        var preferences = AppPreferences(dictationDictionary: ["  Symfony ", "CapRover", "Symfony", "  "])
        XCTAssertEqual(preferences.schemaVersion, AppPreferences.currentSchemaVersion)
        XCTAssertFalse(preferences.hasCompletedOnboarding)
        XCTAssertFalse(preferences.cleanupEnabled)
        XCTAssertEqual(preferences.sttLanguage, .automatic)
        XCTAssertEqual(preferences.sttFavoriteLanguages, [.french, .english])
        XCTAssertEqual(preferences.dictationDictionary, ["Symfony", "CapRover"])
        XCTAssertEqual(preferences.dictationDictionaryPrompt, "Symfony, CapRover")
        XCTAssertTrue(preferences.trimLeadingAndTrailingSilence)
        XCTAssertFalse(preferences.reduceLongInternalPauses)

        preferences.sttLanguage = .french
        let microphone = AudioInputDeviceReference(uid: "usb-microphone", name: "USB Microphone")
        preferences.audioInputSelection = .device(microphone)
        preferences.trimLeadingAndTrailingSilence = false
        preferences.reduceLongInternalPauses = true
        preferences.dictationDictionary = ["Symfony", "CapRover"]
        preferences.triggerMode = .toggle
        preferences.cleanupFormat = .chatCompletions
        preferences.cleanupFailurePolicy = .stop
        preferences.outputMode = .paste
        preferences.launchAtLogin = true
        preferences.playFeedbackSounds = false
        preferences.hasCompletedOnboarding = true

        let decoded = try JSONDecoder().decode(
            AppPreferences.self,
            from: JSONEncoder().encode(preferences)
        )
        XCTAssertEqual(decoded, preferences)
    }

    func testMissingAudioInputSelectionDefaultsToMacOSSystemInput() throws {
        let preferences = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data("{\"schemaVersion\":12}".utf8)
        )

        XCTAssertEqual(preferences.audioInputSelection, .systemDefault)
        XCTAssertTrue(preferences.trimLeadingAndTrailingSilence)
        XCTAssertFalse(preferences.reduceLongInternalPauses)
        XCTAssertEqual(preferences.schemaVersion, 12)
    }

    func testSchemaTwelvePreferencesMigrateToCurrentAudioInputSchema() {
        let migrated = PreferencesMigrator.migrate(
            AppPreferences(schemaVersion: 12),
            localizedDefaultPrompt: AppPreferences.defaultCleanupPrompt
        )

        XCTAssertEqual(migrated.schemaVersion, AppPreferences.currentSchemaVersion)
        XCTAssertEqual(migrated.audioInputSelection, .systemDefault)
    }

    func testAudioInputDeviceIdentityUsesStableUIDRatherThanDisplayName() {
        XCTAssertEqual(
            AudioInputDeviceReference(uid: "usb-mic", name: "USB Microphone"),
            AudioInputDeviceReference(uid: "usb-mic", name: "Studio Mic")
        )
    }

    func testPromptLibraryRoundTripAndEmptyLibrary() throws {
        let first = CleanupPrompt(name: "Writing", systemImageName: "quote.bubble", instructions: "Improve writing.")
        let second = CleanupPrompt(name: "Code", systemImageName: "terminal", instructions: "Keep code exact.")
        var preferences = AppPreferences(cleanupPrompts: [first, second], activeCleanupPromptID: second.id)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded.cleanupPrompts, [first, second])
        XCTAssertEqual(decoded.activeCleanupPromptID, second.id)

        preferences.cleanupPrompts = []
        preferences.activeCleanupPromptID = nil
        let empty = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(empty.cleanupPrompts.isEmpty)
        XCTAssertNil(empty.activeCleanupPromptID)
    }

    func testMissingFieldsUseCurrentDefaults() throws {
        let data = Data("{\"schemaVersion\":4}".utf8)
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertEqual(preferences.stt, .openAITranscription)
        XCTAssertEqual(preferences.cleanupProvider, .openAIResponses)
        XCTAssertEqual(preferences.cleanupPrompt, AppPreferences.defaultCleanupPrompt)
        XCTAssertFalse(preferences.hasCompletedOnboarding)
        XCTAssertEqual(preferences.sttLanguage, .automatic)
        XCTAssertEqual(preferences.sttFavoriteLanguages, [.french, .english])
        XCTAssertTrue(preferences.dictationDictionary.isEmpty)
    }

    func testTranscriptionLanguageCodesAndLegacyMigration() throws {
        XCTAssertEqual(TranscriptionLanguage.french.apiCode, "fr")
        XCTAssertNil(TranscriptionLanguage.automatic.apiCode)
        XCTAssertEqual(TranscriptionLanguage(legacyCode: "fr-FR"), .french)
        XCTAssertEqual(TranscriptionLanguage(legacyCode: "unknown"), .automatic)

        let migrated = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data("{\"schemaVersion\":6,\"sttPrompt\":\"legacy context\",\"dictationDictionary\":[\"  Symfony \",\"CapRover\",\"Symfony\",\"  \"],\"sttLanguage\":\"de-DE\",\"sttFavoriteLanguages\":[\"fr\",\"fr\",\"automatic\",\"invalid\",\"en\"]}".utf8)
        )

        XCTAssertEqual(migrated.sttLanguage, .german)
        XCTAssertEqual(migrated.sttFavoriteLanguages, [.french, .english, .german])
        XCTAssertEqual(migrated.dictationDictionary, ["Symfony", "CapRover"])
        XCTAssertNotEqual(migrated.dictationDictionaryPrompt, "legacy context")
    }

    func testLocalizationDefaultsAndLegacyPromptMigration() throws {
        let fresh = AppPreferences()
        XCTAssertEqual(fresh.interfaceLanguage, .automatic)
        XCTAssertEqual(fresh.cleanupPromptMode, .localizedDefault)

        let legacy = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data("{\"schemaVersion\":4,\"cleanupPrompt\":\"\(AppPreferences.defaultCleanupPrompt)\"}".utf8)
        )
        XCTAssertEqual(legacy.cleanupPromptMode, .legacyDefaultPendingChoice)

        let custom = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data("{\"schemaVersion\":4,\"cleanupPrompt\":\"Keep my wording\"}".utf8)
        )
        XCTAssertEqual(custom.cleanupPromptMode, .custom)
    }

    func testSchemaFiveCustomPromptDecodesAsEditableLibraryEntry() throws {
        let preferences = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data("{\"schemaVersion\":5,\"cleanupPrompt\":\"Keep my wording\",\"cleanupPromptMode\":\"custom\"}".utf8)
        )

        XCTAssertEqual(preferences.cleanupPrompts.count, 1)
        XCTAssertEqual(preferences.cleanupPrompts.first?.name, "Existing Prompt")
        XCTAssertEqual(preferences.cleanupPrompts.first?.instructions, "Keep my wording")
        XCTAssertEqual(preferences.activeCleanupPromptID, preferences.cleanupPrompts.first?.id)
    }

    func testLegacyPreferencesSkipOnboarding() throws {
        let data = Data("{\"schemaVersion\":3}".utf8)
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
        XCTAssertTrue(preferences.hasCompletedOnboarding)
    }

    func testPreferencesMigratorRepairsLegacyAndLocalizedPrompts() throws {
        let legacy = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data("{\"schemaVersion\":4,\"cleanupPrompt\":\"\(AppPreferences.defaultCleanupPrompt)\"}".utf8)
        )
        let migrated = PreferencesMigrator.migrate(legacy, localizedDefaultPrompt: "Prompt localized")

        XCTAssertEqual(migrated.schemaVersion, AppPreferences.currentSchemaVersion)
        XCTAssertEqual(migrated.cleanupPrompts.count, 1)
        XCTAssertEqual(migrated.cleanupPrompts.first?.name, "Standard")
        XCTAssertEqual(migrated.cleanupPrompts.first?.instructions, "Prompt localized")
        XCTAssertEqual(migrated.activeCleanupPromptID, migrated.cleanupPrompts.first?.id)
    }

    func testPreferencesMigratorPreservesCustomPromptAndRepairsReference() {
        let prompt = CleanupPrompt(name: "Custom", systemImageName: "quote.bubble", instructions: "Keep wording")
        var preferences = AppPreferences(
            schemaVersion: 6,
            cleanupPrompts: [prompt],
            activeCleanupPromptID: UUID()
        )
        let migrated = PreferencesMigrator.migrate(preferences, localizedDefaultPrompt: "Localized")

        XCTAssertEqual(migrated.cleanupPrompts, [prompt])
        XCTAssertEqual(migrated.activeCleanupPromptID, prompt.id)
        XCTAssertNotEqual(migrated.cleanupPrompt, "Localized")
        preferences = AppPreferences()
        let unchanged = PreferencesMigrator.migrate(preferences, localizedDefaultPrompt: AppPreferences.defaultCleanupPrompt)
        XCTAssertEqual(unchanged, preferences)
    }

    func testSafeLogMessages() {
        struct SensitiveError: LocalizedError {
            var errorDescription: String? { "secret transcript" }
        }

        XCTAssertEqual(safeLogMessage(for: StubError.failure), "Safe failure")
        XCTAssertEqual(safeLogMessage(for: SensitiveError()), "Operation failed with no exportable details.")
        XCTAssertFalse(safeLogMessage(for: SensitiveError()).contains("secret"))
    }

}
