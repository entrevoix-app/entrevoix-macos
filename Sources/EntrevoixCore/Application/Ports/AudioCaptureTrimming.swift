import Foundation

/// The result of preparing a completed audio capture for transcription.
public enum AudioCaptureTrimResult: Sendable, Equatable {
    case unchanged(URL)
    case trimmed(URL)
    case noSpeechDetected
}

/// Detects speech at the edges of a completed recording and optionally removes
/// leading and trailing silence. Implementations must leave the source capture
/// intact when returning `.unchanged`.
public protocol AudioCaptureTrimming: Sendable {
    func trimLeadingAndTrailingSilence(
        in audioURL: URL,
        language: String?
    ) async -> AudioCaptureTrimResult
}

/// Default behavior used when no platform audio processor is assembled.
public struct PassthroughAudioCaptureTrimmer: AudioCaptureTrimming {
    public init() {}

    public func trimLeadingAndTrailingSilence(
        in audioURL: URL,
        language: String?
    ) async -> AudioCaptureTrimResult {
        .unchanged(audioURL)
    }
}
