import Foundation

public enum AuthenticationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case bearer
    case apiKey
    case none
    public var id: Self { self }
}

public struct ProviderConfiguration: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var path: String
    public var model: String
    public var authentication: AuthenticationMode
    public var customHeaderName: String
    public var timeout: Double
    /// Relevant only to speech-to-text requests. Text requests ignore it.
    public var audioUploadFormat: AudioUploadFormat

    public init(
        id: UUID = UUID(), name: String, baseURL: String, path: String, model: String,
        authentication: AuthenticationMode = .bearer,
        customHeaderName: String = "Authorization", timeout: Double = 60,
        audioUploadFormat: AudioUploadFormat = .wav
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.path = path
        self.model = model
        self.authentication = authentication
        self.customHeaderName = customHeaderName
        self.timeout = timeout
        self.audioUploadFormat = audioUploadFormat
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, path, model, authentication, customHeaderName, timeout, audioUploadFormat
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        authentication = try container.decodeIfPresent(AuthenticationMode.self, forKey: .authentication) ?? .bearer
        customHeaderName = try container.decodeIfPresent(String.self, forKey: .customHeaderName) ?? "Authorization"
        timeout = try container.decodeIfPresent(Double.self, forKey: .timeout) ?? 60
        audioUploadFormat = try container.decodeIfPresent(AudioUploadFormat.self, forKey: .audioUploadFormat) ?? .wav
    }

    public var endpointURL: URL? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: base), components.scheme == "https" || components.scheme == "http" else { return nil }
        var basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedSuffix = suffix.lowercased()
        let knownOpenAIRoute = ["audio/transcriptions", "responses", "chat/completions"].contains(normalizedSuffix)
        if knownOpenAIRoute, basePath.split(separator: "/").contains("v1") == false, basePath.hasSuffix(suffix) == false {
            basePath = basePath.isEmpty ? "v1" : "\(basePath)/v1"
        }
        if basePath.hasSuffix(suffix) == false {
            basePath = basePath.isEmpty ? suffix : "\(basePath)/\(suffix)"
        }
        components.path = "/" + basePath
        return components.url
    }
}

public extension ProviderConfiguration {
    static let openAITranscription = ProviderConfiguration(name: "OpenAI STT", baseURL: "https://api.openai.com/v1", path: "audio/transcriptions", model: "gpt-transcribe")
    static let openAIResponses = ProviderConfiguration(name: "OpenAI TTT", baseURL: "https://api.openai.com/v1", path: "responses", model: "gpt-5-mini")
    static func codexResponses(model: CodexModel) -> ProviderConfiguration {
        ProviderConfiguration(
            name: "OpenAI (Codex)",
            baseURL: "https://chatgpt.com/backend-api/codex",
            path: "responses",
            model: model.rawValue,
            authentication: .none
        )
    }
}
