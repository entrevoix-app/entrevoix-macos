import Foundation
import EntrevoixCore
import Observation

@MainActor
@Observable
final class AppStore {
    let dictationSession: DictationStore
    let connectionTestStore: ConnectionTestStore
    let audioInput: AudioInputStore
    let preferencesModel: PreferencesStore
    let providerStore: ProviderStore
    let permissionsModel: PermissionsStore
    let promptLibrary: PromptLibraryStore
    private let cleanupLibraryCloudSync: CleanupLibraryCloudSync
    let updates: UpdateStore
    private let launchAtLoginService: any LaunchAtLoginControlling
    let logStore: AppLogStore

    var preferences: AppPreferences {
        get { preferencesModel.preferences }
        set { preferencesModel.update(newValue) }
    }
    private(set) var interfaceLanguageRevision = 0
    var sttAPIKey: String {
        get { preferencesModel.sttAPIKey }
        set { preferencesModel.updateSTTAPIKey(newValue) }
    }
    var cleanupAPIKey: String {
        get { preferencesModel.cleanupAPIKey }
        set { preferencesModel.updateCleanupAPIKey(newValue) }
    }
    var connectionTestState: ConnectionTestState { connectionTestStore.state }
    var mode: TriggerMode { dictationSession.mode }
    private var launchAtLoginErrorDetail: String?
    var launchAtLoginError: String? {
        guard let launchAtLoginErrorDetail else { return nil }
        let format = EntrevoixLocalization.text(
            "error.launch_at_login",
            defaultValue: "Could not change the launch at login setting: %@",
            locale: interfaceLocale
        )
        return String(format: format, locale: interfaceLocale, arguments: [launchAtLoginErrorDetail])
    }
    var permissionsRevision: Int { permissionsModel.revision }
    var isResettingMicrophonePermission: Bool { permissionsModel.isResettingMicrophonePermission }
    var microphonePermissionRepairFeedback: MicrophonePermissionRepairFeedback? {
        permissionsModel.microphonePermissionRepairFeedback
    }
    var lastAudioURL: URL? { dictationSession.lastAudioURL }

    var lastTranscript: String? { dictationSession.lastTranscript }
    var discoveredModels: [UUID: [String]] { providerStore.discoveredModels }
    var modelDiscoveryError: String? { providerStore.modelDiscoveryErrors.values.first }
    var codexConnectionState: CodexConnectionState { providerStore.codexConnectionState }
    var audioCaptureTrimmingResourceState: AudioCaptureTrimmingResourceState {
        providerStore.audioCaptureTrimmingResourceState
    }

    var interfaceLocale: Locale {
        _ = interfaceLanguageRevision
        return EntrevoixLocalization.locale(for: preferences.interfaceLanguage)
    }

    var activeCleanupPrompt: CleanupPrompt? {
        promptLibrary.activePrompt
    }

    var activeCleanupWorkflow: CleanupWorkflow? {
        promptLibrary.activeWorkflow
    }

    var hasActiveCleanupPrompt: Bool { activeCleanupPrompt != nil }

    var hasActiveCleanupTransformation: Bool { promptLibrary.activeSelection != nil }

    var cleanupPromptLibraryDiffersFromDefault: Bool {
        promptLibrary.differsFromDefault
    }

    func setInterfaceLanguage(_ language: InterfaceLanguage) {
        guard preferences.interfaceLanguage != language else { return }
        preferences.interfaceLanguage = language
        interfaceLanguageRevision &+= 1
        savePreferences()
    }

    func setSTTLanguage(_ language: TranscriptionLanguage) {
        var changed = preferences.sttLanguage != language
        preferences.sttLanguage = language
        if language != .automatic && !preferences.sttFavoriteLanguages.contains(language) {
            preferences.sttFavoriteLanguages.append(language)
            changed = true
        }
        if changed {
            savePreferences()
        }
        providerStore.refreshAudioCaptureTrimmingResourceState()
    }

    func setTrimLeadingAndTrailingSilence(_ enabled: Bool) {
        guard preferences.trimLeadingAndTrailingSilence != enabled else { return }
        preferences.trimLeadingAndTrailingSilence = enabled
        savePreferences()
        if enabled {
            providerStore.refreshAudioCaptureTrimmingResourceState()
        }
    }

    func setReduceLongInternalPauses(_ enabled: Bool) {
        guard preferences.reduceLongInternalPauses != enabled else { return }
        preferences.reduceLongInternalPauses = enabled
        savePreferences()
    }

    func refreshAudioCaptureTrimmingResourceState() {
        providerStore.refreshAudioCaptureTrimmingResourceState()
    }

    func downloadAudioCaptureTrimmingResource() {
        providerStore.downloadAudioCaptureTrimmingResource()
    }

    func setSTTFavoriteLanguage(_ language: TranscriptionLanguage, enabled: Bool) {
        guard language != .automatic else { return }
        if enabled {
            guard !preferences.sttFavoriteLanguages.contains(language) else { return }
            preferences.sttFavoriteLanguages.append(language)
        } else {
            guard preferences.sttLanguage != language,
                  let index = preferences.sttFavoriteLanguages.firstIndex(of: language) else { return }
            preferences.sttFavoriteLanguages.remove(at: index)
        }
        savePreferences()
    }

