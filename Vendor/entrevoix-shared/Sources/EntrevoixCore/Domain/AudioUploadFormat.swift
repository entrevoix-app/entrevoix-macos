import Foundation

/// The container and encoding used when uploading a completed dictation to a
/// remote speech-to-text provider. Local recording and silence trimming remain
/// uncompressed WAV regardless of this choice.
public enum AudioUploadFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case wav
    case m4aAAC
    case flac

    public var id: Self { self }
}
