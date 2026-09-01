import Foundation

/// A stable, localizable description for an error shown in Entrevoix's UI.
public enum UserFacingErrorMessage: Equatable, Sendable, ExpressibleByStringLiteral {
    case recordingCouldNotStart
    case sttInvalidEndpoint
    case sttInvalidHeader
    case sttMissingAPIKey
    case sttFileTooLarge
    case sttAudioEncodingFailed
    case sttInvalidResponse
    case sttEmptyResult
    case sttHTTP(statusCode: Int, providerMessage: String?)
    case tttInvalidEndpoint
    case tttMissingAPIKey
    case tttInvalidHeader
    case tttEmptyInput
    case tttEmptyPrompt
    case tttInvalidResponse
    case tttEmptyResult
    case tttHTTP(statusCode: Int, providerMessage: String?)
    case codexNotConnected
    case codexInvalidRequest
    case codexConnectionFailed
    case verbatim(String)

    public init(stringLiteral value: String) {
        self = .verbatim(value)
    }
}

/// Errors that provide a safe, structured message for the user-facing state machine.
public protocol UserFacingErrorProviding: Error {
    var userFacingMessage: UserFacingErrorMessage { get }
}

public func userFacingMessage(for error: any Error) -> UserFacingErrorMessage {
    if let error = error as? any UserFacingErrorProviding {
        return error.userFacingMessage
    }
    return .verbatim(error.localizedDescription)
}
