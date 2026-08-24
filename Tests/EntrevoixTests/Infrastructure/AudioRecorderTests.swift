import AVFoundation
import CoreMedia
import EntrevoixCore
import Speech
import XCTest
@testable import Entrevoix

@MainActor
final class AudioRecorderTests: XCTestCase {
    func testSpeechTrimUsesWordTimeRangesInsteadOfFinalizationRange() {
        var spoken = AttributedString("speech")
        spoken[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = CMTimeRange(
            start: CMTime(seconds: 1, preferredTimescale: 1_000),
            duration: CMTime(seconds: 2, preferredTimescale: 1_000)
        )
        var finalizationMarker = AttributedString(" ")
        finalizationMarker[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = CMTimeRange(
            start: CMTime(seconds: 8, preferredTimescale: 1_000),
            duration: .zero
        )
        spoken.append(finalizationMarker)

        XCTAssertEqual(
            AppleSpeechAudioCaptureTrimmer.wordTimeRanges(in: spoken),
            [CMTimeRange(
                start: CMTime(seconds: 1, preferredTimescale: 1_000),
                duration: CMTime(seconds: 2, preferredTimescale: 1_000)
            )]
        )
    }

    func testCaptureEngineIsReusedWithoutVoiceProcessing() throws {
        let engine = AudioCaptureEngineSpy()
        let factory = AudioCaptureEngineFactorySpy(engines: [engine])
        let recorder = AudioRecorder(logger: AppLogStore(), captureEngineFactory: factory)

        try recorder.start(input: .systemDefault)
        recorder.cancel()
        try recorder.start(input: .systemDefault)
        recorder.cancel()

        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertEqual(engine.startCaptureCount, 2)
        XCTAssertEqual(engine.pauseCaptureCount, 2)
        XCTAssertEqual(engine.discardCount, 0)
    }

    func testSelectedInputUsesItsOwnCaptureEngine() throws {
        let systemEngine = AudioCaptureEngineSpy()
        let selectedEngine = AudioCaptureEngineSpy()
        let factory = AudioCaptureEngineFactorySpy(engines: [systemEngine, selectedEngine])
        let recorder = AudioRecorder(logger: AppLogStore(), captureEngineFactory: factory)
        let selectedInput = AudioInputDeviceReference(uid: "external-mic", name: "External microphone")

        try recorder.start(input: .systemDefault)
        recorder.cancel()
        try recorder.start(input: .device(selectedInput))
        recorder.cancel()
        XCTAssertEqual(factory.makeCount, 2)
        XCTAssertEqual(systemEngine.configuredInputs, [.systemDefault])
        XCTAssertEqual(selectedEngine.configuredInputs, [.device(selectedInput)])
    }

    func testUnavailableSelectedInputDiscardsItsEngineAndFallsBackToSystemDefault() throws {
        let unavailableEngine = AudioCaptureEngineSpy(configureError: AppStubError.failure)
        let fallbackEngine = AudioCaptureEngineSpy()
        let factory = AudioCaptureEngineFactorySpy(engines: [unavailableEngine, fallbackEngine])
        let recorder = AudioRecorder(logger: AppLogStore(), captureEngineFactory: factory)
        let selectedInput = AudioInputDeviceReference(uid: "missing-device", name: "Missing microphone")

        let result = try recorder.start(input: .device(selectedInput))
        recorder.cancel()

        XCTAssertEqual(result, .fellBackToSystemDefault)
        XCTAssertEqual(unavailableEngine.configuredInputs, [.device(selectedInput)])
        XCTAssertEqual(unavailableEngine.discardCount, 1)
        XCTAssertEqual(fallbackEngine.configuredInputs, [.systemDefault])
        XCTAssertEqual(fallbackEngine.startCaptureCount, 1)
    }

    func testFailedCaptureEvictsTheCachedEngineBeforeRetrying() throws {
        let failedEngine = AudioCaptureEngineSpy(startCaptureError: AppStubError.failure)
        let replacementEngine = AudioCaptureEngineSpy()
        let factory = AudioCaptureEngineFactorySpy(engines: [failedEngine, replacementEngine])
        let recorder = AudioRecorder(logger: AppLogStore(), captureEngineFactory: factory)

        XCTAssertThrowsError(try recorder.start(input: .systemDefault))
        try recorder.start(input: .systemDefault)
        recorder.cancel()

        XCTAssertEqual(failedEngine.discardCount, 1)
        XCTAssertEqual(factory.makeCount, 2)
        XCTAssertEqual(replacementEngine.startCaptureCount, 1)
    }

    func testCaptureTapRunsOutsideTheMainActor() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let url = try appTemporaryFile()
        try FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioCaptureWriter(inputFormat: inputFormat, outputURL: url)
        let tap = LiveAudioCaptureEngine.makeCaptureTap(writer: writer)

        let audioQueue = DispatchQueue(label: "AudioRecorderTests.captureTap")
        let completed = expectation(description: "Capture tap completed")
        audioQueue.async {
            dispatchPrecondition(condition: .onQueue(audioQueue))
            dispatchPrecondition(condition: .notOnQueue(.main))
            guard let callbackFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            ), let buffer = AVAudioPCMBuffer(pcmFormat: callbackFormat, frameCapacity: 480) else {
                XCTFail("Expected a valid callback buffer")
                completed.fulfill()
                return
            }
            buffer.frameLength = 480
            tap(buffer, AVAudioTime())
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(writer.finish(), .success)
    }

    func testCaptureWriterConvertsStereoFloatInputToRequiredWAVFormatAndMetersIt() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 480))
        buffer.frameLength = 480
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<480 {
                channels[channel][frame] = 0.5
            }
        }

        let url = try appTemporaryFile()
        try FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioCaptureWriter(inputFormat: inputFormat, outputURL: url)

        writer.append(buffer)

        XCTAssertEqual(writer.averagePower, -6.02, accuracy: 0.05)
        XCTAssertEqual(writer.finish(), .success)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatLinearPCM)
        XCTAssertGreaterThan(file.length, 0)
    }

    func testCaptureWriterPreservesSignalOutsideFirstChannelWhenDownmixing() throws {
        let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder) | 6
        let channelLayout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: layoutTag))
        let inputFormat = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channelLayout: channelLayout
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 480))
        buffer.frameLength = 480
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<480 {
            channels[5][frame] = 0.5
        }

        let url = try appTemporaryFile()
        try FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioCaptureWriter(inputFormat: inputFormat, outputURL: url)

        writer.append(buffer)

        XCTAssertEqual(writer.finish(), .success)
        let file = try AVAudioFile(forReading: url)
        let output = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: output)
        let samples = try XCTUnwrap(output.floatChannelData?.pointee)
        let maximum = (0..<Int(output.frameLength)).reduce(Float.zero) { maximum, frame in
            max(maximum, abs(samples[frame]))
        }
        XCTAssertGreaterThan(maximum, 0.01)
    }

    func testSpeechTrimBoundsKeepOneHundredMillisecondsOfPaddingAndRewriteWAV() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let sourceURL = try appTemporaryFile()
        try FileManager.default.removeItem(at: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let source = try AVAudioFile(forWriting: sourceURL, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
        buffer.frameLength = 32_000
        try source.write(from: buffer)
        source.close()

        let input = try AVAudioFile(forReading: sourceURL)
        let speech = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 16_000), duration: CMTime(seconds: 0.7, preferredTimescale: 16_000))
        let bounds = try XCTUnwrap(AppleSpeechAudioCaptureTrimmer.trimBounds(for: [speech], file: input))

        XCTAssertEqual(bounds.startFrame, 6_400)
        XCTAssertEqual(bounds.endFrame, 20_800)
        let trimmedURL = try AppleSpeechAudioCaptureTrimmer.writeProcessedFile(
            from: input,
            sourceURL: sourceURL,
            plan: AudioCaptureRewritePlan(
                sourceRanges: [bounds.startFrame..<bounds.endFrame],
                insertedSilentFrames: 0
            )
        )
        defer { try? FileManager.default.removeItem(at: trimmedURL) }
        let trimmed = try AVAudioFile(forReading: trimmedURL)
        XCTAssertEqual(trimmed.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(trimmed.fileFormat.channelCount, 1)
        XCTAssertEqual(trimmed.length, 14_400)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testSpeechTrimReducesOnlyInternalPausesLongerThanOneSecond() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let sourceURL = try appTemporaryFile()
        try FileManager.default.removeItem(at: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let source = try AVAudioFile(forWriting: sourceURL, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        try source.write(from: buffer)
        source.close()

        let input = try AVAudioFile(forReading: sourceURL)
        let speech = [
            CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 16_000), duration: CMTime(seconds: 1, preferredTimescale: 16_000)),
            CMTimeRange(start: CMTime(seconds: 4, preferredTimescale: 16_000), duration: CMTime(seconds: 1, preferredTimescale: 16_000))
        ]
        let plan = try XCTUnwrap(AppleSpeechAudioCaptureTrimmer.rewritePlan(
            for: speech,
            file: input,
            removeEdgeSilence: true,
            reduceInternalPauses: true
        ))

        XCTAssertEqual(plan.sourceRanges, [14_400..<32_000, 64_000..<81_600])
        XCTAssertEqual(plan.insertedSilentFrames, 8_000)
        let processedURL = try AppleSpeechAudioCaptureTrimmer.writeProcessedFile(
            from: input,
            sourceURL: sourceURL,
            plan: plan
        )
        defer { try? FileManager.default.removeItem(at: processedURL) }
        XCTAssertEqual(try AVAudioFile(forReading: processedURL).length, 43_200)
    }

}

