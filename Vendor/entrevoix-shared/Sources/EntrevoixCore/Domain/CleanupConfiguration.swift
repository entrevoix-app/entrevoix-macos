public enum CleanupAPIFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case responses
    case chatCompletions
    case anthropicMessages
    public var id: Self { self }
}

public enum CleanupFailurePolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case useRawTranscript
    case stop
    public var id: Self { self }
}
