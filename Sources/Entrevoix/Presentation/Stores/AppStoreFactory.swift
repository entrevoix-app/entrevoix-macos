import EntrevoixCore

@MainActor
enum AppStoreFactory {
    static func make(
        dependencies: AppStoreDependencies,
        initialPreferences: AppPreferences,
        initialPreferencesAreFresh: Bool = false
    ) -> AppStore {
        let preferencesModel = PreferencesStore(preferencesStore: dependencies.preferencesStore, keychain: dependencies.keychain, initialPreferences: initialPreferences)
        let providerStore = ProviderStore(preferencesStore: preferencesModel, modelCatalog: dependencies.modelCatalog, codexCredentialsStore: dependencies.codexCredentials, codexAuthenticator: dependencies.codexAuthenticator, audioCaptureTrimmingResources: dependencies.audioCaptureTrimmingResources, logStore: dependencies.logStore, initialPreferencesAreFresh: initialPreferencesAreFresh)
        let permissionsModel = PermissionsStore(provider: dependencies.permissions)
        let lifecycle = CloudSyncLifecycleStore(preferencesModel: preferencesModel, cleanupLibraryCloudSync: dependencies.cleanupLibraryCloudSync, dictationDictionaryCloudSync: dependencies.dictationDictionaryCloudSync)
        let promptLibrary = PromptLibraryStore(preferencesModel: preferencesModel, exportReader: dependencies.cleanupPromptExportReader, libraryDidChange: { [weak lifecycle] in lifecycle?.publishCleanupLibrary() })
        let connectionTestStore = ConnectionTestStore(coordinator: dependencies.connectionTest, providerStore: providerStore, permissionsStore: permissionsModel, feedback: dependencies.feedback, textDelivery: dependencies.textDelivery)
        let dictationSession = DictationStore(coordinator: dependencies.coordinator, providerStore: providerStore, permissionsStore: permissionsModel, promptLibrary: promptLibrary, hotkeys: dependencies.hotkeys, textDelivery: dependencies.textDelivery, soundFeedback: dependencies.feedback, listeningIndicator: dependencies.listeningIndicator, providerAlerts: dependencies.providerAlerts, logStore: dependencies.logStore, now: dependencies.now)
        dictationSession.canStart = { [weak connectionTestStore] in connectionTestStore?.state.isInactive ?? false }
        connectionTestStore.canStart = { [weak dictationSession] in dictationSession?.state == .idle }
        let audioInput = AudioInputStore(preferencesStore: preferencesModel, deviceCatalog: dependencies.audioInputDevices)
        dependencies.listeningIndicator.configureSelectors(
            promptLibrary: promptLibrary,
            audioInput: audioInput,
            interfaceLocale: { [weak preferencesModel] in
                guard let preferencesModel else { return .current }
                return EntrevoixLocalization.locale(for: preferencesModel.preferences.interfaceLanguage)
            }
        )
        let appStore = AppStore(dictationSession: dictationSession, connectionTestStore: connectionTestStore, audioInput: audioInput, preferencesModel: preferencesModel, recordingRetention: dependencies.recordingRetention, providerStore: providerStore, permissionsModel: permissionsModel, promptLibrary: promptLibrary, cloudSyncLifecycle: lifecycle, updates: UpdateStore(preferencesModel: preferencesModel, updater: dependencies.updater), launchAtLoginService: dependencies.launchAtLogin, recordingsFolderOpener: dependencies.recordingsFolderOpener, logStore: dependencies.logStore)
        lifecycle.start(with: initialPreferences, seedLocalLibrary: promptLibrary.differsFromDefault)
        return appStore
    }
}
