import EntrevoixCore
import Foundation

@MainActor
final class DictationAudioRetentionRecorder: AudioRecording {
    static let archiveFailureLogMessage = "Error: could not retain recording."

    private let recorder: any AudioRecording
    private let archive: any RecordingArchiving
    private let deleteAudioAfterTranscription: @MainActor () -> Bool
    private let logger: any LogWriting

    init(
        recorder: any AudioRecording,
        archive: any RecordingArchiving,
        deleteAudioAfterTranscription: @escaping @MainActor () -> Bool,
        logger: any LogWriting
    ) {
        self.recorder = recorder
        self.archive = archive
        self.deleteAudioAfterTranscription = deleteAudioAfterTranscription
        self.logger = logger
    }

    @discardableResult
    func start(input: AudioInputSelection) throws -> AudioInputStartResult {
        return try recorder.start(input: input)
    }

    func stop() -> URL? {
        guard let sourceURL = recorder.stop() else { return nil }
        if !deleteAudioAfterTranscription() {
            do {
                _ = try archive.archive(sourceURL: sourceURL)
            } catch {
                logger.log(Self.archiveFailureLogMessage)
            }
        }
        return sourceURL
    }

    func cancel() {
        recorder.cancel()
    }

    func deleteLastCapture() {
        recorder.deleteLastCapture()
    }

    func captureSize(at url: URL) -> Int {
        recorder.captureSize(at: url)
    }

    func deleteCapture(at url: URL) {
        recorder.deleteCapture(at: url)
    }
}