    var providersSortedForDisplay: [ProviderCatalogEntry] {
        providerStore.providersSortedForDisplay
    }

    func providerName(_ entry: ProviderCatalogEntry) -> String {
        providerStore.providerName(entry)
    }

    func apiKey(for provider: ProviderIdentifier?) -> String { providerStore.apiKey(for: provider) }

    func setAPIKey(_ value: String, for provider: ProviderIdentifier?) {
        providerStore.setAPIKey(value, for: provider)
    }

    func setSTTProvider(_ id: ProviderIdentifier?) {
        providerStore.setSTTProvider(id)
    }

    func setTTTProvider(_ id: ProviderIdentifier?) {
        providerStore.setTTTProvider(id)
    }

    func addAppleProvider() {
        providerStore.addAppleProvider()
    }

    func addCodexProvider() {
        providerStore.addCodexProvider()
    }

    func setCodexModel(_ model: CodexModel) {
        providerStore.setCodexModel(model)
    }

    func connectCodex() {
        providerStore.connectCodex()
    }

    func disconnectCodex() {
        providerStore.disconnectCodex()
    }

    func removeCodexProvider() {
        providerStore.removeCodexProvider()
    }

    func newRemoteProvider(kind: RemoteProviderKind) -> RemoteProviderProfile {
        providerStore.newRemoteProvider(kind: kind)
    }

    @discardableResult
    func saveRemoteProvider(_ draft: RemoteProviderProfile, apiKey: String) -> [ProviderValidationIssue] {
        providerStore.saveRemoteProvider(draft, apiKey: apiKey)
    }

    @discardableResult
    func removeProvider(_ id: ProviderIdentifier) -> Bool {
        providerStore.removeProvider(id)
    }

    func loadModels(for profile: RemoteProviderProfile) {
        providerStore.loadModels(for: profile)
    }

    @discardableResult
    func addDictationDictionaryTerm(_ rawTerm: String) -> Bool {
        guard let term = AppPreferences.normalizedDictationDictionary([rawTerm]).first,
              !preferences.dictationDictionary.contains(term) else { return false }
        preferences.dictationDictionary.append(term)
        savePreferences()
        return true
    }

    func removeDictationDictionaryTerm(_ term: String) {
        guard let index = preferences.dictationDictionary.firstIndex(of: term) else { return }
        preferences.dictationDictionary.remove(at: index)
        savePreferences()
    }

    @discardableResult
    func updateDictationDictionaryTerm(_ term: String, to rawTerm: String) -> Bool {
        guard let updatedTerm = AppPreferences.normalizedDictationDictionary([rawTerm]).first,
              let index = preferences.dictationDictionary.firstIndex(of: term),
              updatedTerm == term || !preferences.dictationDictionary.contains(updatedTerm) else { return false }
        preferences.dictationDictionary[index] = updatedTerm
        savePreferences()
        return true
    }

    var cleanupPromptForDisplay: String { activeCleanupPrompt?.instructions ?? "" }

    init(dependencies: AppStoreDependencies, initialPreferences: AppPreferences) {
        logStore = dependencies.logStore
        let preferencesModel = PreferencesStore(
            preferencesStore: dependencies.preferencesStore,
            keychain: dependencies.keychain,
            initialPreferences: initialPreferences
        )
        self.preferencesModel = preferencesModel
        self.audioInput = AudioInputStore(
            preferencesStore: preferencesModel,
            deviceCatalog: dependencies.audioInputDevices
        )
        self.updates = UpdateStore(preferencesModel: preferencesModel, updater: dependencies.updater)
        let providerStore = ProviderStore(
            preferencesStore: preferencesModel,
            modelCatalog: dependencies.modelCatalog,
            codexCredentialsStore: dependencies.codexCredentials,
            codexAuthenticator: dependencies.codexAuthenticator,
            audioCaptureTrimmingResources: dependencies.audioCaptureTrimmingResources,
            logStore: dependencies.logStore
        )
        self.providerStore = providerStore
        let permissionsModel = PermissionsStore(provider: dependencies.permissions)
        self.permissionsModel = permissionsModel
        let cleanupLibraryCloudSync = dependencies.cleanupLibraryCloudSync
        self.cleanupLibraryCloudSync = cleanupLibraryCloudSync
        let promptLibrary = PromptLibraryStore(
            preferencesModel: preferencesModel,
            exportReader: dependencies.cleanupPromptExportReader,
            libraryDidChange: { [weak cleanupLibraryCloudSync, weak preferencesModel] in
                guard let cleanupLibraryCloudSync, let preferencesModel else { return }
                cleanupLibraryCloudSync.publish(preferencesModel.preferences)
            }
        )
        self.promptLibrary = promptLibrary
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
        cleanupLibraryCloudSync.start(
            with: CleanupLibrary(
                prompts: initialPreferences.cleanupPrompts,
                workflows: initialPreferences.cleanupWorkflows
            ),
            seedLocalLibrary: promptLibrary.differsFromDefault
        )
        let connectionTestStore = ConnectionTestStore(
            coordinator: dependencies.connectionTest,
            providerStore: providerStore,
            permissionsStore: permissionsModel,
            feedback: dependencies.feedback,
            textDelivery: dependencies.textDelivery
        )
        self.connectionTestStore = connectionTestStore
        let dictationSession = DictationStore(
            coordinator: dependencies.coordinator,
            providerStore: providerStore,
            permissionsStore: permissionsModel,
            promptLibrary: promptLibrary,
            hotkeys: dependencies.hotkeys,
            textDelivery: dependencies.textDelivery,
            soundFeedback: dependencies.feedback,
            listeningIndicator: dependencies.listeningIndicator,
            providerAlerts: dependencies.providerAlerts,
            logStore: dependencies.logStore,
            now: dependencies.now
        )
        self.dictationSession = dictationSession
        dictationSession.canStart = { [weak connectionTestStore] in
            connectionTestStore?.state.isInactive ?? false
        }
        connectionTestStore.canStart = { [weak dictationSession] in
            dictationSession?.state == .idle
        }
        launchAtLoginService = dependencies.launchAtLogin
    }

