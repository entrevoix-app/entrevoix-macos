import AVFoundation
import AudioToolbox
import CoreMedia
@testable import EntrevoixAppleAdapters
import EntrevoixCore
import Speech
import XCTest
@testable import Entrevoix

@MainActor
final class AudioRecorderTests: XCTestCase {
    func testDeleteCaptureRemovesCompletedWAV() throws {
        let url = try appTemporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = AudioRecorder(logger: AppLogStore(), captureEngineFactory: AudioCaptureEngineFactorySpy(engines: []))

        recorder.deleteCapture(at: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

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

    func testEachSystemDefaultCaptureConfiguresAndUsesANewEngine() throws {
        let firstEngine = AudioCaptureEngineSpy()
        let replacementEngine = AudioCaptureEngineSpy()
        let factory = AudioCaptureEngineFactorySpy(engines: [firstEngine, replacementEngine])
        let recorder = AudioRecorder(logger: AppLogStore(), captureEngineFactory: factory)

        try recorder.start(input: .systemDefault)
        recorder.cancel()
        try recorder.start(input: .systemDefault)
        recorder.cancel()

        XCTAssertEqual(factory.makeCount, 2)
        XCTAssertEqual(firstEngine.configuredInputs, [.systemDefault])
        XCTAssertEqual(firstEngine.startCaptureCount, 1)
        XCTAssertEqual(firstEngine.pauseCaptureCount, 1)
        XCTAssertEqual(firstEngine.discardCount, 1)
        XCTAssertEqual(replacementEngine.configuredInputs, [.systemDefault])
        XCTAssertEqual(replacementEngine.startCaptureCount, 1)
        XCTAssertEqual(replacementEngine.pauseCaptureCount, 1)
    }

    func testSystemDefaultCaptureReplacesEngineEvenWhenPriorEngineReportsReusable() throws {
        let staleEngine = AudioCaptureEngineSpy()
        let replacementEngine = AudioCaptureEngineSpy()
        let factory = AudioCaptureEngineFactorySpy(engines: [staleEngine, replacementEngine])
        let recorder = AudioRecorder(logger: AppLogStore(), captureEngineFactory: factory)

        try recorder.start(input: .systemDefault)
        recorder.cancel()
        try recorder.start(input: .systemDefault)
        recorder.cancel()

        XCTAssertEqual(factory.makeCount, 2)
        XCTAssertEqual(staleEngine.discardCount, 1)
        XCTAssertEqual(replacementEngine.configuredInputs, [.systemDefault])
    }

    func testAUHALConfigurationUsesRequiredCoreAudioOrderScopesBusesAndDevice() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let configurator = HALInputAudioUnitConfiguratorSpy(inputFormat: format)

        _ = try HALInputCaptureEngine.configureAUHAL(deviceID: 42, using: configurator) { _ in
            AURenderCallbackStruct(inputProc: nil, inputProcRefCon: nil)
        }

        XCTAssertEqual(configurator.operations, [
            .io(enabled: 1, scope: kAudioUnitScope_Input, element: 1),
            .io(enabled: 0, scope: kAudioUnitScope_Output, element: 0),
            .device(42, scope: kAudioUnitScope_Global, element: 0),
            .readFormat(scope: kAudioUnitScope_Input, element: 1),
            .writeFormat(scope: kAudioUnitScope_Output, element: 1),
            .callback(scope: kAudioUnitScope_Global, element: 0)
        ])
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
        XCTAssertEqual(systemEngine.discardCount, 1)
        XCTAssertEqual(selectedEngine.configuredInputs, [.device(selectedInput)])
    }

    func testUnavailableSelectedInputDiscardsItsEngineWithoutFallingBackToSystemDefault() throws {
        let unavailableEngine = AudioCaptureEngineSpy(configureError: AppStubError.failure)
        let factory = AudioCaptureEngineFactorySpy(engines: [unavailableEngine])
        let recorder = AudioRecorder(logger: AppLogStore(), captureEngineFactory: factory)
        let selectedInput = AudioInputDeviceReference(uid: "missing-device", name: "Missing microphone")

        XCTAssertThrowsError(try recorder.start(input: .device(selectedInput)))

        XCTAssertEqual(unavailableEngine.configuredInputs, [.device(selectedInput)])
        XCTAssertEqual(unavailableEngine.discardCount, 1)
    }

    func testFailedCaptureDiscardsItsEngineBeforeRetrying() throws {
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

    func testCaptureWriterNormalizesNativeBluetoothInt16AndFloatSourcesToRequiredWAVFormat() throws {
        let int16Source = try makeInt16Buffer(sampleRate: 24_000)
        let int16URL = try appTemporaryFile()
        try FileManager.default.removeItem(at: int16URL)
        defer { try? FileManager.default.removeItem(at: int16URL) }
        let int16Writer = try AudioCaptureWriter(inputFormat: int16Source.format, outputURL: int16URL)

        int16Writer.append(int16Source)

        XCTAssertEqual(int16Writer.finish(), .success)
        try assertRequiredWAVFormat(at: int16URL)

        let floatSource = try makeFloatBuffer(sampleRate: 48_000)
        let floatURL = try appTemporaryFile()
        try FileManager.default.removeItem(at: floatURL)
        defer { try? FileManager.default.removeItem(at: floatURL) }
        let floatWriter = try AudioCaptureWriter(inputFormat: floatSource.format, outputURL: floatURL)

        floatWriter.append(floatSource)

        XCTAssertEqual(floatWriter.finish(), .success)
        try assertRequiredWAVFormat(at: floatURL)
    }

    func testRecorderAcceptsSigned24BitLittleEndianInterleavedPCMAndNormalizesItToRequiredWAV() throws {
        let buffer = try makePCMBuffer(
            sampleRate: 48_000,
            channels: 2,
            bitsPerChannel: 24,
            formatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            interleaved: true,
            bytes: [0x00, 0x00, 0x40, 0x00, 0x00, 0x40]
        )

        try assertRecorderNormalizesNativeCapture(buffer)
    }

    func testRecorderAcceptsUnsigned8BitPCMAndNormalizesItToRequiredWAV() throws {
        let buffer = try makePCMBuffer(
            sampleRate: 22_050,
            channels: 1,
            bitsPerChannel: 8,
            formatFlags: kAudioFormatFlagIsPacked,
            interleaved: true,
            bytes: [0xE0]
        )

        try assertRecorderNormalizesNativeCapture(buffer)
    }

    func testRecorderAcceptsSigned32BitBigEndianNonInterleavedPCMAndNormalizesItToRequiredWAV() throws {
        let buffer = try makePCMBuffer(
            sampleRate: 44_100,
            channels: 2,
            bitsPerChannel: 32,
            formatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsBigEndian
                | kAudioFormatFlagIsNonInterleaved,
            interleaved: false,
            bytes: [0x40, 0x00, 0x00, 0x00]
        )

        try assertRecorderNormalizesNativeCapture(buffer)
    }

    func testRecorderRejectsInvalidNativeFormatsWithoutPartialWAVOrSystemDefaultFallback() throws {
        let selectedInput = AudioInputDeviceReference(uid: "dji-mini-input", name: "DJI Mini")
        let invalidRateAndChannelEngine = AudioCaptureEngineSpy(inputFormat: AVAudioFormat())
        let recorder = AudioRecorder(
            logger: AppLogStore(),
            captureEngineFactory: AudioCaptureEngineFactorySpy(engines: [invalidRateAndChannelEngine])
        )

        XCTAssertThrowsError(try recorder.start(input: .device(selectedInput))) { error in
            guard case RecorderError.couldNotStart = error else {
                return XCTFail("Expected invalid rate or channel count to be rejected as couldNotStart.")
            }
        }
        XCTAssertNil(recorder.currentURL)
        XCTAssertEqual(invalidRateAndChannelEngine.configuredInputs, [.device(selectedInput)])
        recorder.cancel()
    }

    func testRecorderRejectsNonPCMNativeFormatWithoutStartingCapture() throws {
        let format = try makeAudioFormat(
            formatID: kAudioFormatMPEG4AAC,
            formatFlags: 0,
            bitsPerChannel: 0,
            bytesPerFrame: 0
        )
        let engine = AudioCaptureEngineSpy(inputFormat: format)
        let recorder = AudioRecorder(
            logger: AppLogStore(),
            captureEngineFactory: AudioCaptureEngineFactorySpy(engines: [engine])
        )

        XCTAssertThrowsError(try recorder.start(input: .systemDefault))

        XCTAssertNil(recorder.currentURL)
        XCTAssertEqual(engine.startCaptureCount, 0)
        XCTAssertEqual(engine.discardCount, 1)
    }

    func testRecorderRejectsNonconvertibleLinearPCMNativeFormatWithoutStartingCapture() throws {
        let format = try makeAudioFormat(
            formatID: kAudioFormatLinearPCM,
            formatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            bitsPerChannel: 12,
            bytesPerFrame: 2
        )
        let floatFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: format.channelCount,
            interleaved: false
        ))
        XCTAssertNil(AVAudioConverter(from: format, to: floatFormat))
        let engine = AudioCaptureEngineSpy(inputFormat: format)
        let recorder = AudioRecorder(
            logger: AppLogStore(),
            captureEngineFactory: AudioCaptureEngineFactorySpy(engines: [engine])
        )

        XCTAssertThrowsError(try recorder.start(input: .systemDefault))

        XCTAssertNil(recorder.currentURL)
        XCTAssertEqual(engine.startCaptureCount, 0)
        XCTAssertEqual(engine.discardCount, 1)
    }

