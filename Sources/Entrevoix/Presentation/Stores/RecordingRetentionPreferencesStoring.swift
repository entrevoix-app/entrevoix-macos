protocol RecordingRetentionPreferencesStoring: AnyObject {
    func loadDeleteAudioAfterTranscription() -> Bool
    func saveDeleteAudioAfterTranscription(_ enabled: Bool)
}
