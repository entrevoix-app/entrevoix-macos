import Foundation
import Testing
import EntrevoixAppleAdapters
import EntrevoixCore
@testable import EntrevoixOpenAIAdapters
@testable import Entrevoix

@Suite("Provider model catalogue")
struct RemoteModelCatalogClientTests {
    @Test("loads, deduplicates, and sorts bearer-authenticated models")
    func loadsBearerModels() async throws {
        let payload = Data(#"{"data":[{"id":"zeta"},{"id":"Alpha"},{"id":"zeta"},{"id":""}]}"#.utf8)
        let transport = HTTPStub { request in response(url: request.url!, data: payload) }
        let client = RemoteModelCatalogClient(transport: transport)
        let configuration = ProviderConfiguration(
            name: "Remote",
            baseURL: "https://models.example.com/v1",
            path: "",
            model: "",
            timeout: 12
        )

        let models = try await client.discoverModels(configuration: configuration, apiKey: "token")

        #expect(models == ["Alpha", "zeta"])
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://models.example.com/v1/models")
        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == 12)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    }

    @Test("uses a custom API-key header")
    func usesCustomAPIKeyHeader() async throws {
        let payload = Data(#"{"data":[]}"#.utf8)
        let transport = HTTPStub { request in response(url: request.url!, data: payload) }
        let client = RemoteModelCatalogClient(transport: transport)
        let configuration = ProviderConfiguration(
            name: "Compatible",
            baseURL: "https://models.example.com",
            path: "catalogue",
            model: "",
            authentication: .apiKey,
            customHeaderName: "X-Provider-Key"
        )

        _ = try await client.discoverModels(configuration: configuration, apiKey: "secret")

        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Provider-Key") == "secret")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("rejects missing credentials before sending a request")
    func rejectsMissingCredentials() async {
        let transport = HTTPStub { request in response(url: request.url!) }
        let client = RemoteModelCatalogClient(transport: transport)
        let configuration = ProviderConfiguration(
            name: "Remote",
            baseURL: "https://models.example.com",
            path: "models",
            model: ""
        )

        do {
            _ = try await client.discoverModels(configuration: configuration, apiKey: "  ")
            Issue.record("Expected missingAPIKey")
        } catch ModelCatalogError.missingAPIKey {
            #expect(await transport.requests.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("rejects invalid endpoints and HTTP failures")
    func rejectsInvalidResponses() async {
        let unusedTransport = HTTPStub { request in response(url: request.url!) }
        let client = RemoteModelCatalogClient(transport: unusedTransport)
        let invalid = ProviderConfiguration(name: "Invalid", baseURL: "file:///tmp", path: "models", model: "")

        do {
            _ = try await client.discoverModels(configuration: invalid, apiKey: "token")
            Issue.record("Expected invalidEndpoint")
        } catch ModelCatalogError.invalidEndpoint {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let failingTransport = HTTPStub { request in response(url: request.url!, status: 503) }
        let failingClient = RemoteModelCatalogClient(transport: failingTransport)
        let valid = ProviderConfiguration(name: "Remote", baseURL: "https://models.example.com", path: "models", model: "")
        do {
            _ = try await failingClient.discoverModels(configuration: valid, apiKey: "token")
            Issue.record("Expected HTTP failure")
        } catch ModelCatalogError.http(let status) {
            #expect(status == 503)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Suite("Provider routing")
struct ProviderRoutingTests {
    @Test("routes remote transcription through request and compatibility APIs")
    func routesRemoteTranscription() async throws {
        let router = ProviderSpeechRouter(
            remote: RemoteSpeechStub(),
            apple: AppleSpeechTranscriptionService(resources: AppleSpeechResourceManager())
        )
        let request = TranscriptionRequest(
            configuration: .openAITranscription,
            apiKey: "key",
            prompt: "dictionary",
            language: "fr",
            target: .remote
        )
        let audioURL = URL(fileURLWithPath: "/tmp/provider-routing.wav")

        try await router.preflight(request: request)
        #expect(try await router.transcribe(audioURL: audioURL, request: request) == "remote:dictionary:fr")
        #expect(try await router.transcribe(
            audioURL: audioURL,
            configuration: .openAITranscription,
            apiKey: "key",
            prompt: "legacy",
            language: "en"
        ) == "remote:legacy:en")
    }

    @Test("routes remote and Codex cleanup to their adapters")
    func routesCleanup() async throws {
        let payload = Data(#"{"output_text":"cleaned","output":[]}"#.utf8)
        let transport = HTTPStub { request in response(url: request.url!, data: payload) }
        let router = ProviderCleanupRouter(
            remote: RemoteCleanupStub(),
            codex: CodexCleanupService(
                transport: transport,
                credentialsProvider: TestCodexCredentialsProvider()
            ),
            apple: AppleFoundationCleanupService()
        )
        let remoteRequest = CleanupRequest(
            configuration: .openAIResponses,
            apiKey: "key",
            format: .responses,
            prompt: "remote policy",
            failurePolicy: .stop,
            target: .remote
        )
        let codexRequest = CleanupRequest(
            configuration: .codexResponses(model: .gpt56Luna),
            apiKey: "",
            format: .responses,
            prompt: "codex policy",
            failurePolicy: .stop,
            target: .codex
        )

        try await router.preflight(request: remoteRequest)
        try await router.preflight(request: codexRequest)
        #expect(try await router.clean(text: "raw", request: remoteRequest) == "remote:raw:remote policy")
        #expect(try await router.clean(text: "raw", request: codexRequest) == "cleaned")
        #expect(try await router.clean(
            text: "raw",
            configuration: .openAIResponses,
            apiKey: "key",
            format: .responses,
            prompt: "legacy policy"
        ) == "remote:raw:legacy policy")
    }
}

private struct RemoteSpeechStub: SpeechTranscribing {
    func transcribe(
        audioURL: URL,
        configuration: ProviderConfiguration,
        apiKey: String,
        prompt: String?,
        language: String?
    ) async throws -> String {
        "remote:\(prompt ?? ""):\(language ?? "")"
    }
}

private struct RemoteCleanupStub: TextCleaning {
    func clean(
        text: String,
        configuration: ProviderConfiguration,
        apiKey: String,
        format: CleanupAPIFormat,
        prompt: String
    ) async throws -> String {
        "remote:\(text):\(prompt)"
    }
}

private actor TestCodexCredentialsProvider: CodexAccessTokenProviding {
    func validCredentials() async throws -> CodexCredentials {
        CodexCredentials(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture)
    }
}
