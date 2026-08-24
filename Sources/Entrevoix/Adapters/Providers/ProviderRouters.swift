import Foundation
import EntrevoixAppleAdapters
import EntrevoixCore

struct ProviderSpeechRouter: SpeechTranscribing {
    let remote: any SpeechTranscribing
    let apple: AppleSpeechTranscriptionService

    func preflight(request: TranscriptionRequest) async throws {
        switch request.target {
        case .remote: return
        case .apple: try await apple.preflight(request: request)
        }
    }

    func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> String {
        switch request.target {
        case .remote: try await remote.transcribe(audioURL: audioURL, request: request)
        case .apple: try await apple.transcribe(audioURL: audioURL, request: request)
        }
    }

    func transcribe(audioURL: URL, configuration: ProviderConfiguration, apiKey: String, prompt: String?, language: String?) async throws -> String {
        try await remote.transcribe(audioURL: audioURL, configuration: configuration, apiKey: apiKey, prompt: prompt, language: language)
    }
}

struct ProviderCleanupRouter: TextCleaning {
    let remote: any TextCleaning
    let anthropic: any TextCleaning
    let codex: CodexCleanupService
    let apple: AppleFoundationCleanupService

    func preflight(request: CleanupRequest) async throws {
        switch request.target {
        case .remote: return
        case .anthropic: return
        case .codex: return
        case .apple: try await apple.preflight(request: request)
        }
    }

    func clean(text: String, request: CleanupRequest) async throws -> String {
        switch request.target {
        case .remote: try await remote.clean(text: text, request: request)
        case .anthropic: try await anthropic.clean(text: text, request: request)
        case .codex: try await codex.clean(text: text, request: request)
        case .apple: try await apple.clean(text: text, request: request)
        }
    }

    func clean(text: String, configuration: ProviderConfiguration, apiKey: String, format: CleanupAPIFormat, prompt: String) async throws -> String {
        try await remote.clean(text: text, configuration: configuration, apiKey: apiKey, format: format, prompt: prompt)
    }
}