    func testExplicitUIDSelectionCapturesItsNativeInputAndMissingUIDNeverOpensSystemDefault() throws {
        let selectedInput = AudioInputDeviceReference(uid: "dji-mini-input", name: "DJI Mini")
        let selectedEngine = NativeFormatCaptureEngine(buffer: try makeInt16Buffer(sampleRate: 24_000))
        let unavailableEngine = AudioCaptureEngineSpy(configureError: RecorderError.inputDeviceUnavailable)
        let recorder = AudioRecorder(
            logger: AppLogStore(),
            captureEngineFactory: AudioCaptureEngineFactorySpy(engines: [selectedEngine, unavailableEngine])
        )

        try recorder.start(input: .device(selectedInput))
        let captureURL = recorder.stop()

        XCTAssertNotNil(captureURL)
        if let captureURL {
            defer { try? FileManager.default.removeItem(at: captureURL) }
            try assertRequiredWAVFormat(at: captureURL)
        }

        let missingInput = AudioInputDeviceReference(uid: "missing-dji-mini", name: "Missing DJI Mini")
        XCTAssertThrowsError(try recorder.start(input: .device(missingInput)))
        XCTAssertEqual(unavailableEngine.configuredInputs, [.device(missingInput)])
    }

    func testSelectedDJIMiniUIDSurvivesNativeFormatChangesAndNormalizesEveryCapture() throws {
        let selectedInput = AudioInputDeviceReference(uid: "dji-mini-input", name: "DJI Mini")
        let int16Engine = NativeFormatCaptureEngine(buffer: try makeInt16Buffer(sampleRate: 24_000))
        let floatEngine = NativeFormatCaptureEngine(buffer: try makeFloatBuffer(sampleRate: 48_000))
        let factory = AudioCaptureEngineFactorySpy(engines: [int16Engine, floatEngine])
        let recorder = AudioRecorder(
            logger: AppLogStore(),
            captureEngineFactory: factory
        )

        try recorder.start(input: .device(selectedInput))
        let int16URL = recorder.stop()
        XCTAssertNotNil(int16URL)
        if let int16URL {
            defer { try? FileManager.default.removeItem(at: int16URL) }
            try assertRequiredWAVFormat(at: int16URL)
        }

        try recorder.start(input: .device(selectedInput))
        let floatURL = recorder.stop()
        XCTAssertNotNil(floatURL)
        if let floatURL {
            defer { try? FileManager.default.removeItem(at: floatURL) }
            try assertRequiredWAVFormat(at: floatURL)
        }
        XCTAssertEqual(factory.makeCount, 2)
        XCTAssertEqual(int16Engine.configuredInputs, [.device(selectedInput)])
        XCTAssertEqual(floatEngine.configuredInputs, [.device(selectedInput)])
    }