    func savePreferences() {
        preferencesModel.savePreferencesImmediately()
    }

    var requiresOnboarding: Bool { !preferences.hasCompletedOnboarding }

    var microphonePermission: PermissionStatus {
        permissionsModel.microphonePermission
    }

    var accessibilityPermission: PermissionStatus {
        permissionsModel.accessibilityPermission
    }

    var launchAtLoginEnabled: Bool {
        launchAtLoginService.isEnabled
    }

    func completeOnboarding() {
        preferences.hasCompletedOnboarding = true
        savePreferences()
    }

    func requestMicrophonePermission() {
        permissionsModel.requestMicrophonePermission()
    }

    func resetMicrophonePermission() {
        permissionsModel.resetMicrophonePermission()
    }

    func requestAccessibilityPermission() {
        permissionsModel.requestAccessibilityPermission()
    }

    func refreshPermissions() {
        permissionsModel.refresh()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginService.setEnabled(enabled)
            preferences.launchAtLogin = enabled
            launchAtLoginErrorDetail = nil
            savePreferences()
        } catch {
            launchAtLoginErrorDetail = error.localizedDescription
            logStore.log("Error: could not change the launch at login setting.")
        }
    }

    func setActiveCleanupPrompt(_ id: UUID?) {
        promptLibrary.setActive(id)
    }

    func setActiveCleanupWorkflow(_ id: UUID?) {
        promptLibrary.setActiveWorkflow(id)
    }

    @discardableResult
    func saveCleanupPrompt(_ prompt: CleanupPrompt) -> CleanupPromptValidationError? {
        promptLibrary.save(prompt)
    }

    func deleteCleanupPrompt(id: UUID) {
        promptLibrary.delete(id: id)
    }

    @discardableResult
    func saveCleanupWorkflow(_ workflow: CleanupWorkflow) -> CleanupWorkflowValidationError? {
        promptLibrary.saveWorkflow(workflow)
    }

    func deleteCleanupWorkflow(id: UUID) {
        promptLibrary.deleteWorkflow(id: id)
    }

    func resetPromptLibrary() {
        promptLibrary.reset()
    }

    func makeCleanupPromptExport() -> CleanupPromptExport {
        promptLibrary.makeExport()
    }

    func importCleanupPrompts(from url: URL) -> Result<CleanupPromptImportResult, CleanupPromptImportError> {
        promptLibrary.importPrompts(from: url)
    }

    func resetCleanupPrompt() { resetPromptLibrary() }

    func refreshCleanupLibrary() {
        cleanupLibraryCloudSync.refresh()
    }

    var state: DictationState { dictationSession.state }

    func setMode(_ newMode: TriggerMode) {
        dictationSession.setMode(newMode)
    }

    func handleKeyDown() {
        dictationSession.handleKeyDown()
    }

    func handleKeyUp() {
        dictationSession.handleKeyUp()
    }

    func handleEscape() {
        dictationSession.handleEscape()
    }

    func startRecording() {
        dictationSession.startRecording()
    }

    func stopRecording() {
        dictationSession.stopRecording()
    }

    func cancelRecording() {
        dictationSession.cancelRecording()
    }

    func startSTTConnectionTest() {
        connectionTestStore.start()
    }

    func finishSTTConnectionTest() {
        connectionTestStore.finish()
    }

    func cancelSTTConnectionTest() {
        connectionTestStore.cancel()
    }

    func copyTestText() {
        connectionTestStore.copyTestText()
    }

    func pasteTestText() {
        connectionTestStore.pasteTestText()
    }

    func deleteLastCapture() {
        dictationSession.deleteLastCapture()
    }

    func copyTranscript() {
        dictationSession.copyTranscript()
    }

    func deliverTranscript() {
        dictationSession.deliverTranscript()
    }
}
