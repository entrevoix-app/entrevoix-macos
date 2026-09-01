public enum OutputMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case clipboard
    case paste
    public var id: Self { self }
}

public enum TextDeliveryResult: Equatable, Sendable {
    case copied
    case inserted
    case fallbackCopied(reason: String)
    case secureFieldCopied
}
