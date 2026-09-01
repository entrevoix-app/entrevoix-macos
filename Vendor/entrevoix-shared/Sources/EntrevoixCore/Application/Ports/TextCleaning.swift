public protocol TextCleaning: Sendable {
    func clean(text: String, configuration: ProviderConfiguration, apiKey: String, format: CleanupAPIFormat, prompt: String) async throws -> String
    func clean(text: String, request: CleanupRequest) async throws -> String
}

public extension TextCleaning {
    func preflight(request: CleanupRequest) async throws {}

    func clean(text: String, request: CleanupRequest) async throws -> String {
        try await clean(text: text, configuration: request.configuration, apiKey: request.apiKey, format: request.format, prompt: request.prompt)
    }
}
