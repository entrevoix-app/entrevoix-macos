import AppKit
import CryptoKit
import Foundation
import Network
import EntrevoixCore

/// Constants for the undocumented ChatGPT Codex protocol. Keeping these in one
/// adapter makes changes to the external protocol contained and reviewable.
enum CodexProtocol {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let issuer = URL(string: "https://auth.openai.com")!
    static let callbackPort: NWEndpoint.Port = 1455
    static let callbackPath = "/auth/callback"
    static let responsesEndpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    static let keychainService = "com.d9beuD.Entrevoix"
    static let keychainAccount = "codex-oauth"
}

enum CodexAuthenticationError: Error, Equatable, LogSafeError, UserFacingErrorProviding {
    case callbackServerUnavailable
    case callbackTimedOut
    case callbackRejected
    case browserCouldNotOpen
    case tokenExchangeFailed(Int)
    case refreshFailed(Int)
    case malformedTokenResponse

    var logMessage: String {
        switch self {
        case .callbackServerUnavailable: "Codex OAuth callback listener could not start."
        case .callbackTimedOut: "Codex OAuth callback timed out."
        case .callbackRejected: "Codex OAuth callback was rejected."
        case .browserCouldNotOpen: "Codex OAuth browser could not open."
        case .tokenExchangeFailed(let status): "Codex OAuth token exchange failed (HTTP \(status))."
        case .refreshFailed(let status): "Codex OAuth token refresh failed (HTTP \(status))."
        case .malformedTokenResponse: "Codex OAuth returned an invalid token response."
        }
    }

    var userFacingMessage: UserFacingErrorMessage { .codexConnectionFailed }
}

