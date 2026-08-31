import Foundation

final class UserDefaultsRecordingRetentionPreferencesStore: RecordingRetentionPreferencesStoring {
    static let key = "entrevoix.recordings.deleteAfterTranscription"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadDeleteAudioAfterTranscription() -> Bool {
        defaults.object(forKey: Self.key) as? Bool ?? true
    }

    func saveDeleteAudioAfterTranscription(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.key)
    }
}
