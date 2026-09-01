import Foundation

/// Errors that can be safely written to the live diagnostic log.
///
/// Network providers may include user input in an error payload, so callers
/// must never fall back to `localizedDescription` for an unknown error.
public protocol LogSafeError: Error {
    var logMessage: String { get }
}

public func safeLogMessage(for error: any Error) -> String {
    if let error = error as? any LogSafeError {
        return error.logMessage
    }
    return "Operation failed with no exportable details."
}
