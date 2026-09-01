import Foundation

public enum TranscriptionLanguage: String, CaseIterable, Codable, Identifiable, Sendable, Hashable {
    case automatic
    case arabic = "ar"
    case chinese = "zh"
    case dutch = "nl"
    case english = "en"
    case french = "fr"
    case german = "de"
    case hindi = "hi"
    case indonesian = "id"
    case italian = "it"
    case japanese = "ja"
    case korean = "ko"
    case polish = "pl"
    case portuguese = "pt"
    case russian = "ru"
    case spanish = "es"
    case turkish = "tr"
    case ukrainian = "uk"
    case vietnamese = "vi"

    public var id: Self { self }

    public var apiCode: String? {
        self == .automatic ? nil : rawValue
    }

    public static var selectableCases: [Self] {
        allCases.filter { $0 != .automatic }
    }

    public init(legacyCode: String) {
        let normalized = legacyCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let baseCode = normalized.split(separator: "-").first.map(String.init) ?? normalized

        if normalized == Self.automatic.rawValue || normalized.isEmpty {
            self = .automatic
        } else {
            self = Self(rawValue: baseCode) ?? .automatic
        }
    }
}
