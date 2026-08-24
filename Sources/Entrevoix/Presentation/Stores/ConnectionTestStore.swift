import Foundation
import EntrevoixCore
import Observation

@MainActor
@Observable
final class ConnectionTestStore {
    let coordinator: ConnectionTestCoordinator
    private(set) var snapshot: ConnectionTestSnapshot
    @ObservationIgnored var canStart: () -> Bool = { true }

    private let providerStore: ProviderStore
    private let permissionsStore: PermissionsStore
    private let feedback: any FeedbackPlaying
    private let textDelivery: any TextDelivering

    init(
        coordinator: ConnectionTestCoordinator,
        providerStore: ProviderStore,
        permissionsStore: PermissionsStore,
        feedback: any FeedbackPlaying,
        textDelivery: any TextDelivering
    ) {
        self.coordinator = coordinator
        self.providerStore = providerStore
        self.permissionsStore = permissionsStore
        self.feedback = feedback
        self.textDelivery = textDelivery
        snapshot = coordinator.snapshot
        coordinator.onSnapshot = { [weak self] snapshot in
            self?.snapshot = snapshot
        }
        coordinator.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    var state: ConnectionTestState { snapshot.state }
    var interfaceLocale: Locale { providerStore.interfaceLocale }

    func start() {
        guard canStart(), state.isInactive,
              let request = providerStore.makeTranscriptionRequest() else { return }
        coordinator.start(
            request: request,
            audioInput: providerStore.preferences.audioInputSelection,
            trimLeadingAndTrailingSilence: providerStore.preferences.trimLeadingAndTrailingSilence,
            reduceLongInternalPauses: providerStore.preferences.reduceLongInternalPauses
        )
    }

    func finish() {
        guard let request = providerStore.makeTranscriptionRequest() else { return }
        coordinator.finish(request: request)
    }

    func cancel() {
        let shouldPlayCancellation = !state.isInactive
        coordinator.cancel()
        if shouldPlayCancellation { playFeedback(.recordingCancelled) }
    }

    func copyTestText() {
        textDelivery.copy(EntrevoixLocalization.text(
            "test.clipboard",
            defaultValue: "Entrevoix — clipboard test",
            locale: interfaceLocale
        ))
    }

    func pasteTestText() {
        textDelivery.copyAndPaste(EntrevoixLocalization.text(
            "test.insertion",
            defaultValue: "Entrevoix — insertion test",
            locale: interfaceLocale
        ))
    }

    private func handle(_ event: ConnectionTestEvent) {
        switch event {
        case .recordingStarted:
            permissionsStore.refresh()
            playFeedback(.recordingStarted)
        case .recordingStopped:
            playFeedback(.recordingStopped)
        case .succeeded:
            playFeedback(.connectionTestSucceeded)
        case .failed:
            permissionsStore.refresh()
            playFeedback(.error)
        }
    }

    private func playFeedback(_ event: FeedbackEvent) {
        guard providerStore.preferences.playFeedbackSounds else { return }
        feedback.play(event)
    }
}
