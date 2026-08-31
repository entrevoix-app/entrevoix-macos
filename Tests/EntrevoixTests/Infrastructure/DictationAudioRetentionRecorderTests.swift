import EntrevoixCore
import Foundation
@testable import Entrevoix
import XCTest

@MainActor
final class DictationAudioRetentionRecorderTests: XCTestCase {
    func testDeletionEnabledDoesNotArchiveAtSuccessfulStop() {
        let sourceURL = url("source.wav")
        let recorder = RetentionRecorderSpy(stopURL: sourceURL)
        let archive = RetentionArchiveSpy()
        let sut = makeSUT(recorder: recorder, archive: archive, deleteAudioAfterTranscription: true)

        XCTAssertEqual(sut.stop(), sourceURL)

        XCTAssertEqual(archive.sources, [])
    }

    func testDeletionDisabledArchivesSourceAtSuccessfulStopAndReturnsOriginalURL() {
        let sourceURL = url("source.wav")
        let recorder = RetentionRecorderSpy(stopURL: sourceURL)
        let archive = RetentionArchiveSpy()
        let sut = makeSUT(recorder: recorder, archive: archive, deleteAudioAfterTranscription: false)

        XCTAssertEqual(sut.stop(), sourceURL)

        XCTAssertEqual(archive.sources, [sourceURL])
    }

    func testDeferredDeletionForwardsFinalTrimmedURLWithoutArchivingAgain() {
        let sourceURL = url("source.wav")
        let trimmedURL = url("trimmed.wav")
        let recorder = RetentionRecorderSpy(stopURL: sourceURL)
        let archive = RetentionArchiveSpy()
        let sut = makeSUT(recorder: recorder, archive: archive, deleteAudioAfterTranscription: false)

        XCTAssertEqual(sut.stop(), sourceURL)
        sut.deleteCapture(at: trimmedURL)

        XCTAssertEqual(archive.sources, [sourceURL])
        XCTAssertEqual(recorder.deletedURLs, [trimmedURL])
    }

    func testPolicyIsEvaluatedAtEachSuccessfulStop() {
        let firstURL = url("first.wav")
        let secondURL = url("second.wav")
        let setting = RetentionSetting(value: false)
        let recorder = RetentionRecorderSpy(stopURL: firstURL)
        let archive = RetentionArchiveSpy()
        let sut = makeSUT(recorder: recorder, archive: archive, setting: setting)

        XCTAssertEqual(sut.stop(), firstURL)
        setting.value = true
        recorder.stopURL = secondURL
        XCTAssertEqual(sut.stop(), secondURL)

        XCTAssertEqual(archive.sources, [firstURL])
    }

    func testTwoRetainedStopsBeforeEitherCleanupArchiveBothSources() {
        let firstURL = url("first.wav")
        let secondURL = url("second.wav")
        let recorder = RetentionRecorderSpy(stopURL: firstURL)
        let archive = RetentionArchiveSpy()
        let sut = makeSUT(recorder: recorder, archive: archive, deleteAudioAfterTranscription: false)

        XCTAssertEqual(sut.stop(), firstURL)
        recorder.stopURL = secondURL
        XCTAssertEqual(sut.stop(), secondURL)
        sut.deleteCapture(at: secondURL)
        sut.deleteCapture(at: firstURL)

        XCTAssertEqual(archive.sources, [firstURL, secondURL])
        XCTAssertEqual(recorder.deletedURLs, [secondURL, firstURL])
    }

    func testArchiveFailureLogsSafeConstantOnceAndStillReturnsSource() {
        let sourceURL = url("private-source.wav")
        let recorder = RetentionRecorderSpy(stopURL: sourceURL)
        let archive = RetentionArchiveSpy(error: RetentionArchiveError.privateMarker)
        let logger = RetentionLogSpy()
        let sut = makeSUT(recorder: recorder, archive: archive, deleteAudioAfterTranscription: false, logger: logger)

        XCTAssertEqual(sut.stop(), sourceURL)
        sut.deleteCapture(at: sourceURL)

        XCTAssertEqual(archive.sources, [sourceURL])
        XCTAssertEqual(logger.messages, [DictationAudioRetentionRecorder.archiveFailureLogMessage])
        XCTAssertFalse(logger.messages[0].contains(sourceURL.path))
        XCTAssertFalse(logger.messages[0].contains("privateMarker"))
        XCTAssertEqual(recorder.deletedURLs, [sourceURL])
    }

    func testNilStopDoesNotArchiveOrLog() {
        let recorder = RetentionRecorderSpy(stopURL: nil)
        let archive = RetentionArchiveSpy()
        let logger = RetentionLogSpy()
        let sut = makeSUT(recorder: recorder, archive: archive, deleteAudioAfterTranscription: false, logger: logger)

        XCTAssertNil(sut.stop())

        XCTAssertEqual(archive.sources, [])
        XCTAssertEqual(logger.messages, [])
    }

