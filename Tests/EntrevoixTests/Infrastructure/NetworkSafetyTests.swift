import Foundation
import XCTest
@testable import EntrevoixOpenAIAdapters
@testable import Entrevoix

final class NetworkSafetyTests: XCTestCase {
    func testSameOriginPolicyAcceptsCaseAndImplicitPorts() {
        XCTAssertTrue(SameOriginPolicy.allowsRedirect(
            from: URL(string: "HTTPS://EXAMPLE.com/path")!,
            to: URL(string: "https://example.COM:443/other")!
        ))
        XCTAssertTrue(SameOriginPolicy.allowsRedirect(
            from: URL(string: "http://example.com:80/path")!,
            to: URL(string: "http://example.com/other")!
        ))
        XCTAssertTrue(SameOriginPolicy.allowsRedirect(
            from: URL(string: "custom://example.com/path")!,
            to: URL(string: "CUSTOM://EXAMPLE.COM/other")!
        ))
    }

    func testSameOriginPolicyRejectsSchemeHostAndPortChanges() {
        let original = URL(string: "https://example.com/path")!
        for redirected in [
            URL(string: "http://example.com/path")!,
            URL(string: "https://other.example.com/path")!,
            URL(string: "https://example.com:444/path")!
        ] {
            XCTAssertFalse(SameOriginPolicy.allowsRedirect(from: original, to: redirected))
        }
    }

    func testRedirectDelegateAcceptsOnlySameOrigin() async throws {
        let delegate = SameOriginRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let originalURL = URL(string: "https://example.com/original")!
        let task = session.dataTask(with: originalURL)
        let redirectResponse = try XCTUnwrap(HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "/next"]
        ))

        let accepted = await redirectedRequest(
            delegate: delegate,
            session: session,
            task: task,
            response: redirectResponse,
            destination: URL(string: "https://example.com/next")!
        )
        let rejected = await redirectedRequest(
            delegate: delegate,
            session: session,
            task: task,
            response: redirectResponse,
            destination: URL(string: "https://attacker.example/next")!
        )

        XCTAssertEqual(accepted?.url?.absoluteString, "https://example.com/next")
        XCTAssertNil(rejected)
    }

    private func redirectedRequest(
        delegate: SameOriginRedirectDelegate,
        session: URLSession,
        task: URLSessionTask,
        response: HTTPURLResponse,
        destination: URL
    ) async -> URLRequest? {
        await withCheckedContinuation { continuation in
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: destination)
            ) { request in
                continuation.resume(returning: request)
            }
        }
    }
}
