import Foundation
import Testing
import EntrevoixAppleAdapters
import EntrevoixCore
import EntrevoixOpenAIAdapters

@Test
func sharedAdaptersExposeConsumerConstructors() {
    let remoteTranscriber: any SpeechTranscribing = OpenAITranscriptionService()
    let remoteCleaner: any TextCleaning = OpenAITextCleanupService()
    let anthropicCleaner: any TextCleaning = AnthropicTextCleanupService()
    let modelCatalog: any RemoteModelDiscovering = RemoteModelCatalogClient()
    let appleTranscriber: any SpeechTranscribing = AppleSpeechTranscriptionService()
    let appleCleaner: any TextCleaning = AppleFoundationCleanupService()
    let trimmer: any AudioCaptureTrimming = AppleSpeechAudioCaptureTrimmer()
    let trimmingResources: any AudioCaptureTrimmingResourceManaging = AppleSpeechAudioCaptureTrimmingResourceManager()
    let preferences: any PreferencesStoring = UserDefaultsPreferencesStore(
        defaults: UserDefaults(suiteName: "EntrevoixAdapterAPITests")!,
        recoveryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("preferences-recovery.json")
    )
    let keychain: any SecretStoring = KeychainStore(service: "com.d9beuD.Entrevoix.tests")
    let exportReader: any CleanupPromptExportReading = JSONCleanupPromptExportReader()

    withExtendedLifetime((
        remoteTranscriber,
        remoteCleaner,
        anthropicCleaner,
        modelCatalog,
        appleTranscriber,
        appleCleaner,
        trimmer,
        trimmingResources,
        preferences,
        keychain,
        exportReader
    )) {}
}
