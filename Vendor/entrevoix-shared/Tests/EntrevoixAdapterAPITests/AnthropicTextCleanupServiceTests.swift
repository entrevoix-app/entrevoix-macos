import Foundation
import Testing
import EntrevoixCore
@testable import EntrevoixOpenAIAdapters

@Test("Anthropic cleanup builds a Messages request and extracts text blocks")
func anthropicCleanupBuildsExpectedRequest() async throws {
    let transport = AnthropicHTTPStub(data: Data(#"{"content":[{"type":"thinking"},{"type":"text","text":"  cleaned "},{"type":"text","text":"text  "}]}"#.utf8))
    let result = try await AnthropicTextCleanupService(transport: transport).clean(
        text: "raw transcript",
        configuration: RemoteProviderProfile.anthropic().configuration(for: .ttt)!,
        apiKey: "secret",
        format: .anthropicMessages,
        prompt: "Clean it."
    )

    #expect(result == "cleaned text")
    let request = try #require(await transport.request)
    #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
    #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    let body = try #require(request.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["model"] as? String == "claude-sonnet-5")
    #expect(object["max_tokens"] as? Int == 4_096)
}

@Test("Anthropic cleanup falls back when the provider echoes the cleanup policy")
func anthropicCleanupProtectsTranscript() async throws {
    let policy = "Correct punctuation."
    let transport = AnthropicHTTPStub(data: Data(#"{"content":[{"type":"text","text":"Correct punctuation."}]}"#.utf8))
    let result = try await AnthropicTextCleanupService(transport: transport).clean(
        text: "raw transcript",
        configuration: RemoteProviderProfile.anthropic().configuration(for: .ttt)!,
        apiKey: "secret",
        format: .anthropicMessages,
        prompt: policy
    )

    #expect(result == "raw transcript")
}

@Test("Anthropic cleanup exposes structured HTTP failures")
func anthropicCleanupHandlesHTTPFailure() async {
    let transport = AnthropicHTTPStub(
        data: Data(#"{"error":{"message":"rate limited"}}"#.utf8),
        statusCode: 429
    )

    do {
        _ = try await AnthropicTextCleanupService(transport: transport).clean(
            text: "raw transcript",
            configuration: RemoteProviderProfile.anthropic().configuration(for: .ttt)!,
            apiKey: "secret",
            format: .anthropicMessages,
            prompt: "Clean it."
        )
        Issue.record("Expected an HTTP failure")
    } catch let error as AnthropicCleanupError {
        #expect(error.userFacingMessage == .tttHTTP(statusCode: 429, providerMessage: "rate limited"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private actor AnthropicHTTPStub: HTTPTransporting {
    let data: Data
    let statusCode: Int
    private(set) var request: URLRequest?

    init(data: Data, statusCode: Int = 200) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        return (data, HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!)
    }
}
