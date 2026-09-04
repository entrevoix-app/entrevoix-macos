import Foundation
import EntrevoixCore

public final class UserDefaultsPreferencesStore: PreferencesStoring {
    private let defaults: UserDefaults
    private let key = "entrevoix.preferences"
    private let recoveryURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public private(set) var didLoadFreshPreferences = false

    public init(
        defaults: UserDefaults = .standard,
        recoveryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.recoveryURL = recoveryURL ?? applicationSupportURL
            .appendingPathComponent("Entrevoix", isDirectory: true)
            .appendingPathComponent("preferences-recovery.json")
    }

    public func load() -> PreferencesLoadResult {
        didLoadFreshPreferences = false
        guard let data = defaults.data(forKey: key) else {
            didLoadFreshPreferences = true
            return .loaded(AppPreferences())
        }

        guard let value = try? decoder.decode(AppPreferences.self, from: data) else {
            saveRecoveryCopy(data)
            let recovered = AppPreferences()
            save(recovered)
            return .recovered(recovered)
        }

        guard value.schemaVersion <= AppPreferences.currentSchemaVersion else {
            return .incompatible(schemaVersion: value.schemaVersion)
        }
        return .loaded(value)
    }

    public func save(_ preferences: AppPreferences) {
        var value = preferences
        value.schemaVersion = AppPreferences.currentSchemaVersion
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    public func reset() {
        defaults.removeObject(forKey: key)
    }

    private func saveRecoveryCopy(_ data: Data) {
        do {
            try fileManager.createDirectory(
                at: recoveryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: recoveryURL, options: .atomic)
        } catch {
            // Recovery is best effort; the invalid value is still replaced with defaults.
        }
    }
}
