import Foundation

/// Immutable application state consumed by presentation stores.
public struct DictationSnapshot: Equatable, Sendable {
    public let state: DictationState
    public let lastAudioURL: URL?
    public let lastTranscript: String?

    public init(state: DictationState, lastAudioURL: URL?, lastTranscript: String?) {
        self.state = state
        self.lastAudioURL = lastAudioURL
        self.lastTranscript = lastTranscript
    }
}