    func testAUHALRenderFailureMarksCaptureWriterAsFailed() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let url = try appTemporaryFile()
        try FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let audioUnit = try makeGenericOutputAudioUnit()
        defer { AudioComponentInstanceDispose(audioUnit) }
        let writer = try AudioCaptureWriter(inputFormat: format, outputURL: url)
        let context = try HALInputCaptureContext(
            inputFormat: format,
            audioUnit: audioUnit,
            audioUnitRender: { _, _, _, _, _, _ in kAudio_ParamError }
        )
        try context.startCapture(writer: writer)
        var flags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()

        let status = withUnsafeMutablePointer(to: &flags) { flags in
            withUnsafePointer(to: &timestamp) { timestamp in
                context.render(
                    actionFlags: flags,
                    timeStamp: timestamp,
                    busNumber: 1,
                    frameCount: 480
                )
            }
        }

        XCTAssertEqual(status, kAudio_ParamError)
        context.pauseCapture()
        XCTAssertEqual(writer.finish(), .failed)
    }

    func testRecorderLogsOnlySafeSelectionAndNativeFormatDiagnosticsForSuccessAndFailure() throws {
        let secretUID = "dji-mini-uid-SECRET-123"
        let transcript = "private transcript"
        let providerBody = #"{\"api_key\":\"secret\"}"#
        let logger = LogWritingSpy()
        let successfulEngine = AudioCaptureEngineSpy()
        let failedEngine = AudioCaptureEngineSpy(configureError: RecorderError.inputDeviceUnavailable)
        let recorder = AudioRecorder(
            logger: logger,
            captureEngineFactory: AudioCaptureEngineFactorySpy(engines: [successfulEngine, failedEngine])
        )

        try recorder.start(input: .device(AudioInputDeviceReference(uid: secretUID, name: "DJI Mini")))
        recorder.cancel()
        let unavailableUID = "missing-dji-mini-uid-SECRET-456"
        XCTAssertThrowsError(try recorder.start(input: .device(AudioInputDeviceReference(uid: unavailableUID, name: "Missing DJI Mini"))))

        let diagnostics = logger.messages.joined(separator: "\n")
        XCTAssertTrue(diagnostics.localizedCaseInsensitiveContains("selection"))
        XCTAssertTrue(diagnostics.contains("48000"))
        XCTAssertTrue(diagnostics.localizedCaseInsensitiveContains("float"))
        XCTAssertTrue(diagnostics.localizedCaseInsensitiveContains("failed"))
        XCTAssertFalse(diagnostics.contains(secretUID))
        XCTAssertFalse(diagnostics.contains(unavailableUID))
        XCTAssertFalse(diagnostics.contains(transcript))
        XCTAssertFalse(diagnostics.contains(providerBody))
    }

    func testSpeechTrimBoundsKeepTwoHundredMillisecondsOfPaddingAndRewriteWAV() throws {
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

        XCTAssertEqual(bounds.startFrame, 4_800)
        XCTAssertEqual(bounds.endFrame, 22_400)
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
        XCTAssertEqual(trimmed.length, 17_600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    private func makeInt16Buffer(sampleRate: Double) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        buffer.frameLength = 240
        let samples = try XCTUnwrap(buffer.int16ChannelData?.pointee)
        for frame in 0..<240 {
            samples[frame] = 8_192
        }
        return buffer
    }

    private func makeFloatBuffer(sampleRate: Double) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let samples = try XCTUnwrap(buffer.floatChannelData?.pointee)
        for frame in 0..<480 {
            samples[frame] = 0.25
        }
        return buffer
    }

    private func makePCMBuffer(
        sampleRate: Double,
        channels: UInt32,
        bitsPerChannel: UInt32,
        formatFlags: UInt32,
        interleaved: Bool,
        bytes: [UInt8]
    ) throws -> AVAudioPCMBuffer {
        let bytesPerSample = bitsPerChannel / 8
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: formatFlags,
            mBytesPerPacket: interleaved ? bytesPerSample * channels : bytesPerSample,
            mFramesPerPacket: 1,
            mBytesPerFrame: interleaved ? bytesPerSample * channels : bytesPerSample,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bitsPerChannel,
            mReserved: 0
        )
        let format = try XCTUnwrap(AVAudioFormat(streamDescription: &description))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480

        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            let destination = try XCTUnwrap(audioBuffer.mData)
            let sampleCount = Int(audioBuffer.mDataByteSize) / bytes.count
            for sample in 0..<sampleCount {
                bytes.withUnsafeBytes { source in
                    destination.advanced(by: sample * bytes.count).copyMemory(
                        from: source.baseAddress!,
                        byteCount: bytes.count
                    )
                }
            }
        }
        return buffer
    }

    private func makeAudioFormat(
        formatID: AudioFormatID,
        formatFlags: UInt32,
        bitsPerChannel: UInt32,
        bytesPerFrame: UInt32
    ) throws -> AVAudioFormat {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: formatID,
            mFormatFlags: formatFlags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: 1,
            mBitsPerChannel: bitsPerChannel,
            mReserved: 0
        )
        return try XCTUnwrap(AVAudioFormat(streamDescription: &description))
    }

    private func makeGenericOutputAudioUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_GenericOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let component = try XCTUnwrap(AudioComponentFindNext(nil, &description))
        var audioUnit: AudioUnit?
        XCTAssertEqual(AudioComponentInstanceNew(component, &audioUnit), noErr)
        return try XCTUnwrap(audioUnit)
    }

    private func assertRecorderNormalizesNativeCapture(_ buffer: AVAudioPCMBuffer) throws {
        let engine = NativeFormatCaptureEngine(buffer: buffer)
        let recorder = AudioRecorder(
            logger: AppLogStore(),
            captureEngineFactory: AudioCaptureEngineFactorySpy(engines: [engine])
        )

        try recorder.start(input: .systemDefault)
        let captureURL = try XCTUnwrap(recorder.stop())
        defer { try? FileManager.default.removeItem(at: captureURL) }
        try assertRequiredWAVFormat(at: captureURL)

        let file = try AVAudioFile(forReading: captureURL)
        let output = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: output)
        let samples = try XCTUnwrap(output.floatChannelData?.pointee)
        let peak = (0..<Int(output.frameLength)).reduce(Float.zero) { peak, frame in
            max(peak, abs(samples[frame]))
        }
        XCTAssertGreaterThan(peak, 0.01)
    }

    private func assertRequiredWAVFormat(at url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let description = file.fileFormat.streamDescription.pointee

        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(description.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(description.mBitsPerChannel, 16)
        XCTAssertEqual(description.mBytesPerFrame, 2)
        XCTAssertEqual(description.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0)
        XCTAssertGreaterThan(file.length, 0)
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

        XCTAssertEqual(plan.sourceRanges, [12_800..<32_000, 64_000..<83_200])
        XCTAssertEqual(plan.insertedSilentFrames, 8_000)
        let processedURL = try AppleSpeechAudioCaptureTrimmer.writeProcessedFile(
            from: input,
            sourceURL: sourceURL,
            plan: plan
        )
        defer { try? FileManager.default.removeItem(at: processedURL) }
        XCTAssertEqual(try AVAudioFile(forReading: processedURL).length, 46_400)
    }

}

