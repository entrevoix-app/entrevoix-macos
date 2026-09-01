import Foundation

public enum PreferencesLoadResult: Equatable, Sendable {
    case loaded(AppPreferences)
    case recovered(AppPreferences)
    case incompatible(schemaVersion: Int)
}

public protocol PreferencesStoring: AnyObject {
    func load() -> PreferencesLoadResult
    func save(_ preferences: AppPreferences)
    func reset()
}
