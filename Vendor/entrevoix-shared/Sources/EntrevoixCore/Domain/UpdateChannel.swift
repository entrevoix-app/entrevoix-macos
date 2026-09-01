import Foundation

public enum UpdateChannel: String, CaseIterable, Codable, Equatable, Hashable, Sendable, Identifiable {
    case stable
    case releaseCandidate = "rc"
    case development = "dev"

    public var id: Self { self }

    /// The channel name used in Sparkle appcast items. The stable channel is
    /// represented by the absence of a channel element.
    public var sparkleChannelName: String? {
        switch self {
        case .stable: nil
        case .releaseCandidate: "rc"
        case .development: "dev"
        }
    }

    /// Higher values represent less conservative update choices.
    public var riskLevel: Int {
        switch self {
        case .stable: 0
        case .releaseCandidate: 1
        case .development: 2
        }
    }

    public func requiresConfirmation(beforeChangingFrom current: Self) -> Bool {
        riskLevel > current.riskLevel
    }
}