@MainActor
private final class AudioCaptureEngineFactorySpy: AudioCaptureEngineFactory {
    private var engines: [any AudioCaptureEngine]
    private(set) var makeCount = 0

    init(engines: [any AudioCaptureEngine]) {
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
    let isReusableResult: Bool

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
        startCaptureError: (any Error)? = nil,
        isReusableResult: Bool = true
    ) {
        self.inputFormat = inputFormat ?? AVAudioFormat()
        self.configureError = configureError
        self.startCaptureError = startCaptureError
        self.isReusableResult = isReusableResult
    }

    func configure(input: AudioInputSelection) throws {
        configuredInputs.append(input)
        if let configureError { throw configureError }
    }

    func startCapture(writer: AudioCaptureWriter) throws {
        startCaptureCount += 1
        if let startCaptureError { throw startCaptureError }
    }

    func isReusable(for input: AudioInputSelection) -> Bool {
        isReusableResult
    }

    func pauseCapture() {
        pauseCaptureCount += 1
    }

    func discard() {
        discardCount += 1
    }
}

@MainActor
private final class HALInputAudioUnitConfiguratorSpy: HALInputAudioUnitConfiguring {
    enum Operation: Equatable {
        case io(enabled: UInt32, scope: AudioUnitScope, element: AudioUnitElement)
        case device(AudioDeviceID, scope: AudioUnitScope, element: AudioUnitElement)
        case readFormat(scope: AudioUnitScope, element: AudioUnitElement)
        case writeFormat(scope: AudioUnitScope, element: AudioUnitElement)
        case callback(scope: AudioUnitScope, element: AudioUnitElement)
    }

