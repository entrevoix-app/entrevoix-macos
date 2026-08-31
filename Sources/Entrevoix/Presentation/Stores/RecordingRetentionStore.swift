import Observation

@MainActor
@Observable
final class RecordingRetentionStore {
    private let preferencesStore: any RecordingRetentionPreferencesStoring
    private(set) var deleteAudioAfterTranscription: Bool

    init(preferencesStore: any RecordingRetentionPreferencesStoring) {
        self.preferencesStore = preferencesStore
        deleteAudioAfterTranscription = preferencesStore.loadDeleteAudioAfterTranscription()
    }

    func setDeleteAudioAfterTranscription(_ enabled: Bool) {
        guard deleteAudioAfterTranscription != enabled else { return }
        deleteAudioAfterTranscription = enabled
        preferencesStore.saveDeleteAudioAfterTranscription(enabled)
    }
}
