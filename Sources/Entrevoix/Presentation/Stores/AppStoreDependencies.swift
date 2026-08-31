import Foundation
import EntrevoixCore

@MainActor
struct AppStoreDependencies {
    let coordinator: DictationCoordinator
    let connectionTest: ConnectionTestCoordinator
    let textDelivery: any TextDelivering
    let cleanupPromptExportReader: any CleanupPromptExportReading
    let preferencesStore: any PreferencesStoring
    let recordingRetention: RecordingRetentionStore
    let recordingsFolderOpener: any RecordingsFolderOpening
    let keychain: any SecretStoring
    let codexCredentials: any CodexCredentialsStoring & CodexAccessTokenProviding
    let codexAuthenticator: any CodexAuthenticating
    let modelCatalog: any RemoteModelDiscovering
    let audioCaptureTrimmingResources: any AudioCaptureTrimmingResourceManaging
    let providerAlerts: any ProviderAlertPresenting
    let hotkeys: any HotkeyHandling
    let launchAtLogin: any LaunchAtLoginControlling
    let feedback: any FeedbackPlaying
    let listeningIndicator: any ListeningIndicatorPresenting
    let permissions: any PermissionProviding
    let audioInputDevices: any AudioInputDeviceDiscovering
    let updater: any ApplicationUpdating
    let cleanupLibraryCloudSync: CleanupLibraryCloudSync
    let dictationDictionaryCloudSync: DictationDictionaryCloudSync
    let logStore: AppLogStore
    let now: () -> Date

    init(
        coordinator: DictationCoordinator,
        connectionTest: ConnectionTestCoordinator,
        textDelivery: any TextDelivering,
        cleanupPromptExportReader: any CleanupPromptExportReading,
        preferencesStore: any PreferencesStoring,
        recordingRetention: RecordingRetentionStore,
        recordingsFolderOpener: any RecordingsFolderOpening,
        keychain: any SecretStoring,
        codexCredentials: any CodexCredentialsStoring & CodexAccessTokenProviding = UnavailableCodexCredentialsStore(),
        codexAuthenticator: any CodexAuthenticating = UnavailableCodexAuthenticator(),
        modelCatalog: any RemoteModelDiscovering = UnavailableModelCatalog(),
        audioCaptureTrimmingResources: any AudioCaptureTrimmingResourceManaging = UnavailableAudioCaptureTrimmingResourceManager(),
        providerAlerts: any ProviderAlertPresenting = makeNoOpProviderAlertPresenter(),
        hotkeys: any HotkeyHandling,
        launchAtLogin: any LaunchAtLoginControlling,
        feedback: any FeedbackPlaying,
        listeningIndicator: any ListeningIndicatorPresenting,
        permissions: any PermissionProviding,
        audioInputDevices: any AudioInputDeviceDiscovering = UnavailableAudioInputDeviceCatalog(),
        updater: any ApplicationUpdating = UnavailableApplicationUpdater(),
        cleanupLibraryCloudSync: CleanupLibraryCloudSync,
        dictationDictionaryCloudSync: DictationDictionaryCloudSync,
        logStore: AppLogStore,
        now: @escaping () -> Date
    ) {
        self.coordinator = coordinator; self.connectionTest = connectionTest; self.textDelivery = textDelivery; self.cleanupPromptExportReader = cleanupPromptExportReader
        self.preferencesStore = preferencesStore; self.recordingRetention = recordingRetention; self.recordingsFolderOpener = recordingsFolderOpener; self.keychain = keychain; self.codexCredentials = codexCredentials; self.codexAuthenticator = codexAuthenticator; self.modelCatalog = modelCatalog; self.audioCaptureTrimmingResources = audioCaptureTrimmingResources; self.providerAlerts = providerAlerts
        self.hotkeys = hotkeys; self.launchAtLogin = launchAtLogin; self.feedback = feedback
        self.listeningIndicator = listeningIndicator; self.permissions = permissions; self.audioInputDevices = audioInputDevices; self.updater = updater; self.cleanupLibraryCloudSync = cleanupLibraryCloudSync; self.dictationDictionaryCloudSync = dictationDictionaryCloudSync; self.logStore = logStore
        self.now = now
    }
}

@MainActor
private final class UnavailableAudioInputDeviceCatalog: AudioInputDeviceDiscovering {
    var onInputDevicesChanged: (() -> Void)?

    func snapshot() -> AudioInputDeviceSnapshot {
        AudioInputDeviceSnapshot(devices: [], defaultDeviceUID: nil)
    }
}

@MainActor
private final class UnavailableApplicationUpdater: ApplicationUpdating {
    func start(channel: UpdateChannel) {}
    func setChannel(_ channel: UpdateChannel) {}
    func checkForUpdates() {}
}

private actor UnavailableCodexCredentialsStore: CodexCredentialsStoring, CodexAccessTokenProviding {
    func readCodexCredentials() async throws -> CodexCredentials? { nil }
    func saveCodexCredentials(_ credentials: CodexCredentials?) async throws { throw UnavailableError() }
    func validCredentials() async throws -> CodexCredentials { throw UnavailableError() }
    private struct UnavailableError: Error {}
}

@MainActor
private final class UnavailableCodexAuthenticator: CodexAuthenticating {
    func connect() async throws -> CodexCredentials { throw UnavailableError() }
    private struct UnavailableError: Error {}
}

private struct UnavailableModelCatalog: RemoteModelDiscovering {
    func discoverModels(configuration: ProviderConfiguration, apiKey: String) async throws -> [String] { throw UnavailableError() }
    private struct UnavailableError: Error {}
}