    let sourceFormat: AVAudioFormat
    private(set) var operations: [Operation] = []

    init(inputFormat: AVAudioFormat) {
        sourceFormat = inputFormat
    }

    func setIO(enabled: UInt32, scope: AudioUnitScope, element: AudioUnitElement) throws {
        operations.append(.io(enabled: enabled, scope: scope, element: element))
    }

    func setDevice(_ deviceID: AudioDeviceID, scope: AudioUnitScope, element: AudioUnitElement) throws {
        operations.append(.device(deviceID, scope: scope, element: element))
    }

    func inputFormat(scope: AudioUnitScope, element: AudioUnitElement) throws -> AVAudioFormat {
        operations.append(.readFormat(scope: scope, element: element))
        return sourceFormat
    }

    func setClientFormat(_ format: AVAudioFormat, scope: AudioUnitScope, element: AudioUnitElement) throws -> AVAudioFormat {
        operations.append(.writeFormat(scope: scope, element: element))
        return format
    }

    func installInputCallback(_ callback: AURenderCallbackStruct, scope: AudioUnitScope, element: AudioUnitElement) throws {
        operations.append(.callback(scope: scope, element: element))
    }
}

@MainActor
private final class NativeFormatCaptureEngine: AudioCaptureEngine {
    private var nextCapture: AVAudioPCMBuffer
    private(set) var configuredInputs: [AudioInputSelection] = []

    init(buffer: AVAudioPCMBuffer) {
        nextCapture = buffer
    }

    var inputFormat: AVAudioFormat { nextCapture.format }

    func configure(input: AudioInputSelection) throws {
        configuredInputs.append(input)
    }

    func startCapture(writer: AudioCaptureWriter) throws {
        writer.append(nextCapture)
    }

    func pauseCapture() {}

    func discard() {}

}

@MainActor
private final class LogWritingSpy: LogWriting {
    private(set) var messages: [String] = []

    func log(_ message: String) {
        messages.append(message)
    }
}
