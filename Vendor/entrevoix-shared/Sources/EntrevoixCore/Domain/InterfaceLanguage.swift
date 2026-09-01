import Foundation

public enum InterfaceLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic
    case english
    case french

    public var id: Self { self }
}

public enum CleanupPromptMode: String, Codable, Sendable {
    case localizedDefault
    case custom
    case legacyDefaultPendingChoice
}
