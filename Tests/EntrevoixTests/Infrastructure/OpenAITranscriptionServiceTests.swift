import Foundation
import XCTest
import EntrevoixCore
@testable import EntrevoixOpenAIAdapters
@testable import Entrevoix

final class OpenAITranscriptionServiceTests: XCTestCase {
    func testBuildsDeterministicMultipartRequest() async throws {
        let audioURL = try appTemporaryFile(contents: Data([0x01, 0x02, 0x03]))
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let transport = HTTPStub { request in
            response(url: request.url!, data: Data("{\"text\":\"  bonjour  \"}".utf8))
        }
        let service = OpenAITranscriptionService(
            transport: transport,
            makeBoundary: { "Boundary-Test" }
        )
        let configuration = ProviderConfiguration(
            name: "STT",
            baseURL: "https://stt.example.com/v1",
            path: "audio/transcriptions",
            model: "gpt-transcribe",
            authentication: .bearer,
            timeout: 12
        )

        let text = try await service.transcribe(
            audioURL: audioURL,
            configuration: configuration,
            apiKey: "secret-key",
            prompt: "Names: Entrevoix",
            language: "fr"
        )

        XCTAssertEqual(text, "bonjour")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://stt.example.com/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 12)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=Boundary-Test")

        var expected = Data()
        expected.append(Data("--Boundary-Test\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n".utf8))
        expected.append(Data("--Boundary-Test\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nNames: Entrevoix\r\n".utf8))
        expected.append(Data("--Boundary-Test\r\nContent-Disposition: form-data; name=\"languages[]\"\r\n\r\nfr\r\n".utf8))
        expected.append(Data("--Boundary-Test\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        expected.append(Data([0x01, 0x02, 0x03]))
        expected.append(Data("\r\n--Boundary-Test--\r\n".utf8))
        XCTAssertEqual(request.httpBody, expected)
    }

    func testUsesWhisperLanguageFieldAndOmitsBlankPrompt() async throws {
        let audioURL = try appTemporaryFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let transport = HTTPStub { request in response(url: request.url!, data: Data("plain text".utf8)) }
        let service = OpenAITranscriptionService(transport: transport, makeBoundary: { "B" })
        let configuration = ProviderConfiguration(
            name: "Whisper",
            baseURL: "https://example.com/v1",
            path: "audio/transcriptions",
            model: "whisper-1",
            authentication: .none
        )

        let text = try await service.transcribe(
            audioURL: audioURL,
            configuration: configuration,
            apiKey: "",
            prompt: "  ",
            language: "en"
        )

        XCTAssertEqual(text, "plain text")
        let requests = await transport.requests
        let body = String(decoding: try XCTUnwrap(requests.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"language\""))
        XCTAssertFalse(body.contains("name=\"languages[]\""))
        XCTAssertFalse(body.contains("name=\"prompt\""))
    }

    func testAutomaticLanguageOmitsLanguageField() async throws {
        let audioURL = try appTemporaryFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let transport = HTTPStub { request in response(url: request.url!, data: Data("plain text".utf8)) }
        let service = OpenAITranscriptionService(transport: transport, makeBoundary: { "B" })
        let configuration = ProviderConfiguration(
            name: "Whisper",
            baseURL: "https://example.com/v1",
            path: "audio/transcriptions",
            model: "whisper-1",
            authentication: .none
        )

        _ = try await service.transcribe(
            audioURL: audioURL,
            configuration: configuration,
            apiKey: "",
            prompt: nil,
            language: nil
        )

        let requests = await transport.requests
        let body = String(decoding: try XCTUnwrap(requests.first?.httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"language\""))
        XCTAssertFalse(body.contains("name=\"languages[]\""))
    }

    func testAuthenticationModes() async throws {
        let audioURL = try appTemporaryFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let cases: [(AuthenticationMode, String, String, String?)] = [
            (.bearer, "Authorization", "token", "Bearer token"),
            (.apiKey, "X-API-Key", "token", "token"),
            (.none, "Authorization", "", nil)
        ]

        for (mode, header, key, expected) in cases {
            let transport = HTTPStub { request in response(url: request.url!, data: Data("ok".utf8)) }
            let service = OpenAITranscriptionService(transport: transport)
            let configuration = ProviderConfiguration(
                name: "Auth",
                baseURL: "https://example.com",
                path: "audio/transcriptions",
                model: "model",
                authentication: mode,
                customHeaderName: header
            )
            _ = try await service.transcribe(
                audioURL: audioURL,
                configuration: configuration,
                apiKey: key,
                prompt: nil,
                language: nil
            )
            let requests = await transport.requests
            XCTAssertEqual(requests.first?.value(forHTTPHeaderField: header), expected)
        }
    }

    func testValidationFailuresDoNotCallTransport() async throws {
        let audioURL = try appTemporaryFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let transport = HTTPStub { request in response(url: request.url!) }
        let service = OpenAITranscriptionService(transport: transport)

        await assertTranscriptionError(.invalidEndpoint) {
            try await service.transcribe(
                audioURL: audioURL,
                configuration: ProviderConfiguration(name: "Bad", baseURL: "bad", path: "audio/transcriptions", model: "m"),
                apiKey: "key", prompt: nil, language: nil
            )
        }
        await assertTranscriptionError(.missingAPIKey) {
            try await service.transcribe(
                audioURL: audioURL,
                configuration: ProviderConfiguration(name: "Bad", baseURL: "https://example.com", path: "audio/transcriptions", model: "m"),
                apiKey: "", prompt: nil, language: nil
            )
        }
        await assertTranscriptionError(.invalidHeader) {
            try await service.transcribe(
                audioURL: audioURL,
                configuration: ProviderConfiguration(name: "Bad", baseURL: "https://example.com", path: "audio/transcriptions", model: "m", authentication: .apiKey, customHeaderName: "  "),
                apiKey: "key", prompt: nil, language: nil
            )
        }
        let calls = await transport.requests
        XCTAssertTrue(calls.isEmpty)
    }

    func testRejectsFilesLargerThan25Megabytes() async throws {
        let audioURL = try appTemporaryFile(contents: Data(count: 25 * 1024 * 1024 + 1))
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let transport = HTTPStub { request in response(url: request.url!) }
        let service = OpenAITranscriptionService(transport: transport)

        await assertTranscriptionError(.fileTooLarge) {
            try await service.transcribe(
                audioURL: audioURL,
                configuration: .openAITranscription,
                apiKey: "key",
                prompt: nil,
                language: nil
            )
        }
        let calls = await transport.requests
        XCTAssertTrue(calls.isEmpty)
    }

    func testResponseAndHTTPFailures() async throws {
        let audioURL = try appTemporaryFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let invalidResponse = HTTPStub { request in
            (Data("text".utf8), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 4, textEncodingName: nil))
        }
        await assertTranscriptionError(.invalidResponse) {
            try await self.transcribe(audioURL: audioURL, transport: invalidResponse)
        }

        let empty = HTTPStub { request in response(url: request.url!, data: Data("   ".utf8)) }
        await assertTranscriptionError(.emptyResult) {
            try await self.transcribe(audioURL: audioURL, transport: empty)
        }

        let emptyJSON = HTTPStub { request in
            response(
                url: request.url!,
                data: Data(#"{"text":"","language":null,"duration":0.15664196014404297,"segments":[{"text":"","language":"None","start":0.0,"end":2.559625}]}"#.utf8)
            )
        }
        await assertTranscriptionError(.emptyResult) {
            try await self.transcribe(audioURL: audioURL, transport: emptyJSON)
        }

        let http = HTTPStub { request in
            response(url: request.url!, status: 401, data: Data("{\"error\":{\"message\":\"provider secret\"}}".utf8))
        }
        do {
            _ = try await transcribe(audioURL: audioURL, transport: http)
            XCTFail("Expected HTTP error")
        } catch let error as TranscriptionError {
            guard case .http(let status, let message) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertEqual(status, 401)
            XCTAssertEqual(message, "provider secret")
            XCTAssertEqual(error.logMessage, "STT request failed (HTTP 401).")
        }

        let httpWithoutMessage = HTTPStub { request in
            response(url: request.url!, status: 503, data: Data("unstructured".utf8))
        }
        do {
            _ = try await transcribe(audioURL: audioURL, transport: httpWithoutMessage)
            XCTFail("Expected HTTP error")
        } catch let error as TranscriptionError {
            guard case .http(let status, let message) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertEqual(status, 503)
            XCTAssertNil(message)
            XCTAssertEqual(error.errorDescription, "STT error (HTTP 503).")
        }

        let transportError = HTTPStub { _ in throw AppStubError.failure }
        do {
            _ = try await transcribe(audioURL: audioURL, transport: transportError)
            XCTFail("Expected transport error")
        } catch {
            XCTAssertEqual(error as? AppStubError, .failure)
        }
    }

    private func transcribe(audioURL: URL, transport: any HTTPTransporting) async throws -> String {
        try await OpenAITranscriptionService(transport: transport).transcribe(
            audioURL: audioURL,
            configuration: .openAITranscription,
            apiKey: "key",
            prompt: nil,
            language: nil
        )
    }

    private func assertTranscriptionError(
        _ expected: TranscriptionError,
        operation: () async throws -> String
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as TranscriptionError {
            XCTAssertEqual(String(describing: error), String(describing: expected))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
