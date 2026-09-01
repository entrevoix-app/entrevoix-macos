import Foundation
import EntrevoixCore

public struct OpenAITextCleanupService: TextCleaning {
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
        guard let endpoint = configuration.endpointURL else { throw CleanupError.invalidEndpoint }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CleanupError.emptyInput }
        let cleanupPolicy = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanupPolicy.isEmpty else { throw CleanupError.emptyPrompt }
        let instructions = CleanupTransformationPolicy.systemInstructions
        let input = CleanupTransformationPolicy.input(instructions: cleanupPolicy, transcript: text)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let language {
            request.setValue(language, forHTTPHeaderField: "X-Text-Language")
        }
        try setAuthentication(on: &request, configuration: configuration, apiKey: apiKey)

        switch format {
        case .responses:
            request.httpBody = try JSONEncoder().encode(ResponsesRequest(
                model: configuration.model,
                instructions: instructions,
                input: input,
                store: false
            ))
        case .chatCompletions:
            request.httpBody = try JSONEncoder().encode(ChatCompletionsRequest(
                model: configuration.model,
                messages: [
                    ChatMessage(role: "system", content: instructions),
                    ChatMessage(role: "user", content: input)
                ],
                store: false
            ))
        case .anthropicMessages:
            throw CleanupError.invalidResponse
        }

        let (data, response) = try await transport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw CleanupError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CleanupError.http(statusCode: httpResponse.statusCode, message: errorMessage(from: data))
        }

        let result: String?
        switch format {
        case .responses:
            result = try? decodeResponsesText(from: data)
        case .chatCompletions:
            result = try? decodeChatCompletionsText(from: data)
        case .anthropicMessages:
            result = nil
        }
        guard let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CleanupError.emptyResult
        }
        let cleanedResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if CleanupTransformationPolicy.shouldUseRawTranscript(
            result: cleanedResult,
            transcript: text,
            cleanupPolicy: cleanupPolicy,
            systemInstructions: instructions,
            input: input
        ) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleanedResult
    }

    private func setAuthentication(on request: inout URLRequest, configuration: ProviderConfiguration, apiKey: String) throws {
        switch configuration.authentication {
        case .bearer:
            guard !apiKey.isEmpty else { throw CleanupError.missingAPIKey }
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .apiKey:
            guard !apiKey.isEmpty else { throw CleanupError.missingAPIKey }
            let header = configuration.customHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !header.isEmpty else { throw CleanupError.invalidHeader }
            request.setValue(apiKey, forHTTPHeaderField: header)
        case .none:
            break
        }
    }

    private func decodeResponsesText(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(ResponsesResponse.self, from: data)
        if let outputText = response.outputText, !outputText.isEmpty { return outputText }
        let text = response.output
            .flatMap { $0.content ?? [] }
            .compactMap(\.text)
            .joined()
        guard !text.isEmpty else { throw CleanupError.emptyResult }
        return text
    }

    private func decodeChatCompletionsText(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        let text = response.choices
            .compactMap { $0.message.content?.text }
            .joined()
        guard !text.isEmpty else { throw CleanupError.emptyResult }
        return text
    }

    private func errorMessage(from data: Data) -> String? {
        guard let error = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) else { return nil }
        return error.error.message
    }
}

private struct ResponsesRequest: Encodable {
    let model: String
    let instructions: String
    let input: String
    let store: Bool
}

private struct ResponsesResponse: Decodable {
    let outputText: String?
    let output: [ResponsesOutputItem]

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outputText = try container.decodeIfPresent(String.self, forKey: .outputText)
        output = try container.decodeIfPresent([ResponsesOutputItem].self, forKey: .output) ?? []
    }
}

private struct ResponsesOutputItem: Decodable {
    let content: [ResponsesContentPart]?
}

private struct ResponsesContentPart: Decodable {
    let text: String?
}

private struct ChatCompletionsRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let store: Bool
}

private struct ChatMessage: Encodable {
    let role: String
    let content: String
}

private struct ChatCompletionsResponse: Decodable {
    let choices: [ChatChoice]
}

private struct ChatChoice: Decodable {
    let message: ChatMessageResponse
}

private struct ChatMessageResponse: Decodable {
    let content: FlexibleText?
}

private enum FlexibleText: Decodable {
    case text(String)
    case parts([TextPart])

    var text: String {
        switch self {
        case .text(let value): value
        case .parts(let values): values.compactMap(\.text).joined()
        }
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            self = .text(value)
        } else {
            self = .parts(try decoder.singleValueContainer().decode([TextPart].self))
        }
    }
}

private struct TextPart: Decodable {
    let text: String?
}

private struct APIErrorEnvelope: Decodable { let error: APIError }
private struct APIError: Decodable { let message: String }

enum CleanupError: LocalizedError, LogSafeError, UserFacingErrorProviding {
    case invalidEndpoint
    case missingAPIKey
    case invalidHeader
    case emptyInput
    case emptyPrompt
    case invalidResponse
    case emptyResult
    case http(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The TTT endpoint is invalid."
        case .missingAPIKey: "The TTT API key is missing."
        case .invalidHeader: "The TTT header name is invalid."
        case .emptyInput: "The transcript to clean up is empty."
        case .emptyPrompt: "The TTT prompt is empty."
        case .invalidResponse: "The TTT response is invalid."
        case .emptyResult: "TTT cleanup returned empty text."
        case .http(let statusCode, let message):
            if let message { "TTT error (HTTP \(statusCode)): \(message)" }
            else { "TTT error (HTTP \(statusCode))." }
        }
    }

    var logMessage: String {
        switch self {
        case .http(let statusCode, _): "TTT request failed (HTTP \(statusCode))."
        default: "TTT cleanup failed."
        }
    }

    var userFacingMessage: UserFacingErrorMessage {
        switch self {
        case .invalidEndpoint: .tttInvalidEndpoint
        case .missingAPIKey: .tttMissingAPIKey
        case .invalidHeader: .tttInvalidHeader
        case .emptyInput: .tttEmptyInput
        case .emptyPrompt: .tttEmptyPrompt
        case .invalidResponse: .tttInvalidResponse
        case .emptyResult: .tttEmptyResult
        case .http(let statusCode, let message): .tttHTTP(statusCode: statusCode, providerMessage: message)
        }
    }
}