@MainActor
private final class AudioCaptureEngineFactorySpy: AudioCaptureEngineFactory {
    private var engines: [AudioCaptureEngineSpy]
    private(set) var makeCount = 0

    init(engines: [AudioCaptureEngineSpy]) {
        self.engines = engines
    }

    func makeCaptureEngine() -> any AudioCaptureEngine {
        makeCount += 1
        guard !engines.isEmpty else {
            fatalError("AudioCaptureEngineFactorySpy requires an engine for every creation.")
        }
        return engines.removeFirst()
    }
}

@MainActor
private final class AudioCaptureEngineSpy: AudioCaptureEngine {
    let inputFormat: AVAudioFormat
    let configureError: (any Error)?
    let startCaptureError: (any Error)?

    private(set) var configuredInputs: [AudioInputSelection] = []
    private(set) var startCaptureCount = 0
    private(set) var pauseCaptureCount = 0
    private(set) var discardCount = 0

    init(
        inputFormat: AVAudioFormat? = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ),
        configureError: (any Error)? = nil,
        startCaptureError: (any Error)? = nil
    ) {
        self.inputFormat = inputFormat ?? AVAudioFormat()
        self.configureError = configureError
        self.startCaptureError = startCaptureError
    }

    func configure(input: AudioInputSelection) throws {
        configuredInputs.append(input)
        if let configureError { throw configureError }
    }

    func startCapture(writer: AudioCaptureWriter) throws {
        startCaptureCount += 1
        if let startCaptureError { throw startCaptureError }
    }

    func pauseCapture() {
        pauseCaptureCount += 1
    }

    func discard() {
        discardCount += 1
    }
}
