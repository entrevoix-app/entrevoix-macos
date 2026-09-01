import Foundation

/// Refreshable ChatGPT credentials used only by the Codex cleanup adapter.
/// They are persisted in the Keychain and must never be included in preferences
/// or diagnostic logs.
public struct CodexCredentials: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var accountID: String?
    public var computeResidency: String?

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        accountID: String? = nil,
        computeResidency: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.computeResidency = computeResidency
    }

    public var isExpired: Bool { expiresAt <= Date() }
}

@MainActor
public protocol CodexAuthenticating: AnyObject {
    func connect() async throws -> CodexCredentials
}

public protocol CodexCredentialsStoring: Sendable {
    func readCodexCredentials() async throws -> CodexCredentials?
    func saveCodexCredentials(_ credentials: CodexCredentials?) async throws
}

public protocol CodexAccessTokenProviding: Sendable {
    func validCredentials() async throws -> CodexCredentials
}
