import Foundation
import EntrevoixCore
import EntrevoixOpenAIAdapters

struct CodexCleanupService: TextCleaning {
    private let transport: any HTTPTransporting
    private let credentialsProvider: (any CodexAccessTokenProviding)?

    init(
        transport: any HTTPTransporting,
        credentialsProvider: (any CodexAccessTokenProviding)? = nil
    ) {
        self.transport = transport
        self.credentialsProvider = credentialsProvider
    }

    func clean(text: String, request: CleanupRequest) async throws -> String {
        guard case .codex = request.target else { throw CodexCleanupError.invalidRequest }
        guard let credentialsProvider else { throw CodexCleanupError.notConnected }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CodexCleanupError.emptyInput }
        let policy = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !policy.isEmpty else { throw CodexCleanupError.emptyPrompt }
        let instructions = CleanupTransformationPolicy.systemInstructions
        let input = CleanupTransformationPolicy.input(instructions: policy, transcript: text)

        let credentials = try await credentialsProvider.validCredentials()
        var urlRequest = URLRequest(url: CodexProtocol.responsesEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.configuration.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("opencode", forHTTPHeaderField: "originator")
        urlRequest.setValue("Entrevoix", forHTTPHeaderField: "User-Agent")
        if let language = request.language {
            urlRequest.setValue(language, forHTTPHeaderField: "X-Text-Language")
        }
        if let accountID = credentials.accountID, !accountID.isEmpty {
            urlRequest.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        if let residency = credentials.computeResidency, !residency.isEmpty {
            urlRequest.setValue(residency, forHTTPHeaderField: "x-openai-internal-codex-residency")
        }
        urlRequest.httpBody = try JSONEncoder().encode(CodexResponsesRequest(
            model: request.configuration.model,
            instructions: instructions,
            input: input,
            store: false
        ))

        let (data, response) = try await transport.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw CodexCleanupError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw CodexCleanupError.http(http.statusCode, message: errorMessage(from: data)) }
        let result = try decodeText(from: data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw CodexCleanupError.emptyResult }
        if CleanupTransformationPolicy.shouldUseRawTranscript(
            result: result,
            transcript: text,
            cleanupPolicy: policy,
            systemInstructions: instructions,
            input: input
        ) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    func clean(text: String, configuration: ProviderConfiguration, apiKey: String, format: CleanupAPIFormat, prompt: String) async throws -> String {
        throw CodexCleanupError.invalidRequest
    }

    private func decodeText(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(CodexResponsesResponse.self, from: data)
        if let outputText = response.outputText, !outputText.isEmpty { return outputText }
        let result = response.output.flatMap { $0.content ?? [] }.compactMap(\.text).joined()
        guard !result.isEmpty else { throw CodexCleanupError.emptyResult }
        return result
    }

    private func errorMessage(from data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(CodexErrorEnvelope.self, from: data) else { return nil }
        return envelope.error.message
    }
}

private struct CodexResponsesRequest: Encodable {
    let model: String
    let instructions: String
    let input: String
    let store: Bool
}

private struct CodexResponsesResponse: Decodable {
    let outputText: String?
    let output: [CodexOutputItem]
    enum CodingKeys: String, CodingKey { case outputText = "output_text", output }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outputText = try container.decodeIfPresent(String.self, forKey: .outputText)
        output = try container.decodeIfPresent([CodexOutputItem].self, forKey: .output) ?? []
    }
}

private struct CodexOutputItem: Decodable { let content: [CodexContentPart]? }
private struct CodexContentPart: Decodable { let text: String? }
private struct CodexErrorEnvelope: Decodable { let error: CodexError }
private struct CodexError: Decodable { let message: String }

enum CodexCleanupError: Error, LogSafeError, UserFacingErrorProviding {
    case notConnected, invalidRequest, emptyInput, emptyPrompt, invalidResponse, emptyResult
    case http(Int, message: String?)

    var logMessage: String {
        switch self {
        case .notConnected: "Codex cleanup requested without ChatGPT credentials."
        case .http(let status, _): "Codex cleanup failed (HTTP \(status))."
        default: "Codex cleanup failed."
        }
    }

    var userFacingMessage: UserFacingErrorMessage {
        switch self {
        case .notConnected: .codexNotConnected
        case .http(let status, let message): .tttHTTP(statusCode: status, providerMessage: message)
        case .emptyInput: .tttEmptyInput
        case .emptyPrompt: .tttEmptyPrompt
        case .invalidResponse: .tttInvalidResponse
        case .emptyResult: .tttEmptyResult
        case .invalidRequest: .codexInvalidRequest
        }
    }
}
