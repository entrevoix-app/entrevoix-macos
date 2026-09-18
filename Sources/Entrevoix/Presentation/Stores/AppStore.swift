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
    let recordingRetention: RecordingRetentionStore
    let providerStore: ProviderStore
    let permissionsModel: PermissionsStore
    let promptLibrary: PromptLibraryStore
    private let cloudSyncLifecycle: CloudSyncLifecycleStore
    let updates: UpdateStore
    private let launchAtLoginService: any LaunchAtLoginControlling
    private let recordingsFolderOpener: any RecordingsFolderOpening
    let logStore: AppLogStore
    private(set) var recordingsFolderOpenFailed = false

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
        cloudSyncLifecycle.publishDictationDictionary()
        return true
    }

    func removeDictationDictionaryTerm(_ term: String) {
        guard let index = preferences.dictationDictionary.firstIndex(of: term) else { return }
        preferences.dictationDictionary.remove(at: index)
        savePreferences()
        cloudSyncLifecycle.publishDictationDictionary()
    }

    @discardableResult
    func updateDictationDictionaryTerm(_ term: String, to rawTerm: String) -> Bool {
        guard let updatedTerm = AppPreferences.normalizedDictationDictionary([rawTerm]).first,
              let index = preferences.dictationDictionary.firstIndex(of: term),
              updatedTerm == term || !preferences.dictationDictionary.contains(updatedTerm) else { return false }
        preferences.dictationDictionary[index] = updatedTerm
        savePreferences()
        cloudSyncLifecycle.publishDictationDictionary()
        return true
    }

    var cleanupPromptForDisplay: String { activeCleanupPrompt?.instructions ?? "" }

    init(
        dictationSession: DictationStore,
        connectionTestStore: ConnectionTestStore,
        audioInput: AudioInputStore,
        preferencesModel: PreferencesStore,
        recordingRetention: RecordingRetentionStore,
        providerStore: ProviderStore,
        permissionsModel: PermissionsStore,
        promptLibrary: PromptLibraryStore,
        cloudSyncLifecycle: CloudSyncLifecycleStore,
        updates: UpdateStore,
        launchAtLoginService: any LaunchAtLoginControlling,
        recordingsFolderOpener: any RecordingsFolderOpening,
        logStore: AppLogStore
    ) {
        self.dictationSession = dictationSession
        self.connectionTestStore = connectionTestStore
        self.audioInput = audioInput
        self.preferencesModel = preferencesModel
        self.recordingRetention = recordingRetention
        self.providerStore = providerStore
        self.permissionsModel = permissionsModel
        self.promptLibrary = promptLibrary
        self.cloudSyncLifecycle = cloudSyncLifecycle
        self.updates = updates
        self.launchAtLoginService = launchAtLoginService
        self.recordingsFolderOpener = recordingsFolderOpener
        self.logStore = logStore
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

    func requestUnresolvedPermissionsAtLaunch() {
        permissionsModel.requestUnresolvedPermissionsAtLaunch()
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

    func setDeleteAudioAfterTranscription(_ enabled: Bool) {
        recordingRetention.setDeleteAudioAfterTranscription(enabled)
    }

    func openRecordingsFolder() {
        do {
            try recordingsFolderOpener.openRecordingsFolder()
            recordingsFolderOpenFailed = false
        } catch {
            recordingsFolderOpenFailed = true
            logStore.log("Error: could not open recordings folder.")
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
        cloudSyncLifecycle.refreshCleanupLibrary()
    }

    func refreshDictationDictionary() {
        cloudSyncLifecycle.refreshDictationDictionary()
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
