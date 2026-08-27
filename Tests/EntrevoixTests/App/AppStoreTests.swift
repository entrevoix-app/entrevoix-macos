import Foundation
import XCTest
@testable import EntrevoixCore
@testable import Entrevoix

final class AppStoreTests: XCTestCase {
    @MainActor
    func testLoadsAndSavesPreferencesAndSecretsIndependently() {
        var preferences = AppPreferences()
        preferences.sttLanguage = .french
        preferences.triggerMode = .toggle
        let secrets = [
            preferences.stt.id: "stt-key",
            preferences.cleanupProvider.id: "cleanup-key"
        ]
        let context = makeContext(preferences: preferences, secrets: secrets)

        XCTAssertEqual(context.model.preferences.sttLanguage, .french)
        XCTAssertEqual(context.model.mode, .toggle)
        XCTAssertEqual(context.model.sttAPIKey, "stt-key")
        XCTAssertEqual(context.model.cleanupAPIKey, "cleanup-key")
        XCTAssertEqual(Set(context.secretStore.readIDs), Set(secrets.keys))

        context.model.setSTTLanguage(.english)
        context.model.sttAPIKey = "new-stt"
        context.model.cleanupAPIKey = "new-cleanup"
        context.model.savePreferences()

        XCTAssertEqual(context.preferencesStore.saved.last?.sttLanguage, .english)
        XCTAssertTrue(context.secretStore.saves.isEmpty)

        context.model.preferencesModel.flushPendingWrites()

        XCTAssertEqual(context.secretStore.saves.last?[preferences.stt.id], "new-stt")
        XCTAssertEqual(context.secretStore.saves.last?[preferences.cleanupProvider.id], "new-cleanup")
    }

    @MainActor
    func testProviderCatalogueSavesAllSecretsSelectsCapabilitiesAndDeletesAtomically() async {
        let catalog = ModelCatalogSpy(models: ["z-model", "a-model", "a-model"])
        let context = makeContext(modelCatalog: catalog)

        context.model.addAppleProvider()
        XCTAssertTrue(context.model.providersSortedForDisplay.contains { $0.id == .apple })
        context.model.setSTTProvider(.apple)
        XCTAssertEqual(context.model.preferences.selectedSTTProviderID, .apple)
        XCTAssertNotEqual(context.model.preferences.sttLanguage, .automatic)

        var profile = context.model.newRemoteProvider(kind: .openAICompatible)
        profile.name = "Personal endpoint"
        profile.baseURL = "https://models.example.com/v1"
        profile.authentication = .apiKey
        profile.customHeaderName = "X-API-Key"
        profile.stt = STTCapability(path: "audio/transcriptions", model: "stt-model")
        profile.ttt = TTTCapability(path: "responses", model: "ttt-model")
        XCTAssertTrue(context.model.saveRemoteProvider(profile, apiKey: "profile-secret").isEmpty)
        XCTAssertEqual(context.model.apiKey(for: .remote(profile.id)), "profile-secret")

        context.model.setSTTProvider(.remote(profile.id))
        context.model.setTTTProvider(.remote(profile.id))
        context.model.loadModels(for: profile)
        await appWaitUntil("model discovery") { context.model.discoveredModels[profile.id] == ["a-model", "z-model"] }

        XCTAssertTrue(context.model.removeProvider(.remote(profile.id)))
        XCTAssertNil(context.model.preferences.selectedSTTProviderID)
        XCTAssertNil(context.model.preferences.selectedTTTProviderID)
        XCTAssertFalse(context.model.preferences.cleanupEnabled)
        XCTAssertNil(context.secretStore.saves.last?[profile.id])
    }

    @MainActor
    func testRemoteProviderSavesItsSelectedSTTUploadFormat() {
        let context = makeContext()
        var profile = context.model.newRemoteProvider(kind: .openAICompatible)
        profile.name = "Compact uploads"
        profile.baseURL = "https://stt.example.com/v1"
        profile.stt?.uploadFormat = .m4aAAC

        XCTAssertTrue(context.model.saveRemoteProvider(profile, apiKey: "profile-secret").isEmpty)
        let savedProfile = context.model.preferences.remoteProfile(for: .remote(profile.id))

        XCTAssertEqual(savedProfile?.stt?.uploadFormat, .m4aAAC)
        XCTAssertEqual(savedProfile?.configuration(for: .stt)?.audioUploadFormat, .m4aAAC)
    }

    @MainActor
    func testOnboardingAddsOrReusesAnOpenAIProviderAndCommitsItsKey() {
        let context = makeContext()

        let firstID = context.model.providerStore.addOpenAIProviderForOnboarding()
        context.model.providerStore.setAPIKey("onboarding-key", for: firstID)
        context.model.providerStore.commitConfiguration()
        let secondID = context.model.providerStore.addOpenAIProviderForOnboarding()

        XCTAssertEqual(secondID, firstID)
        XCTAssertEqual(context.model.preferences.selectedSTTProviderID, firstID)
        XCTAssertEqual(context.model.preferences.providerCatalog.filter { $0.id == firstID }.count, 1)
        guard let remoteID = firstID.remoteID else { return XCTFail("Expected a remote provider") }
        XCTAssertEqual(context.secretStore.saves.last?[remoteID], "onboarding-key")
    }

    @MainActor
    func testCodexProviderIsTTTOnlyAndPersistsItsModelChoice() {
        let context = makeContext()

        context.model.addCodexProvider()
        context.model.setCodexModel(.gpt56Luna)
        context.model.setSTTProvider(.codex)
        context.model.setTTTProvider(.codex)

        XCTAssertTrue(context.model.providersSortedForDisplay.contains { $0.id == .codex })
        XCTAssertEqual(context.model.preferences.provider(for: .codex)?.codexProfile?.model, .gpt56Luna)
        XCTAssertNotEqual(context.model.preferences.selectedSTTProviderID, .codex)
        XCTAssertEqual(context.model.preferences.selectedTTTProviderID, .codex)
    }

    @MainActor
    func testCodexConnectionLifecyclePersistsAndRemovesCredentialsBeforeProvider() async {
        let credentials = CodexCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: .distantFuture
        )
        let credentialStore = CodexCredentialStoreSpy()
        let authenticator = CodexAuthenticatorSpy(result: .success(credentials))
        let context = makeContext(codexCredentials: credentialStore, codexAuthenticator: authenticator)

