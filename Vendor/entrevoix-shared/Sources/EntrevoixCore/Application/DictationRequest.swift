import Foundation

public enum TranscriptionTarget: Sendable {
    case remote
    case apple(localeIdentifier: String?, dictionaryTerms: [String])
}

public enum CleanupTarget: Sendable {
    case remote
    case anthropic
    case codex
    case apple(localeIdentifier: String?)
}

public struct TranscriptionRequest: Sendable {
    public let configuration: ProviderConfiguration
    public let apiKey: String
    public let prompt: String?
    public let language: String?
    public let target: TranscriptionTarget

    public init(
        configuration: ProviderConfiguration,
        apiKey: String,
        prompt: String?,
        language: String?,
        target: TranscriptionTarget = .remote
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.prompt = prompt
        self.language = language
        self.target = target
    }
}

public struct CleanupRequest: Sendable {
    public let configuration: ProviderConfiguration
    public let apiKey: String
    public let format: CleanupAPIFormat
    public let prompt: String
    public let failurePolicy: CleanupFailurePolicy
    public let target: CleanupTarget
    public let language: String?

    public init(
        configuration: ProviderConfiguration,
        apiKey: String,
        format: CleanupAPIFormat,
        prompt: String,
        failurePolicy: CleanupFailurePolicy,
        target: CleanupTarget = .remote,
        language: String? = nil
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.format = format
        self.prompt = prompt
        self.failurePolicy = failurePolicy
        self.target = target
        self.language = language
    }
}

public struct CleanupStep: Equatable, Sendable {
    public let promptID: UUID
    public let promptName: String
    public let prompt: String

    public init(promptID: UUID, promptName: String, prompt: String) {
        self.promptID = promptID
        self.promptName = promptName
        self.prompt = prompt
    }
}

public enum CleanupPlanKind: Equatable, Sendable {
    case prompt
    case workflow(id: UUID, name: String)
}

/// A frozen cleanup configuration and its ordered prompt steps for one dictation.
public struct CleanupPlan: Sendable {
    public let configuration: ProviderConfiguration
    public let apiKey: String
    public let format: CleanupAPIFormat
    public let failurePolicy: CleanupFailurePolicy
    public let target: CleanupTarget
    public let language: String?
    public let kind: CleanupPlanKind
    public let steps: [CleanupStep]

    public init(
        configuration: ProviderConfiguration,
        apiKey: String,
        format: CleanupAPIFormat,
        failurePolicy: CleanupFailurePolicy,
        target: CleanupTarget = .remote,
        language: String? = nil,
        kind: CleanupPlanKind,
        steps: [CleanupStep]
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.format = format
        self.failurePolicy = failurePolicy
        self.target = target
        self.language = language
        self.kind = kind
        self.steps = steps
    }

    public func request(for step: CleanupStep) -> CleanupRequest {
        CleanupRequest(
            configuration: configuration,
            apiKey: apiKey,
            format: format,
            prompt: step.prompt,
            failurePolicy: failurePolicy,
            target: target,
            language: language
        )
    }
}

public struct DictationRequest: Sendable {
    public let transcription: TranscriptionRequest
    public let cleanup: CleanupPlan?
    public let outputMode: OutputMode

    public init(
        transcription: TranscriptionRequest,
        cleanup: CleanupPlan?,
        outputMode: OutputMode
    ) {
        self.transcription = transcription
        self.cleanup = cleanup
        self.outputMode = outputMode
    }
}
