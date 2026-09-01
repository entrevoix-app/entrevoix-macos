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
    func processCapture(
        in audioURL: URL,
        language: String?,
        removeEdgeSilence: Bool,
        reduceInternalPauses: Bool
    ) async -> AudioCaptureTrimResult
}

public enum AudioCaptureTrimmingResourceState: Equatable, Sendable {
    case checking
    case unsupported
    case downloadRequired
    case downloading
    case ready
    case failed
}

/// Manages the local Apple Speech resource used to identify timed speech ranges.
public protocol AudioCaptureTrimmingResourceManaging: Sendable {
    func preparationState(for requestedLocale: Locale) async -> AudioCaptureTrimmingResourceState
    func download(for requestedLocale: Locale) async throws
}

public struct UnavailableAudioCaptureTrimmingResourceManager: AudioCaptureTrimmingResourceManaging {
    public init() {}

    public func preparationState(for requestedLocale: Locale) async -> AudioCaptureTrimmingResourceState {
        .unsupported
    }

    public func download(for requestedLocale: Locale) async throws {
        throw ResourceError.unavailable
    }

    public enum ResourceError: Error, Sendable {
        case unavailable
    }
}

/// Default behavior used when no platform audio processor is assembled.
public struct PassthroughAudioCaptureTrimmer: AudioCaptureTrimming {
    public init() {}

    public func processCapture(
        in audioURL: URL,
        language: String?,
        removeEdgeSilence: Bool,
        reduceInternalPauses: Bool
    ) async -> AudioCaptureTrimResult {
        .unchanged(audioURL)
    }
}
