import Foundation
import XCTest
import EntrevoixCore
@testable import Entrevoix

final class CodexCleanupServiceTests: XCTestCase {
    func testBuildsCodexResponsesRequestWithoutLeakingCredentials() async throws {
        let transport = HTTPStub { request in
            response(url: request.url!, data: Data("{\"output_text\":\"cleaned\"}".utf8))
        }
        let credentials = CodexCredentials(
            accessToken: "access-secret",
            refreshToken: "refresh-secret",
            expiresAt: .distantFuture,
            accountID: "account-1",
            computeResidency: "eu"
        )
        let service = CodexCleanupService(
            transport: transport,
            credentialsProvider: StaticCodexCredentials(credentials)
        )
        let result = try await service.clean(
            text: "raw text",
            request: CleanupRequest(
                configuration: .codexResponses(model: .gpt56Luna),
                apiKey: "",
                format: .responses,
                prompt: "Clean it.",
                failurePolicy: .stop,
                target: .codex
            )
        )

        XCTAssertEqual(result, "cleaned")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url, CodexProtocol.responsesEndpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-openai-internal-codex-residency"), "eu")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(body["instructions"] as? String, CleanupTransformationPolicy.systemInstructions)
        XCTAssertEqual(
            body["input"] as? String,
            CleanupTransformationPolicy.input(instructions: "Clean it.", transcript: "raw text")
        )
        XCTAssertEqual(body["store"] as? Bool, false)
    }

    func testRejectsMissingCodexCredentialsBeforeNetworkAccess() async {
        let transport = HTTPStub { request in response(url: request.url!) }
        let service = CodexCleanupService(transport: transport)

        do {
            _ = try await service.clean(
                text: "raw",
                request: CleanupRequest(
                    configuration: .codexResponses(model: .gpt56Luna),
                    apiKey: "",
                    format: .responses,
                    prompt: "Clean it.",
                    failurePolicy: .stop,
                    target: .codex
                )
            )
            XCTFail("Expected a missing-credentials error")
        } catch let error as CodexCleanupError {
            guard case .notConnected = error else { return XCTFail("Unexpected error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }
}

private actor StaticCodexCredentials: CodexAccessTokenProviding {
    let credentials: CodexCredentials
    init(_ credentials: CodexCredentials) { self.credentials = credentials }
    func validCredentials() async throws -> CodexCredentials { credentials }
}