        context.model.addCodexProvider()
        context.model.setTTTProvider(.codex)
        context.model.connectCodex()
        await appWaitUntil("Codex connection") { context.model.codexConnectionState == .connected }
        let connectedValues = await credentialStore.saved
        XCTAssertEqual(connectedValues.last!, credentials)

        context.model.disconnectCodex()
        await appWaitUntil("Codex disconnection") { context.model.codexConnectionState == .disconnected }
        let disconnectedValues = await credentialStore.saved
        XCTAssertNil(disconnectedValues.last!)

        context.model.connectCodex()
        await appWaitUntil("Codex reconnection") { context.model.codexConnectionState == .connected }
        context.model.removeCodexProvider()
        await appWaitUntil("Codex provider removal") { context.model.preferences.provider(for: .codex) == nil }
        XCTAssertNil(context.model.preferences.selectedTTTProviderID)
        XCTAssertFalse(context.model.preferences.cleanupEnabled)
        let removedValues = await credentialStore.saved
        XCTAssertNil(removedValues.last!)
    }

    @MainActor
    func testChangingInterfaceLanguageUpdatesLocaleAndPersistsImmediately() {
        let context = makeContext(preferences: AppPreferences(interfaceLanguage: .english))

        XCTAssertEqual(context.model.interfaceLocale.identifier, "en")
        context.model.setInterfaceLanguage(.french)

        XCTAssertEqual(context.model.interfaceLocale.identifier, "fr-FR")
        XCTAssertEqual(context.preferencesStore.saved.last?.interfaceLanguage, .french)

        context.model.setInterfaceLanguage(.english)
        XCTAssertEqual(context.model.interfaceLocale.identifier, "en")
        XCTAssertEqual(context.preferencesStore.saved.last?.interfaceLanguage, .english)
    }

    @MainActor
    func testSelectingSTTLanguageAddsFavoriteAndCanBeChangedBackToAutomatic() {
        let context = makeContext()

        context.model.setSTTLanguage(.german)
        XCTAssertEqual(context.model.preferences.sttLanguage, .german)
        XCTAssertTrue(context.model.preferences.sttFavoriteLanguages.contains(.german))
        XCTAssertEqual(context.preferencesStore.saved.last?.sttLanguage, .german)

        context.model.setSTTLanguage(.automatic)
        XCTAssertEqual(context.model.preferences.sttLanguage, .automatic)
        XCTAssertTrue(context.model.preferences.sttFavoriteLanguages.contains(.german))
    }

    @MainActor
    func testDownloadsAudioTrimmingResourceOnlyWhenRequested() async {
        let resources = AppAudioCaptureTrimmingResourceManagerSpy(state: .downloadRequired)
        let context = makeContext(audioCaptureTrimmingResources: resources)

        await appWaitUntil("audio trimming resource status") {
            context.model.audioCaptureTrimmingResourceState == .downloadRequired
        }
        let initialDownloads = await resources.downloadLocales
        XCTAssertTrue(initialDownloads.isEmpty)

        context.model.downloadAudioCaptureTrimmingResource()
        await appWaitUntil("audio trimming resource download") {
            context.model.audioCaptureTrimmingResourceState == .ready
        }
        let downloadedLocales = await resources.downloadLocales
        XCTAssertEqual(downloadedLocales.count, 1)
    }

    @MainActor
    func testActiveSTTLanguageCannotBeRemovedFromFavorites() {
        var preferences = AppPreferences()
        preferences.sttLanguage = .french
        let migrated = PreferencesMigrator.migrate(preferences, localizedDefaultPrompt: "Localized default")
        let context = makeContext(preferences: migrated)

        context.model.setSTTFavoriteLanguage(.french, enabled: false)
        XCTAssertTrue(context.model.preferences.sttFavoriteLanguages.contains(.french))

        context.model.setSTTFavoriteLanguage(.german, enabled: true)
        XCTAssertTrue(context.model.preferences.sttFavoriteLanguages.contains(.german))
        context.model.setSTTFavoriteLanguage(.german, enabled: false)
        XCTAssertFalse(context.model.preferences.sttFavoriteLanguages.contains(.german))
    }

    @MainActor
    func testDictationDictionaryNormalizesRejectsDuplicatesAndPersists() {
        let context = makeContext()

        XCTAssertTrue(context.model.addDictationDictionaryTerm("  Symfony  "))
        XCTAssertFalse(context.model.addDictationDictionaryTerm("Symfony"))
        XCTAssertFalse(context.model.addDictationDictionaryTerm("   "))
        XCTAssertTrue(context.model.addDictationDictionaryTerm("CapRover"))

        XCTAssertEqual(context.model.preferences.dictationDictionary, ["Symfony", "CapRover"])
        XCTAssertEqual(context.model.preferences.dictationDictionaryPrompt, "Symfony, CapRover")
        XCTAssertEqual(context.preferencesStore.saved.last?.dictationDictionary, ["Symfony", "CapRover"])

        XCTAssertFalse(context.model.updateDictationDictionaryTerm("Symfony", to: "CapRover"))
        XCTAssertFalse(context.model.updateDictationDictionaryTerm("Symfony", to: "   "))
        XCTAssertTrue(context.model.updateDictationDictionaryTerm("Symfony", to: "  Symfony Framework  "))
        XCTAssertEqual(context.model.preferences.dictationDictionary, ["Symfony Framework", "CapRover"])

        context.model.removeDictationDictionaryTerm("Symfony Framework")
        XCTAssertEqual(context.model.preferences.dictationDictionary, ["CapRover"])
    }

    @MainActor
    func testSchemaSixMigrationPreservesPromptLibrary() {
        let prompt = CleanupPrompt(name: "Existing", systemImageName: "quote.bubble", instructions: "Keep this prompt.")
        let preferences = AppPreferences(
            schemaVersion: 6,
            cleanupPrompts: [prompt],
            activeCleanupPromptID: prompt.id
        )
        let migrated = PreferencesMigrator.migrate(preferences, localizedDefaultPrompt: "Localized default")
        let context = makeContext(preferences: migrated)

        XCTAssertEqual(context.model.preferences.cleanupPrompts, [prompt])
        XCTAssertEqual(context.model.preferences.activeCleanupPromptID, prompt.id)
        XCTAssertTrue(context.preferencesStore.saved.isEmpty)
    }

    @MainActor
    func testOnboardingPromptModeAndStateTitles() {
        var preferences = AppPreferences(interfaceLanguage: .english)
        preferences.cleanupPrompt = "custom"
        let migrated = PreferencesMigrator.migrate(preferences, localizedDefaultPrompt: "Localized default")
        let context = makeContext(preferences: migrated)

        XCTAssertTrue(context.model.requiresOnboarding)
        context.model.completeOnboarding()
        XCTAssertFalse(context.model.requiresOnboarding)
        XCTAssertTrue(context.preferencesStore.saved.last?.hasCompletedOnboarding == true)

        context.model.resetCleanupPrompt()
        XCTAssertEqual(context.model.preferences.cleanupPrompt, AppPreferences.defaultCleanupPrompt)
        context.model.setMode(.toggle)
        XCTAssertEqual(context.model.mode, .toggle)
        XCTAssertEqual(context.model.preferences.triggerMode, .toggle)

        XCTAssertEqual(PermissionStatus.granted.title, "Allowed")
        XCTAssertEqual(PermissionStatus.denied.title, "Denied")
        XCTAssertEqual(PermissionStatus.notDetermined.title, "Not allowed yet")
        XCTAssertEqual(AuthenticationMode.allCases.map(\.title), ["Bearer", "API Key", "None"])
        XCTAssertEqual(CleanupAPIFormat.allCases.map(\.title), ["Responses API", "Chat Completions", "Anthropic Messages"])
        XCTAssertEqual(CleanupFailurePolicy.allCases.map(\.title), ["Use Raw Transcript", "Stop with an Error"])
        XCTAssertEqual(TriggerMode.allCases.map(\.title), ["Hold to Talk", "Press to Start/Stop"])
        XCTAssertEqual(OutputMode.allCases.map(\.title), ["Clipboard", "Insert Automatically"])
        XCTAssertEqual(DictationState.error(.audioUnavailable).title, "No audio file was produced.")
        XCTAssertTrue(ConnectionTestState.idle.isInactive)
        XCTAssertFalse(ConnectionTestState.testing.isInactive)
        XCTAssertEqual(ConnectionTestState.succeeded(characterCount: 12).title, "Connection verified: received 12 characters.")
        XCTAssertEqual(ConnectionTestState.failed(.transcriptionFailed(message: "failure")).title, "failure")
    }

    @MainActor
    func testPromptLibraryCRUDValidationAndReset() {
        let preferences = AppPreferences(interfaceLanguage: .french)
        let context = makeContext(preferences: preferences)
        XCTAssertEqual(context.model.activeCleanupPrompt?.instructions, EntrevoixLocalization.defaultCleanupPrompt(locale: context.model.interfaceLocale))

        let duplicate = CleanupPrompt(name: " Standard ", systemImageName: "sparkles", instructions: "Different")
        XCTAssertEqual(context.model.saveCleanupPrompt(duplicate), .duplicateName)
        let invalid = CleanupPrompt(name: "New", systemImageName: "circle", instructions: "Text")
        XCTAssertEqual(context.model.saveCleanupPrompt(invalid), .invalidIcon)

        let custom = CleanupPrompt(name: " Writing ", systemImageName: "quote.bubble", instructions: "Improve prose.")
        XCTAssertNil(context.model.saveCleanupPrompt(custom))
        XCTAssertEqual(context.model.preferences.cleanupPrompts.last?.name, "Writing")
        context.model.setActiveCleanupPrompt(custom.id)
        XCTAssertEqual(context.model.activeCleanupPrompt?.id, custom.id)
        context.model.deleteCleanupPrompt(id: custom.id)
        XCTAssertNil(context.model.preferences.cleanupPrompts.first { $0.id == custom.id })

        let standardID = context.model.preferences.cleanupPrompts[0].id
        context.model.deleteCleanupPrompt(id: standardID)
        XCTAssertTrue(context.model.preferences.cleanupPrompts.isEmpty)
        XCTAssertNil(context.model.preferences.activeCleanupPromptID)
        context.model.resetPromptLibrary()
        XCTAssertEqual(context.model.preferences.cleanupPrompts.count, 1)
        XCTAssertNotNil(context.model.activeCleanupPrompt)
    }

    @MainActor
    func testPromptLibraryExportUsesTheCurrentPromptSnapshot() {
        let first = CleanupPrompt(name: "Writing", systemImageName: "quote.bubble", instructions: "Improve writing.")
        let second = CleanupPrompt(name: "Code", systemImageName: "terminal", instructions: "Keep code exact.")
        let context = makeContext(preferences: AppPreferences(cleanupPrompts: [first, second]))

        XCTAssertEqual(context.model.makeCleanupPromptExport(), CleanupPromptExport(prompts: [first, second]))
    }

    @MainActor
    func testPromptLibraryImportMergesPromptsAndSelectsTheFirstWhenNeeded() {
        let imported = CleanupPrompt(name: "Writing", systemImageName: "quote.bubble", instructions: "Improve writing.")
        let context = makeContext(
            preferences: AppPreferences(cleanupPrompts: [], activeCleanupSelection: nil),
            cleanupPromptExportReader: PromptLibraryExportReaderSpy(result: .success(CleanupPromptExport(prompts: [imported])))
        )

        let result = context.model.importCleanupPrompts(from: URL(fileURLWithPath: "/tmp/prompts.json"))

        XCTAssertEqual(try? result.get().importedPrompts, [imported])
        XCTAssertEqual(context.model.preferences.cleanupPrompts, [imported])
        XCTAssertEqual(context.model.preferences.activeCleanupSelection, .prompt(imported.id))
    }

    @MainActor
    func testDeletingPromptPrunesWorkflowReferencesAndRepairsActiveSelection() {
        let defaultPrompt = CleanupPrompt(
            id: AppPreferences.defaultCleanupPromptID,
            name: "Standard",
            systemImageName: "wand.and.stars",
            instructions: "Default"
        )
        let removable = CleanupPrompt(name: "Polish", systemImageName: "sparkles", instructions: "Polish text")
        let workflow = CleanupWorkflow(name: "Publish", promptIDs: [removable.id, removable.id])
        let preferences = AppPreferences(
            cleanupPrompts: [defaultPrompt, removable],
            cleanupWorkflows: [workflow],
            activeCleanupSelection: .workflow(workflow.id)
        )
        let context = makeContext(preferences: preferences)

        context.model.deleteCleanupPrompt(id: removable.id)

        XCTAssertEqual(context.model.preferences.cleanupWorkflows.first?.promptIDs, [])
        XCTAssertEqual(context.model.preferences.activeCleanupSelection, .prompt(defaultPrompt.id))
        XCTAssertEqual(context.model.activeCleanupPrompt?.id, defaultPrompt.id)
        context.model.setActiveCleanupWorkflow(workflow.id)
        XCTAssertEqual(context.model.preferences.activeCleanupSelection, .prompt(defaultPrompt.id))
    }

    @MainActor
    func testInvalidActivePromptReferenceIsRepairedAndPersisted() {
        var preferences = AppPreferences()
        preferences.activeCleanupPromptID = UUID()
        let migrated = PreferencesMigrator.migrate(preferences, localizedDefaultPrompt: "Localized default")
        let context = makeContext(preferences: migrated)

        XCTAssertEqual(context.model.preferences.activeCleanupPromptID, context.model.preferences.cleanupPrompts.first?.id)
        XCTAssertTrue(context.preferencesStore.saved.isEmpty)
    }

    @MainActor
    func testPushToTalkHandlesRepeatDebounceAndKeyUp() async throws {
        let recorder = AppRecorderSpy()
        let context = makeContext(recorder: recorder)

        context.hotkeys.onKeyDown?()
        await appWaitUntil("recording") { context.model.state == .recording }
        context.hotkeys.onKeyDown?()
        XCTAssertEqual(recorder.startCount, 1)
        context.model.setMode(.toggle)
        XCTAssertEqual(context.model.mode, .pushToTalk)

        context.model.cancelRecording()
        context.hotkeys.onKeyUp?()
        context.hotkeys.onKeyDown?()
        XCTAssertEqual(context.model.state, .idle)
        XCTAssertEqual(recorder.startCount, 1)

        recorder.stopURL = try appTemporaryFile()
        context.clock.advance(by: DictationTiming.shortcutDebounce + 0.01)
        context.hotkeys.onKeyDown?()
        await appWaitUntil("second recording") { context.model.state == .recording }
        XCTAssertEqual(recorder.startCount, 2)
        context.clock.advance(by: 1)
        context.hotkeys.onKeyUp?()
        await appWaitUntil("transcription") { context.model.state == .idle }
    }

    @MainActor
    func testPushToTalkKeyUpCancelsPendingPermission() async {
        let recorder = AppRecorderSpy()
        let permissions = PermissionSpy()
        permissions.holdMicrophoneRequest = true
        let context = makeContext(recorder: recorder, permissions: permissions)

        context.hotkeys.onKeyDown?()
        await Task.yield()
        XCTAssertEqual(context.model.state, .requestingPermission)
        context.hotkeys.onKeyUp?()
        permissions.resolveNextMicrophonePermission(true)
        await Task.yield()

        XCTAssertEqual(context.model.state, .idle)
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertEqual(recorder.cancelCount, 1)
    }

    @MainActor
    func testAutomaticInsertionRequiresAccessibilityBeforeRecording() {
        let recorder = AppRecorderSpy()
        let permissions = PermissionSpy()
        let context = makeContext(
            recorder: recorder,
            preferences: AppPreferences(outputMode: .paste),
            permissions: permissions
        )

        context.model.startRecording()

        XCTAssertEqual(context.model.state, .idle)
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertEqual(permissions.accessibilityRequestCount, 1)
        XCTAssertEqual(context.feedback.events, [.error])
        XCTAssertTrue(context.model.logStore.entries.contains {
            $0.message == "Automatic insertion requires Accessibility permission."
        })
    }

    @MainActor
    func testAutomaticInsertionRequiresAccessibilityBeforeDeliveringLastTranscript() async throws {
        let recorder = AppRecorderSpy()
        recorder.stopURL = try appTemporaryFile()
        let permissions = PermissionSpy()
        let context = makeContext(recorder: recorder, permissions: permissions)

        context.model.startRecording()
        await appWaitUntil("recording") { context.model.state == .recording }
        context.clock.advance(by: 1)
        context.model.stopRecording()
        await appWaitUntil("dictation completion") { context.model.state == .idle }
        context.model.preferences.outputMode = .paste

        context.model.deliverTranscript()

        XCTAssertTrue(context.delivery.pasted.isEmpty)
        XCTAssertEqual(permissions.accessibilityRequestCount, 1)
        XCTAssertEqual(context.feedback.events, [.recordingStarted, .recordingStopped, .error])
    }

    @MainActor
    func testDictationCancellationPlaysFeedbackOnceWhileActive() async {
        let context = makeContext()

        context.model.startRecording()
        await appWaitUntil("recording") { context.model.state == .recording }
        context.model.cancelRecording()
        context.model.cancelRecording()

        XCTAssertEqual(context.feedback.events, [.recordingStarted, .recordingCancelled])
    }

    @MainActor
    func testToggleStartsAndStopsRecording() async throws {
        let recorder = AppRecorderSpy()
        recorder.stopURL = try appTemporaryFile()
        var preferences = AppPreferences()
        preferences.triggerMode = .toggle
        let context = makeContext(recorder: recorder, preferences: preferences)

        context.hotkeys.onKeyDown?()
        await appWaitUntil("toggle recording") { context.model.state == .recording }
        context.hotkeys.onKeyUp?()
        context.clock.advance(by: 1)
        context.clock.advance(by: DictationTiming.shortcutDebounce + 0.01)
        context.hotkeys.onKeyDown?()
        await appWaitUntil("toggle transcription") { context.model.state == .idle }

        XCTAssertEqual(recorder.startCount, 1)
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertEqual(context.listeningIndicator.labels, ["Listening…"])
        XCTAssertEqual(context.listeningIndicator.hideCount, 1)
    }

    @MainActor
    func testDictationForwardsDictionaryPrompt() async throws {
        let recorder = AppRecorderSpy()
        recorder.stopURL = try appTemporaryFile()
        defer { if let url = recorder.stopURL { try? FileManager.default.removeItem(at: url) } }
        let transcriber = AppTranscriberSpy()
        let preferences = AppPreferences(
            dictationDictionary: ["Symfony", "CapRover"],
            cleanupEnabled: false
        )
        let context = makeContext(recorder: recorder, transcriber: transcriber, preferences: preferences)

        context.model.startRecording()
        await appWaitUntil("recording") { context.model.state == .recording }
        context.clock.advance(by: 1)
        context.model.stopRecording()
        await appWaitUntil("dictation completion") { context.model.state == .idle }

        let calls = await transcriber.calls
        XCTAssertEqual(calls.first?.prompt, "Symfony, CapRover")
    }

    @MainActor
    func testConnectionPermissionAndRecorderFailures() async {
        let deniedRecorder = AppRecorderSpy()
        let deniedPermissions = PermissionSpy()
        deniedPermissions.microphoneResult = false
        let denied = makeContext(recorder: deniedRecorder, permissions: deniedPermissions)
        denied.model.startSTTConnectionTest()
        await appWaitUntil("permission denied") { denied.model.connectionTestState.isInactive }
        XCTAssertEqual(
            denied.model.connectionTestState,
            .failed(.microphonePermissionDenied)
        )
        XCTAssertEqual(denied.feedback.events, [.error])

        let failingRecorder = AppRecorderSpy()
        failingRecorder.startError = AppStubError.failure
        let failing = makeContext(recorder: failingRecorder)
        failing.model.startSTTConnectionTest()
        await appWaitUntil("recorder failure") { failing.model.connectionTestState.isInactive }
        XCTAssertEqual(failing.model.connectionTestState, .failed(.recordingFailed(message: "Visible app failure")))
        XCTAssertTrue(failing.model.logStore.entries.contains { $0.message == "Error: connection test: Safe app failure" })
    }

    @MainActor
    func testShortConnectionRecordingFailsWithoutTranscription() async {
        let recorder = AppRecorderSpy()
        let transcriber = AppTranscriberSpy()
        let context = makeContext(recorder: recorder, transcriber: transcriber)

        context.model.startSTTConnectionTest()
        await appWaitUntil("test recording") { context.model.connectionTestState == .recording }
        context.model.finishSTTConnectionTest()

        XCTAssertEqual(
            context.model.connectionTestState,
            .failed(.insufficientAudio)
        )
        XCTAssertEqual(recorder.cancelCount, 1)
        let calls = await transcriber.calls
        XCTAssertTrue(calls.isEmpty)

        let missingRecorder = AppRecorderSpy()
        let missing = makeContext(recorder: missingRecorder)
        missing.model.startSTTConnectionTest()
        await appWaitUntil("missing file recording") { missing.model.connectionTestState == .recording }
        missing.clock.advance(by: 1)
        missing.model.finishSTTConnectionTest()
        XCTAssertEqual(
            missing.model.connectionTestState,
            .failed(.insufficientAudio)
        )
    }

    @MainActor
    func testSuccessfulConnectionTestForwardsConfigurationAndCleansCapture() async throws {
        let recorder = AppRecorderSpy()
        let audioURL = try appTemporaryFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        recorder.stopURL = audioURL
        let transcriber = AppTranscriberSpy(result: .success("verified text"))
        var preferences = AppPreferences()
        preferences.dictationDictionary = ["Symfony", "CapRover"]
        preferences.sttLanguage = .french
        let context = makeContext(recorder: recorder, transcriber: transcriber, preferences: preferences)
        context.model.sttAPIKey = "connection-key"

        context.model.startSTTConnectionTest()
        await appWaitUntil("test recording") { context.model.connectionTestState == .recording }
        context.clock.advance(by: 1)
        context.model.finishSTTConnectionTest()
        await appWaitUntil("test success") { context.model.connectionTestState.isInactive }

        XCTAssertEqual(context.model.connectionTestState, .succeeded(characterCount: 13))
        let calls = await transcriber.calls
        XCTAssertEqual(calls.first?.configuration, preferences.stt)
        XCTAssertEqual(calls.first?.apiKey, "connection-key")
        XCTAssertEqual(calls.first?.prompt, "Symfony, CapRover")
        XCTAssertEqual(calls.first?.language, "fr")
        XCTAssertEqual(recorder.deleteCount, 1)
        XCTAssertEqual(context.feedback.events, [.recordingStarted, .recordingStopped, .connectionTestSucceeded])
    }

    @MainActor
    func testConnectionTranscriptionFailureAndCancellation() async throws {
        let failingRecorder = AppRecorderSpy()
        let failingURL = try appTemporaryFile()
        defer { try? FileManager.default.removeItem(at: failingURL) }
        failingRecorder.stopURL = failingURL
        let failingTranscriber = AppTranscriberSpy(result: .failure(.failure))
        let failing = makeContext(recorder: failingRecorder, transcriber: failingTranscriber)
        failing.model.startSTTConnectionTest()
        await appWaitUntil("failure recording") { failing.model.connectionTestState == .recording }
        failing.clock.advance(by: 1)
        failing.model.finishSTTConnectionTest()
        await appWaitUntil("connection failure") { failing.model.connectionTestState.isInactive }
        XCTAssertEqual(failing.model.connectionTestState, .failed(.transcriptionFailed(message: "Visible app failure")))
        XCTAssertTrue(failing.model.logStore.entries.contains { $0.message == "Error: connection test: Safe app failure" })

        let pendingRecorder = AppRecorderSpy()
        let pendingURL = try appTemporaryFile()
        defer { try? FileManager.default.removeItem(at: pendingURL) }
        pendingRecorder.stopURL = pendingURL
        let pendingTranscriber = AppControlledTranscriber()
        let pending = makeContext(recorder: pendingRecorder, transcriber: pendingTranscriber)
        pending.model.startSTTConnectionTest()
        await appWaitUntil("pending recording") { pending.model.connectionTestState == .recording }
        pending.clock.advance(by: 1)
        pending.model.finishSTTConnectionTest()
        await appWaitUntil("pending request") { await pendingTranscriber.callCount == 1 }
        pending.model.cancelSTTConnectionTest()
        await pendingTranscriber.succeed(with: "late transcript")
        await Task.yield()
        XCTAssertEqual(pending.model.connectionTestState, .idle)
        XCTAssertFalse(pending.model.logStore.entries.contains { $0.message.contains("late transcript") })
    }

    @MainActor
    func testConnectionTestBlocksDictationAndCanBeCancelled() async {
        let recorder = AppRecorderSpy()
        let permissions = PermissionSpy()
        permissions.holdMicrophoneRequest = true
        let context = makeContext(recorder: recorder, permissions: permissions)

        context.model.startSTTConnectionTest()
        await Task.yield()
        context.model.startRecording()
        XCTAssertEqual(context.model.state, .idle)
        context.model.cancelSTTConnectionTest()
        permissions.resolveNextMicrophonePermission(true)
        await Task.yield()

        XCTAssertEqual(context.model.connectionTestState, .idle)
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertEqual(context.feedback.events, [.recordingCancelled])
    }

    @MainActor
    func testPermissionsLaunchAtLoginFeedbackAndClipboardHelpers() async {
        let context = makeContext()
        context.permissions.microphonePermission = .denied
        context.permissions.accessibilityPermission = .granted

        XCTAssertEqual(context.model.microphonePermission, .denied)
        XCTAssertEqual(context.model.accessibilityPermission, .granted)
        let revision = context.model.permissionsRevision
        context.model.requestAccessibilityPermission()
        XCTAssertEqual(context.permissions.accessibilityRequestCount, 1)
        XCTAssertEqual(context.model.permissionsRevision, revision + 1)

        context.model.requestMicrophonePermission()
        await Task.yield()
        XCTAssertGreaterThan(context.model.permissionsRevision, revision + 1)

        context.model.setLaunchAtLogin(true)
        XCTAssertTrue(context.model.launchAtLoginEnabled)
        XCTAssertTrue(context.model.preferences.launchAtLogin)
        XCTAssertNil(context.model.launchAtLoginError)

        context.launch.error = AppStubError.failure
        context.model.setLaunchAtLogin(false)
        XCTAssertNotNil(context.model.launchAtLoginError)
        XCTAssertTrue(context.model.logStore.entries.contains { $0.message.contains("launch at login") })

        context.model.copyTestText()
        context.model.pasteTestText()
        context.model.copyTranscript()
        context.model.deliverTranscript()
        XCTAssertEqual(context.delivery.copied, ["Entrevoix — clipboard test"])
        XCTAssertEqual(context.delivery.pasted, ["Entrevoix — insertion test"])
    }

    @MainActor
    func testRequestsUnresolvedPermissionsAtLaunch() async {
        let context = makeContext()

        context.model.requestUnresolvedPermissionsAtLaunch()
        await appWaitUntil("startup microphone permission request") {
            context.permissions.microphoneRequestCount == 1
        }
        XCTAssertEqual(context.permissions.accessibilityRequestCount, 1)

        context.permissions.microphonePermission = .granted
        context.permissions.accessibilityPermission = .granted
        context.model.requestUnresolvedPermissionsAtLaunch()
        await Task.yield()
        XCTAssertEqual(context.permissions.microphoneRequestCount, 1)
        XCTAssertEqual(context.permissions.accessibilityRequestCount, 1)

        context.permissions.microphonePermission = .denied
        context.model.requestUnresolvedPermissionsAtLaunch()
        await Task.yield()
        XCTAssertEqual(context.permissions.microphoneRequestCount, 1)
    }

    @MainActor
    func testMicrophonePermissionRepairIsSingleFlightAndRefreshesOnSuccess() async {
        let context = makeContext()
        context.permissions.microphonePermission = .denied
        let revision = context.model.permissionsRevision

        context.model.resetMicrophonePermission()
        XCTAssertTrue(context.model.isResettingMicrophonePermission)
        context.model.resetMicrophonePermission()

        await appWaitUntil("microphone permission repair") {
            !context.model.isResettingMicrophonePermission
        }

        XCTAssertEqual(context.permissions.microphoneResetCount, 1)
        XCTAssertEqual(context.model.microphonePermission, .notDetermined)
        XCTAssertEqual(context.model.microphonePermissionRepairFeedback, .succeeded)
        XCTAssertGreaterThan(context.model.permissionsRevision, revision)
    }

    @MainActor
    func testMicrophonePermissionRepairExposesFailure() async {
        let context = makeContext()
        context.permissions.microphonePermission = .denied
        context.permissions.microphoneResetError = .commandFailed

        context.model.resetMicrophonePermission()
        await appWaitUntil("failed microphone permission repair") {
            !context.model.isResettingMicrophonePermission
        }

        XCTAssertEqual(context.permissions.microphoneResetCount, 1)
        XCTAssertEqual(context.model.microphonePermission, .denied)
        XCTAssertEqual(context.model.microphonePermissionRepairFeedback, .failed)
    }

    @MainActor
    func testCompletedDictationCanBeCopiedAndDeliveredAgain() async throws {
        let recorder = AppRecorderSpy()
        recorder.stopURL = try appTemporaryFile()
        let permissions = PermissionSpy()
        permissions.accessibilityPermission = .granted
        let context = makeContext(recorder: recorder, permissions: permissions)
        context.model.preferences.outputMode = .paste

        context.model.startRecording()
        await appWaitUntil("recording") { context.model.state == .recording }
        context.clock.advance(by: 1)
        context.model.stopRecording()
        await appWaitUntil("dictation completion") { context.model.state == .idle }
        context.model.copyTranscript()
        context.model.deliverTranscript()
        context.model.deleteLastCapture()

        XCTAssertEqual(context.delivery.copied, ["connection transcript"])
        XCTAssertEqual(context.delivery.pasted, ["connection transcript"])
        XCTAssertEqual(recorder.deleteCount, 1)
    }

    @MainActor
    func testDisabledFeedbackProducesNoSoundEvents() async {
        let recorder = AppRecorderSpy()
        let permissions = PermissionSpy()
        permissions.microphoneResult = false
        var preferences = AppPreferences()
        preferences.playFeedbackSounds = false
        let context = makeContext(recorder: recorder, preferences: preferences, permissions: permissions)

        context.model.startSTTConnectionTest()
        await appWaitUntil("silent failure") { context.model.connectionTestState.isInactive }
        XCTAssertTrue(context.feedback.events.isEmpty)
    }

    @MainActor
    func testDisabledFeedbackProducesNoCancellationSound() async {
        var preferences = AppPreferences()
        preferences.playFeedbackSounds = false
        let context = makeContext(preferences: preferences)

        context.model.startRecording()
        await appWaitUntil("recording") { context.model.state == .recording }
        context.model.cancelRecording()

        XCTAssertTrue(context.feedback.events.isEmpty)
    }

    @MainActor
    func testPromptNavigationCreateSaveAndDiscardDraftLifecycle() {
        let context = makeContext()
        let state = PromptLibraryNavigationState()
        let id = UUID()

        state.beginCreating(id)
        XCTAssertTrue(state.isDirty)
        state.draft?.name = "Writing"
        state.draft?.instructions = "Improve prose."

        XCTAssertTrue(state.save(model: context.model))
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(context.model.preferences.cleanupPrompts.last?.id, id)

        state.draft?.instructions = "Changed locally."
        XCTAssertTrue(state.isDirty)
        state.discard()
        XCTAssertFalse(state.isDirty)
        XCTAssertEqual(state.draft?.instructions, "Improve prose.")
    }

    @MainActor
    func testPromptNavigationResetTransientStateClearsNavigationAndDraft() {
        let context = makeContext()
        let state = PromptLibraryNavigationState()
        let id = context.model.preferences.cleanupPrompts[0].id

        state.beginEditing(id, model: context.model)
        state.openPrompt(id)
        let firstDestination = state.destination
        state.resetTransientState()
        state.openPrompt(id)
        XCTAssertNotEqual(state.destination, firstDestination)
        state.pendingAction = .back
        state.showUnsavedConfirmation = true

        state.resetTransientState()

        XCTAssertNil(state.destination)
        XCTAssertNil(state.draft)
        XCTAssertNil(state.originalDraft)
        XCTAssertNil(state.pendingAction)
        XCTAssertFalse(state.showUnsavedConfirmation)
    }

    @MainActor
    func testListeningIndicatorFollowsDictationRecordingLifetime() async {
        let context = makeContext()

        context.model.startRecording()
        await appWaitUntil("recording") { context.model.state == .recording }

        XCTAssertEqual(context.listeningIndicator.labels, ["Listening…"])
        XCTAssertEqual(context.listeningIndicator.hideCount, 0)

        context.model.cancelRecording()

        XCTAssertEqual(context.model.state, .idle)
        XCTAssertEqual(context.listeningIndicator.hideCount, 1)
    }

    @MainActor
    func testListeningIndicatorRemainsVisibleDuringTranscription() async throws {
        let recorder = AppRecorderSpy()
        recorder.stopURL = try appTemporaryFile()
        let transcriber = AppControlledTranscriber()
        let cleaner = AppControlledCleaner()
        let context = makeContext(recorder: recorder, transcriber: transcriber, cleaner: cleaner)

        context.model.startRecording()
        await appWaitUntil("recording") { context.model.state == .recording }
        context.clock.advance(by: 1)
        context.model.stopRecording()
        await appWaitUntil("transcription request") { await transcriber.callCount == 1 }

        XCTAssertEqual(context.model.state, .transcribing)
        XCTAssertEqual(context.listeningIndicator.updatedLabels, ["Transcribing…"])
        XCTAssertEqual(context.listeningIndicator.hideCount, 0)

        await transcriber.succeed(with: "finished")
        await appWaitUntil("cleanup request") { await cleaner.callCount == 1 }
        XCTAssertEqual(context.listeningIndicator.updatedLabels, ["Transcribing…", "Improving text…"])
        XCTAssertEqual(context.listeningIndicator.hideCount, 0)

        await cleaner.succeed(with: "improved")
        await appWaitUntil("processing completion") { context.model.state == .idle }

        XCTAssertEqual(context.listeningIndicator.hideCount, 1)
    }

    @MainActor
    func testListeningIndicatorShowsWorkflowStepProgress() async throws {
        let recorder = AppRecorderSpy()
        recorder.stopURL = try appTemporaryFile()
        let first = CleanupPrompt(name: "Clean", systemImageName: "sparkles", instructions: "First prompt")
        let second = CleanupPrompt(name: "Format", systemImageName: "text.alignleft", instructions: "Second prompt")
        let workflow = CleanupWorkflow(name: "Publish", promptIDs: [first.id, second.id])
        let preferences = AppPreferences(
            interfaceLanguage: .english,
            cleanupPrompts: [first, second],
            cleanupWorkflows: [workflow],
            activeCleanupSelection: .workflow(workflow.id)
        )
        let cleaner = AppSequencedCleaner(results: [.success("first result"), .success("second result")])
        let context = makeContext(recorder: recorder, cleaner: cleaner, preferences: preferences)

        context.model.startRecording()
        await appWaitUntil("recording") { context.model.state == .recording }
        context.clock.advance(by: 1)
        context.model.stopRecording()
        await appWaitUntil("workflow completion") { context.model.state == .idle }

        let calls = await cleaner.calls
        XCTAssertEqual(calls.map(\.text), ["connection transcript", "first result"])
        XCTAssertEqual(context.listeningIndicator.updatedLabels, [
            "Transcribing…",
            "Improving text… 1/2",
            "Improving text… 2/2"
        ])
    }

    @MainActor
    func testEscapeCancelsRecordingAndInFlightTranscription() async throws {
        let recorder = AppRecorderSpy()
        recorder.stopURL = try appTemporaryFile()
        let transcriber = AppControlledTranscriber()
        let context = makeContext(recorder: recorder, transcriber: transcriber)

        context.model.startRecording()
        await appWaitUntil("recording") { context.model.state == .recording }
        context.hotkeys.onEscape?()

        XCTAssertEqual(context.model.state, .idle)
        XCTAssertEqual(recorder.cancelCount, 1)

        recorder.stopURL = try appTemporaryFile()
        context.model.startRecording()
        await appWaitUntil("second recording") { context.model.state == .recording }
        context.clock.advance(by: 1)
        context.model.stopRecording()
        await appWaitUntil("transcription request") { await transcriber.callCount == 1 }

        context.hotkeys.onEscape?()
        XCTAssertEqual(context.model.state, .idle)
        XCTAssertEqual(context.listeningIndicator.hideCount, 2)

        await transcriber.succeed(with: "late result")
        await Task.yield()
        XCTAssertTrue(context.delivery.delivered.isEmpty)
        XCTAssertEqual(
            context.feedback.events,
            [.recordingStarted, .recordingCancelled, .recordingStarted, .recordingStopped, .recordingCancelled]
        )
    }

    @MainActor
    private func makeContext(
        recorder: any AudioRecording = AppRecorderSpy(),
        transcriber: any SpeechTranscribing = AppTranscriberSpy(),
        cleaner: any TextCleaning = AppCleanerStub(),
        preferences: AppPreferences = AppPreferences(interfaceLanguage: .english),
        secrets: [UUID: String]? = nil,
        permissions: PermissionSpy = PermissionSpy(),
        modelCatalog: any RemoteModelDiscovering = ModelCatalogSpy(),
        audioCaptureTrimmingResources: any AudioCaptureTrimmingResourceManaging = UnavailableAudioCaptureTrimmingResourceManager(),
        cleanupPromptExportReader: any CleanupPromptExportReading = PromptLibraryExportReaderSpy(result: .failure(.unreadableFile)),
        codexCredentials: any CodexCredentialsStoring & CodexAccessTokenProviding = CodexCredentialStoreSpy(),
        codexAuthenticator: any CodexAuthenticating = CodexAuthenticatorSpy()
    ) -> AppContext {
        let preferences = configuredForExistingAppTests(preferences)
        let delivery = AppDeliverySpy()
        let logs = AppLogStore()
        let dependencies = DictationDependencies(
            audioRecorder: recorder,
            microphonePermission: permissions,
            textDelivery: delivery,
            transcriber: transcriber,
            cleaner: cleaner,
            logger: logs
        )
        let preferencesStore = PreferencesStoreSpy(preferences: preferences)
        let secretStore = SecretStoreSpy(secrets: secrets ?? [preferences.stt.id: "test-stt-key"])
        let hotkeys = HotkeySpy()
        let launch = LaunchAtLoginSpy()
        let feedback = FeedbackSpy()
        let listeningIndicator = ListeningIndicatorSpy()
        let clock = AppDate()
        let coordinator = DictationCoordinator(
            dependencies: dependencies,
            now: { clock.value },
            sleep: { duration in try await Task.sleep(for: duration) }
        )
        let connectionTest = ConnectionTestCoordinator(
            audioRecorder: recorder,
            microphonePermission: permissions,
            transcriber: transcriber,
            logger: logs,
            now: { clock.value },
            sessionArbiter: nil
        )
        let model = AppStore(dependencies: AppStoreDependencies(
            coordinator: coordinator,
            connectionTest: connectionTest,
            textDelivery: delivery,
            cleanupPromptExportReader: cleanupPromptExportReader,
            preferencesStore: preferencesStore,
            keychain: secretStore,
            codexCredentials: codexCredentials,
            codexAuthenticator: codexAuthenticator,
            modelCatalog: modelCatalog,
            audioCaptureTrimmingResources: audioCaptureTrimmingResources,
            hotkeys: hotkeys,
            launchAtLogin: launch,
            feedback: feedback,
            listeningIndicator: listeningIndicator,
            permissions: permissions,
            cleanupLibraryCloudSync: CleanupLibraryCloudSync(
                store: CleanupLibraryCloudStoreSpy(remoteLibrary: nil)
            ),
            logStore: logs,
            now: { clock.value }
        ), initialPreferences: preferences)
        return AppContext(
            model: model,
            delivery: delivery,
            preferencesStore: preferencesStore,
            secretStore: secretStore,
            hotkeys: hotkeys,
            launch: launch,
            feedback: feedback,
            listeningIndicator: listeningIndicator,
            permissions: permissions,
            clock: clock
        )
    }

    private func configuredForExistingAppTests(_ input: AppPreferences) -> AppPreferences {
        guard input.providerCatalog.isEmpty else { return input }
        var value = input
        let stt = ProviderConfiguration.openAITranscription
        let cleanup = ProviderConfiguration.openAIResponses
        value.providerCatalog = [
            .remote(RemoteProviderProfile(id: stt.id, kind: .openAICompatible, name: stt.name, baseURL: stt.baseURL, authentication: stt.authentication, customHeaderName: stt.customHeaderName, timeout: stt.timeout, stt: STTCapability(path: stt.path, model: stt.model))),
            .remote(RemoteProviderProfile(id: cleanup.id, kind: .openAICompatible, name: cleanup.name, baseURL: cleanup.baseURL, authentication: cleanup.authentication, customHeaderName: cleanup.customHeaderName, timeout: cleanup.timeout, ttt: TTTCapability(path: cleanup.path, model: cleanup.model, format: .responses)))
        ]
        value.selectedSTTProviderID = .remote(stt.id)
        value.selectedTTTProviderID = .remote(cleanup.id)
        value.cleanupEnabled = true
        return value
    }
}

