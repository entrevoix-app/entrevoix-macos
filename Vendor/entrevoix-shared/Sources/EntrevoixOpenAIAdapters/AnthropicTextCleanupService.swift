import Foundation
import EntrevoixCore

/// Text cleanup adapter for Anthropic's Messages API.
public struct AnthropicTextCleanupService: TextCleaning {
    private let transport: any HTTPTransporting

    public init(transport: any HTTPTransporting = SafeNetworkSession()) {
        self.transport = transport
    }

    public func clean(
        text: String,
        configuration: ProviderConfiguration,
        apiKey: String,
        format: CleanupAPIFormat,
        prompt: String
    ) async throws -> String {
        try await clean(
            text: text,
            configuration: configuration,
            apiKey: apiKey,
            format: format,
            prompt: prompt,
            language: nil
        )
    }

    public func clean(text: String, request: CleanupRequest) async throws -> String {
        try await clean(
            text: text,
            configuration: request.configuration,
            apiKey: request.apiKey,
            format: request.format,
            prompt: request.prompt,
            language: request.language
        )
    }

    private func clean(
        text: String,
        configuration: ProviderConfiguration,
        apiKey: String,
        format: CleanupAPIFormat,
        prompt: String,
        language: String?
    ) async throws -> String {
        guard format == .anthropicMessages else { throw AnthropicCleanupError.invalidFormat }
        guard let endpoint = configuration.endpointURL else { throw AnthropicCleanupError.invalidEndpoint }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AnthropicCleanupError.emptyInput }
        let cleanupPolicy = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanupPolicy.isEmpty else { throw AnthropicCleanupError.emptyPrompt }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AnthropicCleanupError.missingAPIKey }

        let instructions = CleanupTransformationPolicy.systemInstructions(language: language)
        let input = CleanupTransformationPolicy.input(instructions: cleanupPolicy, transcript: text)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let language {
            request.setValue(language, forHTTPHeaderField: "X-Text-Language")
        }
        request.httpBody = try JSONEncoder().encode(MessagesRequest(
            model: configuration.model,
            maxTokens: 4_096,
            system: instructions,
            messages: [Message(role: "user", content: input)]
        ))

        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw AnthropicCleanupError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AnthropicCleanupError.http(statusCode: httpResponse.statusCode, message: errorMessage(from: data))
        }

        let result = try JSONDecoder().decode(MessagesResponse.self, from: data).content
            .compactMap { $0.type == "text" ? $0.text : nil }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw AnthropicCleanupError.emptyResult }
        if CleanupTransformationPolicy.shouldUseRawTranscript(
            result: result,
            transcript: text,
            cleanupPolicy: cleanupPolicy,
            systemInstructions: instructions,
            input: input
        ) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private func errorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
    }
}

private struct MessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

private struct Message: Encodable {
    let role: String
    let content: String
}

private struct MessagesResponse: Decodable {
    let content: [ContentBlock]
}

private struct ContentBlock: Decodable {
    let type: String
    let text: String?
}

private struct ErrorEnvelope: Decodable {
    let error: ErrorBody
}

private struct ErrorBody: Decodable {
    let message: String?
}

enum AnthropicCleanupError: LocalizedError, LogSafeError, UserFacingErrorProviding {
    case invalidFormat, invalidEndpoint, missingAPIKey, emptyInput, emptyPrompt, invalidResponse, emptyResult
    case http(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidFormat: "The selected cleanup format is not Anthropic Messages."
        case .invalidEndpoint: "The Anthropic endpoint is invalid."
        case .missingAPIKey: "The Anthropic API key is missing."
        case .emptyInput: "The transcript to clean up is empty."
        case .emptyPrompt: "The TTT prompt is empty."
        case .invalidResponse: "The Anthropic response is invalid."
        case .emptyResult: "Anthropic cleanup returned empty text."
        case .http(let statusCode, let message): message.map { "Anthropic error (HTTP \(statusCode)): \($0)" } ?? "Anthropic error (HTTP \(statusCode))."
        }
    }

    var logMessage: String {
        switch self {
        case .http(let statusCode, _): "Anthropic cleanup request failed (HTTP \(statusCode))."
        default: "Anthropic cleanup failed."
        }
    }

    var userFacingMessage: UserFacingErrorMessage {
        switch self {
        case .invalidFormat, .invalidEndpoint: .tttInvalidEndpoint
        case .missingAPIKey: .tttMissingAPIKey
        case .emptyInput: .tttEmptyInput
        case .emptyPrompt: .tttEmptyPrompt
        case .invalidResponse: .tttInvalidResponse
        case .emptyResult: .tttEmptyResult
        case .http(let statusCode, let message): .tttHTTP(statusCode: statusCode, providerMessage: message)
        }
    }
}
