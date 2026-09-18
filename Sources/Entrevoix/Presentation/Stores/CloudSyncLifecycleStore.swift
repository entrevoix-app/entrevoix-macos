import EntrevoixCore

@MainActor
final class CloudSyncLifecycleStore {
    private let preferencesModel: PreferencesStore
    private let cleanupLibraryCloudSync: CleanupLibraryCloudSync
    private let dictationDictionaryCloudSync: DictationDictionaryCloudSync

    init(preferencesModel: PreferencesStore, cleanupLibraryCloudSync: CleanupLibraryCloudSync, dictationDictionaryCloudSync: DictationDictionaryCloudSync) {
        self.preferencesModel = preferencesModel
        self.cleanupLibraryCloudSync = cleanupLibraryCloudSync
        self.dictationDictionaryCloudSync = dictationDictionaryCloudSync
        cleanupLibraryCloudSync.onRemoteLibrary = { [weak preferencesModel] library in
            guard let preferencesModel else { return }
            var preferences = preferencesModel.preferences
            preferences.cleanupPrompts = library.prompts
            preferences.cleanupWorkflows = library.workflows
            preferences.normalizeCleanupSelection()
            if case .prompt(let id) = preferences.activeCleanupSelection,
               let prompt = preferences.cleanupPrompts.first(where: { $0.id == id }) {
                preferences.cleanupPrompt = prompt.instructions
                preferences.cleanupPromptMode = .custom
            }
            preferencesModel.update(preferences, to: .immediate)
        }
        dictationDictionaryCloudSync.onRemoteTerms = { [weak preferencesModel] terms in
            guard let preferencesModel else { return }
            var preferences = preferencesModel.preferences
            preferences.dictationDictionary = AppPreferences.normalizedDictationDictionary(terms)
            preferencesModel.update(preferences, to: .immediate)
        }
    }

    func start(with preferences: AppPreferences, seedLocalLibrary: Bool) {
        cleanupLibraryCloudSync.start(with: CleanupLibrary(prompts: preferences.cleanupPrompts, workflows: preferences.cleanupWorkflows), seedLocalLibrary: seedLocalLibrary)
        dictationDictionaryCloudSync.start(with: preferences.dictationDictionary, seedLocalTerms: !preferences.dictationDictionary.isEmpty)
    }

    func publishCleanupLibrary() { cleanupLibraryCloudSync.publish(preferencesModel.preferences) }
    func publishDictationDictionary() { dictationDictionaryCloudSync.publish(preferencesModel.preferences.dictationDictionary) }
    func refreshCleanupLibrary() { cleanupLibraryCloudSync.refresh() }
    func refreshDictationDictionary() { dictationDictionaryCloudSync.refresh() }
}
