import Foundation
import EntrevoixCore
import Observation

@MainActor
@Observable
final class DictationStore {
    let coordinator: DictationCoordinator
    private(set) var snapshot: DictationSnapshot
    @ObservationIgnored var canStart: () -> Bool = { true }

    private let providerStore: ProviderStore
    private let permissionsStore: PermissionsStore
    private let promptLibrary: PromptLibraryStore
    private let hotkeys: any HotkeyHandling
    private let textDelivery: any TextDelivering
    private let soundFeedback: any FeedbackPlaying
    private let listeningIndicator: any ListeningIndicatorPresenting
    private let providerAlerts: any ProviderAlertPresenting
    private let logStore: AppLogStore
    private let now: () -> Date
    private var globalShortcutIsDown = false
    private var lastShortcutEventAt: Date?

    init(
        coordinator: DictationCoordinator,
        providerStore: ProviderStore,
        permissionsStore: PermissionsStore,
        promptLibrary: PromptLibraryStore,
        hotkeys: any HotkeyHandling,
        textDelivery: any TextDelivering,
        soundFeedback: any FeedbackPlaying,
        listeningIndicator: any ListeningIndicatorPresenting,
        providerAlerts: any ProviderAlertPresenting,
        logStore: AppLogStore,
        now: @escaping () -> Date
    ) {
        self.coordinator = coordinator
        self.providerStore = providerStore
        self.permissionsStore = permissionsStore
        self.promptLibrary = promptLibrary
        self.hotkeys = hotkeys
        self.textDelivery = textDelivery
        self.soundFeedback = soundFeedback
        self.listeningIndicator = listeningIndicator
        self.providerAlerts = providerAlerts
        self.logStore = logStore
        self.now = now
        snapshot = coordinator.snapshot
        coordinator.onSnapshot = { [weak self] snapshot in
            self?.snapshot = snapshot
        }
        coordinator.onEvent = { [weak self] event in
            self?.handle(event)
        }
        hotkeys.onKeyDown = { [weak self] in self?.handleKeyDown() }
        hotkeys.onKeyUp = { [weak self] in self?.handleKeyUp() }
        hotkeys.onEscape = { [weak self] in self?.handleEscape() }
    }

    var state: DictationState { snapshot.state }
    var lastAudioURL: URL? { snapshot.lastAudioURL }
    var lastTranscript: String? { snapshot.lastTranscript }
    var mode: TriggerMode { providerStore.preferences.triggerMode }

    func setMode(_ newMode: TriggerMode) {
        guard state == .idle else { return }
        providerStore.preferences.triggerMode = newMode
        providerStore.preferencesStore.savePreferencesImmediately()
    }

    func handleKeyDown() {
        guard !globalShortcutIsDown else { return }
        let eventDate = now()
        if let lastShortcutEventAt,
           eventDate.timeIntervalSince(lastShortcutEventAt) < DictationTiming.shortcutDebounce {
            return
        }
        lastShortcutEventAt = eventDate
        globalShortcutIsDown = true

        switch mode {
        case .pushToTalk:
            startRecording()
        case .toggle:
            if state == .recording {
                stopRecording()
            } else if state == .idle || isErrorState {
                startRecording()
            }
        }
    }

    func handleKeyUp() {
        globalShortcutIsDown = false
        guard mode == .pushToTalk else { return }
        switch state {
        case .recording:
            stopRecording()
        case .requestingPermission:
            cancelRecording()
        default:
            break
        }
    }

    func handleEscape() {
        switch state {
        case .requestingPermission, .recording, .transcribing:
            cancelRecording()
        default:
            break
        }
    }

    func startRecording() {
        guard canStart() else { return }
        guard automaticInsertionIsAvailable() else { return }
        if isErrorState { coordinator.dismissError() }
        guard let request = makeRequest() else {
            logStore.log("Error: no usable STT provider is selected.")
            return
        }
        coordinator.startRecording(
            request: request,
            audioInput: providerStore.preferences.audioInputSelection,
            trimLeadingAndTrailingSilence: providerStore.preferences.trimLeadingAndTrailingSilence,
            reduceLongInternalPauses: providerStore.preferences.reduceLongInternalPauses
        )
    }

    func stopRecording() {
        guard state == .recording, let request = makeRequest() else { return }
        coordinator.stopRecording(request: request)
    }

    func cancelRecording() {
        let shouldPlayCancellation = switch state {
        case .requestingPermission, .recording, .transcribing: true
        case .idle, .error: false
        }
        coordinator.cancelRecording()
        if shouldPlayCancellation { playFeedback(.recordingCancelled) }
    }

    func deleteLastCapture() {
        coordinator.deleteLastCapture()
    }

    func copyTranscript() {
        guard let lastTranscript else { return }
        textDelivery.copy(lastTranscript)
    }

    func deliverTranscript() {
        guard let lastTranscript else { return }
        if providerStore.preferences.outputMode == .paste {
            guard automaticInsertionIsAvailable() else { return }
            textDelivery.copyAndPaste(lastTranscript)
        } else {
            textDelivery.copy(lastTranscript)
        }
    }

    private var isErrorState: Bool {
        if case .error = state { return true }
        return false
    }

    private func automaticInsertionIsAvailable() -> Bool {
        guard providerStore.preferences.outputMode == .paste,
              permissionsStore.accessibilityPermission != .granted
        else {
            return true
        }
        permissionsStore.requestAccessibilityPermission()
        logStore.log("Automatic insertion requires Accessibility permission.")
        playFeedback(.error)
        return false
    }

    private func makeRequest() -> DictationRequest? {
        providerStore.makeDictationRequest(
            activeCleanupSelection: promptLibrary.activeSelection,
            cleanupPrompts: providerStore.preferences.cleanupPrompts,
            cleanupWorkflows: providerStore.preferences.cleanupWorkflows
        )
    }

    private func handle(_ event: DictationEvent) {
        switch event {
        case .recordingTimedOut:
            stopRecording()
        case .recordingStarted:
            listeningIndicator.show(label: EntrevoixLocalization.text(
                "dictation.listening",
                defaultValue: "Listening…",
                locale: providerStore.interfaceLocale
            ), phase: .listening)
            playFeedback(.recordingStarted)
        case .recordingStopped:
            playFeedback(.recordingStopped)
            listeningIndicator.update(label: EntrevoixLocalization.text(
                "dictation.transcribing",
                defaultValue: "Transcribing…",
                locale: providerStore.interfaceLocale
            ), phase: .processing)
        case .cleanupStarted:
            listeningIndicator.update(label: EntrevoixLocalization.text(
                "dictation.improving",
                defaultValue: "Improving text…",
                locale: providerStore.interfaceLocale
            ), phase: .processing)
        case .cleanupStepStarted(let current, let total):
            let format = EntrevoixLocalization.text(
                "dictation.improving_progress",
                defaultValue: "Improving text… %lld/%lld",
                locale: providerStore.interfaceLocale
            )
            listeningIndicator.update(label: String(
                format: format,
                locale: providerStore.interfaceLocale,
                arguments: [current, total]
            ), phase: .processing)
        case .providerUnavailable(let capability, let reason):
            logStore.log("Apple \(capability.rawValue) unavailable (\(reason.rawValue)).")
            providerAlerts.presentUnavailable(capability: capability, reason: reason)
        case .sessionEnded:
            listeningIndicator.hide()
        }
    }

    private func playFeedback(_ event: FeedbackEvent) {
        guard providerStore.preferences.playFeedbackSounds else { return }
        soundFeedback.play(event)
    }

}