private struct CodexTokenResponse: Decodable {
    let idToken: String?
    let accessToken: String
    let refreshToken: String
    let expiresIn: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

struct CodexOAuthTokenClient: Sendable {
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(session: URLSession = .ephemeralCodex, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    func authorizationURL(redirectURI: URL, challenge: String, state: String) -> URL {
        var components = URLComponents(url: CodexProtocol.issuer.appending(path: "oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: CodexProtocol.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: "opencode")
        ]
        return components.url!
    }

    func exchange(code: String, redirectURI: URL, verifier: String) async throws -> CodexCredentials {
        try await requestToken(
            items: [
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", redirectURI.absoluteString),
                ("client_id", CodexProtocol.clientID),
                ("code_verifier", verifier)
            ],
            failure: CodexAuthenticationError.tokenExchangeFailed
        )
    }

    func refresh(_ credentials: CodexCredentials) async throws -> CodexCredentials {
        try await requestToken(
            items: [
                ("grant_type", "refresh_token"),
                ("refresh_token", credentials.refreshToken),
                ("client_id", CodexProtocol.clientID)
            ],
            failure: CodexAuthenticationError.refreshFailed,
            fallbackAccountID: credentials.accountID,
            fallbackResidency: credentials.computeResidency
        )
    }

    private func requestToken(
        items: [(String, String)],
        failure: (Int) -> CodexAuthenticationError,
        fallbackAccountID: String? = nil,
        fallbackResidency: String? = nil
    ) async throws -> CodexCredentials {
        var request = URLRequest(url: CodexProtocol.issuer.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = items
            .map { "\(formEncode($0.0))=\(formEncode($0.1))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CodexAuthenticationError.malformedTokenResponse }
        guard (200..<300).contains(http.statusCode) else { throw failure(http.statusCode) }
        guard let token = try? JSONDecoder().decode(CodexTokenResponse.self, from: data) else {
            throw CodexAuthenticationError.malformedTokenResponse
        }
        let claims = JWTClaims(token.idToken ?? token.accessToken)
        return CodexCredentials(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: now().addingTimeInterval(token.expiresIn ?? 3_600),
            accountID: claims.accountID ?? fallbackAccountID,
            computeResidency: claims.computeResidency ?? fallbackResidency
        )
    }

    private func formEncode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

@MainActor
final class CodexBrowserAuthenticator: CodexAuthenticating {
    private let tokenClient: CodexOAuthTokenClient

    init(tokenClient: CodexOAuthTokenClient = CodexOAuthTokenClient()) {
        self.tokenClient = tokenClient
    }

    func connect() async throws -> CodexCredentials {
        let verifier = PKCE.verifier()
        let state = PKCE.randomValue()
        let callback = try CodexLoopbackCallbackServer()
        let redirectURI = callback.redirectURI
        let url = tokenClient.authorizationURL(redirectURI: redirectURI, challenge: PKCE.challenge(for: verifier), state: state)
        guard NSWorkspace.shared.open(url) else { throw CodexAuthenticationError.browserCouldNotOpen }
        let code = try await callback.waitForCode(expectedState: state)
        return try await tokenClient.exchange(code: code, redirectURI: redirectURI, verifier: verifier)
    }
}

actor CodexCredentialVault: CodexCredentialsStoring, CodexAccessTokenProviding {
    private let access: any CodexKeychainAccessing
    private let tokenClient: CodexOAuthTokenClient
    private var cachedCredentials: CodexCredentials?
    private var refreshTask: Task<CodexCredentials, any Error>?
    private var credentialsGeneration = 0

    init(access: any CodexKeychainAccessing = SystemCodexKeychainAccess(), tokenClient: CodexOAuthTokenClient = CodexOAuthTokenClient()) {
        self.access = access
        self.tokenClient = tokenClient
    }

    func readCodexCredentials() async throws -> CodexCredentials? {
        if let cachedCredentials { return cachedCredentials }
        guard let data = try access.read(service: CodexProtocol.keychainService, account: CodexProtocol.keychainAccount) else { return nil }
        let credentials = try JSONDecoder().decode(CodexCredentials.self, from: data)
        cachedCredentials = credentials
        return credentials
    }

    func saveCodexCredentials(_ credentials: CodexCredentials?) async throws {
        credentialsGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        cachedCredentials = credentials
        guard let credentials else {
            try access.delete(service: CodexProtocol.keychainService, account: CodexProtocol.keychainAccount)
            return
        }
        try access.upsert(
            JSONEncoder().encode(credentials),
            service: CodexProtocol.keychainService,
            account: CodexProtocol.keychainAccount
        )
    }

    func validCredentials() async throws -> CodexCredentials {
        guard let credentials = try await readCodexCredentials() else { throw CodexCleanupError.notConnected }
        guard credentials.isExpired else { return credentials }
        if let refreshTask { return try await refreshTask.value }

        let generation = credentialsGeneration
        let task = Task { [tokenClient] in try await tokenClient.refresh(credentials) }
        refreshTask = task
        do {
            let refreshed = try await task.value
            guard credentialsGeneration == generation else { throw CancellationError() }
            refreshTask = nil
            cachedCredentials = refreshed
            try access.upsert(
                JSONEncoder().encode(refreshed),
                service: CodexProtocol.keychainService,
                account: CodexProtocol.keychainAccount
            )
            return refreshed
        } catch {
            if credentialsGeneration == generation { refreshTask = nil }
            throw error
        }
    }
}

private enum PKCE {
    static func verifier() -> String { randomValue(length: 64) }
    static func randomValue(length: Int = 43) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).compactMap { _ in alphabet.randomElement() })
    }
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct JWTClaims {
    let accountID: String?
    let computeResidency: String?

    init(_ token: String) {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let data = Data(base64URLEncoded: String(parts[1])),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            accountID = nil; computeResidency = nil; return
        }
        let namespaced = value["https://api.openai.com/auth"] as? [String: Any]
        accountID = value["chatgpt_account_id"] as? String
            ?? namespaced?["chatgpt_account_id"] as? String
            ?? ((value["organizations"] as? [[String: Any]])?.first?["id"] as? String)
        let residency = namespaced?["chatgpt_compute_residency"] as? String
            ?? value["chatgpt_compute_residency"] as? String
        computeResidency = residency == "no_constraint" ? nil : residency
    }
}

@MainActor
private final class CodexLoopbackCallbackServer {
    private let listener: NWListener
    private var continuation: CheckedContinuation<String, any Error>?
    private var timeoutTask: Task<Void, Never>?

    init() throws {
        do {
            listener = try NWListener(using: .tcp, on: CodexProtocol.callbackPort)
        } catch {
            throw CodexAuthenticationError.callbackServerUnavailable
        }
    }

    deinit { listener.cancel() }

    var redirectURI: URL {
        URL(string: "http://localhost:\(CodexProtocol.callbackPort.rawValue)\(CodexProtocol.callbackPath)")!
    }

    func waitForCode(expectedState: String) async throws -> String {
        try Task.checkCancellation()
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, _, _ in
                Task { @MainActor in self.handle(data: data, connection: connection, expectedState: expectedState) }
            }
        }
        listener.start(queue: .main)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    self?.finish(.failure(CodexAuthenticationError.callbackTimedOut))
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finish(.failure(CancellationError())) }
        }
    }

    private func handle(data: Data?, connection: NWConnection, expectedState: String) {
        defer { connection.cancel() }
        guard let data, let request = String(data: data, encoding: .utf8), let target = request.split(separator: "\n").first?.split(separator: " ").dropFirst().first,
              let url = URLComponents(string: "http://localhost\(target)") else {
            finish(.failure(CodexAuthenticationError.callbackRejected)); return
        }
        let items = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard url.path == CodexProtocol.callbackPath, items["state"] == expectedState, let code = items["code"], !code.isEmpty else {
            respond(connection, status: 400, message: "Authorization failed.")
            finish(.failure(CodexAuthenticationError.callbackRejected)); return
        }
        respond(connection, status: 200, message: "You can return to Entrevoix.")
        finish(.success(code))
    }

    private func respond(_ connection: NWConnection, status: Int, message: String) {
        let body = "<html><body><p>\(message)</p></body></html>"
        let response = "HTTP/1.1 \(status) OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    private func finish(_ result: Result<String, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel(); timeoutTask = nil
        listener.cancel()
        continuation.resume(with: result)
    }
}

private extension URLSession {
    static let ephemeralCodex: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(
            configuration: configuration,
            delegate: CodexSameOriginRedirectDelegate(),
            delegateQueue: nil
        )
    }()
}

private final class CodexSameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
            CodexSameOriginPolicy.allowsRedirect(from: originalURL, to: redirectedURL)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private enum CodexSameOriginPolicy {
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

private extension Data {
    init?(base64URLEncoded value: String) {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized.append(String(repeating: "=", count: (4 - normalized.count % 4) % 4))
        self.init(base64Encoded: normalized)
    }
}