private struct PromptLibraryExportReaderSpy: CleanupPromptExportReading {
    let result: Result<CleanupPromptExport, CleanupPromptImportError>

    func readExport(at _: URL) throws(CleanupPromptImportError) -> CleanupPromptExport {
        try result.get()
    }
}

private actor CodexCredentialStoreSpy: CodexCredentialsStoring, CodexAccessTokenProviding {
    var current: CodexCredentials?
    private(set) var saved: [CodexCredentials?] = []

    func readCodexCredentials() async throws -> CodexCredentials? { current }
    func saveCodexCredentials(_ credentials: CodexCredentials?) async throws {
        current = credentials
        saved.append(credentials)
    }
    func validCredentials() async throws -> CodexCredentials {
        guard let current else { throw CodexCredentialStoreError.missing }
        return current
    }

    private enum CodexCredentialStoreError: Error { case missing }
}

@MainActor
private final class CodexAuthenticatorSpy: CodexAuthenticating {
    var result: Result<CodexCredentials, any Error>

    init(result: Result<CodexCredentials, any Error> = .failure(CodexAuthenticatorError.unavailable)) {
        self.result = result
    }

    func connect() async throws -> CodexCredentials { try result.get() }

    private enum CodexAuthenticatorError: Error { case unavailable }
}

private actor ModelCatalogSpy: RemoteModelDiscovering {
    let models: [String]
    init(models: [String] = []) { self.models = models }
    func discoverModels(configuration: ProviderConfiguration, apiKey: String) async throws -> [String] {
        Array(Set(models)).sorted()
    }
}

@MainActor
private struct AppContext {
    let model: AppStore
    let delivery: AppDeliverySpy
    let preferencesStore: PreferencesStoreSpy
    let secretStore: SecretStoreSpy
    let hotkeys: HotkeySpy
    let launch: LaunchAtLoginSpy
    let feedback: FeedbackSpy
    let listeningIndicator: ListeningIndicatorSpy
    let permissions: PermissionSpy
    let clock: AppDate
}
