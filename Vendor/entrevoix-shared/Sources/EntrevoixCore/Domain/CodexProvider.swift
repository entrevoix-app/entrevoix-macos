import Foundation

/// The intentionally small model set exposed by the ChatGPT Codex provider.
/// Availability is verified by the service at request time because the backend
/// does not expose a stable public model catalogue.
public enum CodexModel: String, CaseIterable, Codable, Equatable, Hashable, Sendable, Identifiable {
    case gpt56Luna = "gpt-5.6-luna"
    case gpt56Terra = "gpt-5.6-terra"
    case gpt56Sol = "gpt-5.6-sol"
    case gpt55 = "gpt-5.5"
    case gpt54 = "gpt-5.4"
    case gpt54Mini = "gpt-5.4-mini"
    case gpt53CodexSpark = "gpt-5.3-codex-spark"

    public var id: String { rawValue }
}

public struct CodexProviderProfile: Codable, Equatable, Sendable {
    public var model: CodexModel

    public init(model: CodexModel = .gpt56Luna) {
        self.model = model
    }
}
