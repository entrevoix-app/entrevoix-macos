import Foundation

public protocol SpeechTranscribing: Sendable {
    func transcribe(audioURL: URL, configuration: ProviderConfiguration, apiKey: String, prompt: String?, language: String?) async throws -> String
}

public extension SpeechTranscribing {
    func preflight(request: TranscriptionRequest) async throws {}

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> String {
        try await transcribe(audioURL: audioURL, configuration: request.configuration, apiKey: request.apiKey, prompt: request.prompt, language: request.language)
    }
}
