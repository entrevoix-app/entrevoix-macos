import Foundation

public protocol HTTPTransporting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Ephemeral URLSession that accepts redirects only within the original origin.
/// Authorization headers are therefore never forwarded to another host.
public struct SafeNetworkSession: HTTPTransporting {
    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        let delegate = SameOriginRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }
}

// URLSession retains this delegate and invokes it serially; it owns no mutable state.
final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard
            let originalURL = task.originalRequest?.url,
            let redirectedURL = request.url,
            SameOriginPolicy.allowsRedirect(from: originalURL, to: redirectedURL)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

}

enum SameOriginPolicy {
    static func allowsRedirect(from lhs: URL, to rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(for: lhs) == effectivePort(for: rhs)
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
