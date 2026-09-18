import Foundation
import FoundationModels
import EntrevoixCore

public struct AppleFoundationCleanupService: TextCleaning {
    public init() {}

    static func instructions(for request: CleanupRequest) -> String {
        guard case let .apple(localeIdentifier) = request.target else {
            return CleanupTransformationPolicy.systemInstructions
        }
        return CleanupTransformationPolicy.systemInstructions(language: localeIdentifier)
    }

    public func preflight(request: CleanupRequest) async throws {
        guard case .apple(let localeIdentifier) = request.target else { return }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: break
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: throw AppleProviderError(capability: .ttt, reason: .unsupportedDevice)
            case .appleIntelligenceNotEnabled: throw AppleProviderError(capability: .ttt, reason: .appleIntelligenceDisabled)
            case .modelNotReady: throw AppleProviderError(capability: .ttt, reason: .modelNotReady)
            @unknown default: throw AppleProviderError(capability: .ttt, reason: .modelNotReady)
            }
        }
        if let localeIdentifier, !model.supportsLocale(Locale(identifier: localeIdentifier)) { throw AppleProviderError(capability: .ttt, reason: .unsupportedLocale) }
    }

    public func clean(text: String, request: CleanupRequest) async throws -> String {
        try await preflight(request: request)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppleProviderError(capability: .ttt, reason: .missingConfiguration) }
        let instructions = Self.instructions(for: request)
        let input = CleanupTransformationPolicy.input(instructions: request.prompt, transcript: text)
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(to: input, options: GenerationOptions(sampling: .greedy))
        let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw AppleProviderError(capability: .ttt, reason: .missingConfiguration) }
        return CleanupTransformationPolicy.shouldUseRawTranscript(
            result: result,
            transcript: text,
            cleanupPolicy: request.prompt,
            systemInstructions: instructions,
            input: input
        ) ? text.trimmingCharacters(in: .whitespacesAndNewlines) : result
    }

    public func clean(text: String, configuration: ProviderConfiguration, apiKey: String, format: CleanupAPIFormat, prompt: String) async throws -> String {
        try await clean(text: text, request: CleanupRequest(configuration: configuration, apiKey: apiKey, format: format, prompt: prompt, failurePolicy: .useRawTranscript, target: .apple(localeIdentifier: nil)))
    }
}