    func testCancelBeforeStopForwardsWithoutArchiving() {
        let recorder = RetentionRecorderSpy()
        let archive = RetentionArchiveSpy()
        let sut = makeSUT(recorder: recorder, archive: archive, deleteAudioAfterTranscription: false)

        sut.cancel()

        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertEqual(archive.sources, [])
    }

    func testCancelAfterRetainedStopForwardsBecauseArchiveAlreadyExists() {
        let sourceURL = url("source.wav")
        let recorder = RetentionRecorderSpy(stopURL: sourceURL)
        let archive = RetentionArchiveSpy()
        let sut = makeSUT(recorder: recorder, archive: archive, deleteAudioAfterTranscription: false)

        XCTAssertEqual(sut.stop(), sourceURL)
        sut.cancel()

        XCTAssertEqual(archive.sources, [sourceURL])
        XCTAssertEqual(recorder.cancelCount, 1)
    }

    func testDeleteLastCaptureForwardsWithoutArchiving() {
        let sourceURL = url("source.wav")
        let recorder = RetentionRecorderSpy(stopURL: sourceURL)
        let archive = RetentionArchiveSpy()
        let sut = makeSUT(recorder: recorder, archive: archive, deleteAudioAfterTranscription: false)

        sut.deleteLastCapture()

        XCTAssertEqual(archive.sources, [])
        XCTAssertEqual(recorder.deleteLastCaptureCount, 1)
    }

    func testDeleteCaptureWithoutStopForwardsWithoutArchiving() {
        let sourceURL = url("source.wav")
        let recorder = RetentionRecorderSpy()
        let archive = RetentionArchiveSpy()
        let sut = makeSUT(recorder: recorder, archive: archive, deleteAudioAfterTranscription: false)

        sut.deleteCapture(at: sourceURL)

        XCTAssertEqual(archive.sources, [])
        XCTAssertEqual(recorder.deletedURLs, [sourceURL])
    }

    func testCaptureSizeForwardsURLAndResult() {
        let sourceURL = url("source.wav")
        let recorder = RetentionRecorderSpy(captureSizeResult: 42)
        let sut = makeSUT(recorder: recorder, archive: RetentionArchiveSpy(), deleteAudioAfterTranscription: true)

        XCTAssertEqual(sut.captureSize(at: sourceURL), 42)

        XCTAssertEqual(recorder.captureSizeURLs, [sourceURL])
    }

    private func makeSUT(
        recorder: RetentionRecorderSpy,
        archive: RetentionArchiveSpy,
        deleteAudioAfterTranscription: Bool? = nil,
        setting: RetentionSetting? = nil,
        logger: RetentionLogSpy = RetentionLogSpy()
    ) -> DictationAudioRetentionRecorder {
        let setting = setting ?? RetentionSetting(value: deleteAudioAfterTranscription ?? true)
        return DictationAudioRetentionRecorder(
            recorder: recorder,
            archive: archive,
            deleteAudioAfterTranscription: { setting.value },
            logger: logger
        )
    }

    private func url(_ name: String) -> URL {
        URL(filePath: "/tmp/\(name)")
    }
}

@MainActor
private final class RetentionRecorderSpy: AudioRecording {
    var stopURL: URL?
    let captureSizeResult: Int
    private(set) var deletedURLs: [URL] = []
    private(set) var cancelCount = 0
    private(set) var deleteLastCaptureCount = 0
    private(set) var captureSizeURLs: [URL] = []

    init(stopURL: URL? = nil, captureSizeResult: Int = 0) {
        self.stopURL = stopURL
        self.captureSizeResult = captureSizeResult
    }

    @discardableResult
    func start(input _: AudioInputSelection) throws -> AudioInputStartResult { .requestedInput }
    func stop() -> URL? { stopURL }
    func cancel() { cancelCount += 1 }
    func deleteLastCapture() { deleteLastCaptureCount += 1 }
    func captureSize(at url: URL) -> Int {
        captureSizeURLs.append(url)
        return captureSizeResult
    }
    func deleteCapture(at url: URL) { deletedURLs.append(url) }
}

@MainActor
private final class RetentionArchiveSpy: RecordingArchiving {
    var error: (any Error)?
    private(set) var sources: [URL] = []

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func archive(sourceURL: URL) throws -> URL {
        sources.append(sourceURL)
        if let error { throw error }
        return sourceURL.appending(path: "archived.wav")
    }
}

@MainActor
private final class RetentionSetting {
    var value: Bool
    init(value: Bool) { self.value = value }
}

@MainActor
private final class RetentionLogSpy: LogWriting {
    private(set) var messages: [String] = []
    func log(_ message: String) { messages.append(message) }
}

private enum RetentionArchiveError: Error {
    case privateMarker
}
