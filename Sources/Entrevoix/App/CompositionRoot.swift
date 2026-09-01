import Foundation
import EntrevoixAppleAdapters
import EntrevoixCore
import EntrevoixOpenAIAdapters

@MainActor
enum CompositionRoot {
    enum LaunchState {
        case ready(AppEnvironment, recoveredPreferences: Bool)
        case incompatible(
            schemaVersion: Int,
            preferencesStore: any PreferencesStoring,
            updater: any ApplicationUpdating
        )
    }

    static func makeLaunchState() -> LaunchState {
        let updater = SparkleUpdateService()
        LegacyMurmureMigration.run()
        let preferencesStore = UserDefaultsPreferencesStore()
        var loadedPreferences: AppPreferences
        let recovered: Bool

        switch preferencesStore.load() {
        case .loaded(let preferences):
            loadedPreferences = preferences
            recovered = false
        case .recovered(let preferences):
            loadedPreferences = preferences
            recovered = true
        case .incompatible(let schemaVersion):
            return .incompatible(
                schemaVersion: schemaVersion,
                preferencesStore: preferencesStore,
                updater: updater
            )
        }

        let migratedPreferences = PreferencesMigrator.migrate(
            loadedPreferences,
            localizedDefaultPrompt: EntrevoixLocalization.defaultCleanupPrompt(
                locale: EntrevoixLocalization.locale(for: loadedPreferences.interfaceLanguage)
            )
        )
        if migratedPreferences != loadedPreferences {
            preferencesStore.save(migratedPreferences)
            loadedPreferences = migratedPreferences
        }

        return .ready(
            makeEnvironment(
                preferencesStore: preferencesStore,
                initialPreferences: loadedPreferences,
                updater: updater
            ),
            recoveredPreferences: recovered
        )
    }

    static func makeEnvironment(
        preferencesStore: any PreferencesStoring,
        initialPreferences: AppPreferences,
        updater: any ApplicationUpdating = SparkleUpdateService()
    ) -> AppEnvironment {
        let audioInputDevices = CoreAudioInputDeviceCatalog()
        let logStore = AppLogStore()
        let audioRecorder = AudioRecorder(logger: logStore)
        let recordingRetentionPreferences = UserDefaultsRecordingRetentionPreferencesStore()
        let recordingRetention = RecordingRetentionStore(preferencesStore: recordingRetentionPreferences)
        let recordingArchive = RecordingArchive()
        let dictationAudioRecorder = DictationAudioRetentionRecorder(
            recorder: audioRecorder,
            archive: recordingArchive,
            deleteAudioAfterTranscription: { recordingRetention.deleteAudioAfterTranscription },
            logger: logStore
        )
        let permissions = SystemPermissionProvider()
        let transport = SafeNetworkSession()
        let codexCredentials = CodexCredentialVault()
        let speechResources = AppleSpeechResourceManager()
        let transcriber = ProviderSpeechRouter(
            remote: OpenAITranscriptionService(transport: transport),
            apple: AppleSpeechTranscriptionService(resources: speechResources)
        )
        let cleaner = ProviderCleanupRouter(
            remote: OpenAITextCleanupService(transport: transport),
            anthropic: AnthropicTextCleanupService(transport: transport),
            codex: CodexCleanupService(
                transport: transport,
                credentialsProvider: codexCredentials
            ),
            apple: AppleFoundationCleanupService()
        )
        let textDelivery = TextDelivery()
        let sessionArbiter = SessionArbiter()
        let audioCaptureTrimmer = AppleSpeechAudioCaptureTrimmer()
        let audioCaptureTrimmingResources = AppleSpeechAudioCaptureTrimmingResourceManager()

        let coordinator = DictationCoordinator(
            dependencies: DictationDependencies(
                audioRecorder: dictationAudioRecorder,
                audioCaptureTrimmer: audioCaptureTrimmer,
                microphonePermission: permissions,
                textDelivery: textDelivery,
                transcriber: transcriber,
                cleaner: cleaner,
                logger: logStore,
                sessionArbiter: sessionArbiter
            )
        )
        let connectionTest = ConnectionTestCoordinator(
            audioRecorder: audioRecorder,
            audioCaptureTrimmer: audioCaptureTrimmer,
            microphonePermission: permissions,
            transcriber: transcriber,
            logger: logStore,
            now: Date.init,
            sessionArbiter: sessionArbiter
        )

        let appStore = AppStore(dependencies: AppStoreDependencies(
            coordinator: coordinator,
            connectionTest: connectionTest,
            textDelivery: textDelivery,
            cleanupPromptExportReader: JSONCleanupPromptExportReader(),
            preferencesStore: preferencesStore,
            recordingRetention: recordingRetention,
            recordingsFolderOpener: recordingArchive,
            keychain: KeychainStore(legacyService: LegacyMurmureMigration.legacyKeychainService),
            codexCredentials: codexCredentials,
            codexAuthenticator: CodexBrowserAuthenticator(),
            modelCatalog: RemoteModelCatalogClient(transport: transport),
            audioCaptureTrimmingResources: audioCaptureTrimmingResources,
            providerAlerts: QueuedProviderAlertPresenter(),
            hotkeys: HotkeyService(),
            launchAtLogin: LaunchAtLoginService(),
            feedback: SoundFeedback(),
            listeningIndicator: ListeningIndicatorController(
                audioLevelProvider: audioRecorder,
                logger: logStore
            ),
            permissions: permissions,
            audioInputDevices: audioInputDevices,
            updater: updater,
            cleanupLibraryCloudSync: CleanupLibraryCloudSync(),
            dictationDictionaryCloudSync: DictationDictionaryCloudSync(),
            logStore: logStore,
            now: Date.init
        ), initialPreferences: initialPreferences)
        return AppEnvironment(appStore: appStore)
    }
}

@MainActor
final class IncompatibleStartupActionHandler {
    enum Action {
        case update
        case openAnyway
        case quit
    }

    enum Result {
        case incompatible
        case ready(AppPreferences, any PreferencesStoring)
    }

    private let updater: any ApplicationUpdating
    private let terminate: () -> Void

    init(
        preferencesStore: any PreferencesStoring,
        updater: any ApplicationUpdating,
        terminate: @escaping () -> Void
    ) {
        self.updater = updater
        self.terminate = terminate
    }

    @discardableResult
    func handle(_ action: Action) -> Result {
        switch action {
        case .update:
            updater.checkForUpdates()
            return .incompatible
        case .openAnyway:
            return .ready(AppPreferences(), InMemoryPreferencesStore())
        case .quit:
            terminate()
            return .incompatible
        }
    }
}

private final class InMemoryPreferencesStore: PreferencesStoring {
    private var preferences = AppPreferences()

    func load() -> PreferencesLoadResult {
        .loaded(preferences)
    }

    func save(_ preferences: AppPreferences) {
        self.preferences = preferences
    }

    func reset() {
        preferences = AppPreferences()
    }
}
