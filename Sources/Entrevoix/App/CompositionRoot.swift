import Foundation
import EntrevoixCore

@MainActor
enum CompositionRoot {
    enum LaunchState {
        case ready(AppEnvironment, recoveredPreferences: Bool)
        case incompatible(schemaVersion: Int, updater: any ApplicationUpdating)
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
            return .incompatible(schemaVersion: schemaVersion, updater: updater)
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

    private static func makeEnvironment(
        preferencesStore: UserDefaultsPreferencesStore,
        initialPreferences: AppPreferences,
        updater: any ApplicationUpdating = SparkleUpdateService()
    ) -> AppEnvironment {
        let audioInputDevices = CoreAudioInputDeviceCatalog()
        let logStore = AppLogStore()
        let audioRecorder = AudioRecorder(logger: logStore)
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
                audioRecorder: audioRecorder,
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
            logStore: logStore,
            now: Date.init
        ), initialPreferences: initialPreferences)
        return AppEnvironment(appStore: appStore)
    }
}
