import AVFoundation
import AudioToolbox
import EntrevoixCore
import Foundation
import Synchronization

@MainActor
protocol AudioLevelProviding: AnyObject {
    func updateMeters()
    var averagePower: Float { get }
}

/// Records microphone sessions into the application's fixed PCM WAV format.
@MainActor
final class AudioRecorder: AudioRecording, AudioLevelProviding {
    private var preparedEngine: (input: AudioInputSelection, engine: any AudioCaptureEngine)?
    private var activeEngine: (any AudioCaptureEngine)?
    private var captureWriter: AudioCaptureWriter?
    private(set) var currentURL: URL?

    private let logger: any LogWriting
    private let captureEngineFactory: any AudioCaptureEngineFactory

    init(
        logger: any LogWriting,
        captureEngineFactory: any AudioCaptureEngineFactory = LiveAudioCaptureEngineFactory()
    ) {
        self.logger = logger
        self.captureEngineFactory = captureEngineFactory
    }

    @discardableResult
    func start(input: AudioInputSelection) throws -> AudioInputStartResult {
        guard activeEngine == nil else { return .requestedInput }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Entrevoix", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let url = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        switch input {
        case .systemDefault:
            try startCapture(at: url, input: .systemDefault)
            return .requestedInput
        case .device(let device):
            // An explicit choice must not silently open the macOS default
            // input. That default can be a Bluetooth headset, which switches
            // its output into the low-quality conversational profile.
            try startCapture(at: url, input: .device(device))
            return .requestedInput
        }
    }

    private func startCapture(
        at url: URL,
        input: AudioInputSelection
    ) throws {
        let engine = try captureEngine(for: input)
        let inputFormat = engine.inputFormat
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            engine.discard()
            preparedEngine = nil
            throw RecorderError.couldNotStart
        }

        do {
            let writer = try AudioCaptureWriter(inputFormat: inputFormat, outputURL: url)
            try engine.startCapture(writer: writer)
            activeEngine = engine
            captureWriter = writer
            currentURL = url
        } catch {
            engine.discard()
            preparedEngine = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Keep only the selected input's prepared engine to avoid startup latency.
    /// Discarding the previous selection prevents a paused Bluetooth input from
    /// retaining its hands-free profile after the user switches microphones.
    private func captureEngine(for input: AudioInputSelection) throws -> any AudioCaptureEngine {
        if let preparedEngine, preparedEngine.input == input {
            return preparedEngine.engine
        }

        preparedEngine?.engine.discard()
        preparedEngine = nil

        let engine = captureEngineFactory.makeCaptureEngine()
        do {
            try engine.configure(input: input)
            preparedEngine = (input, engine)
            return engine
        } catch {
            engine.discard()
            throw error
        }
    }

    /// Metering is calculated as input buffers arrive; retaining this method
    /// preserves the listening indicator's existing abstraction.
    func updateMeters() {}

    var averagePower: Float {
        captureWriter?.averagePower ?? -160
    }

    func stop() -> URL? {
        let result = finishCapture()
        guard result == .success, let currentURL else { return nil }
        return currentURL
    }

    func cancel() {
        _ = finishCapture()
        if let currentURL {
            try? FileManager.default.removeItem(at: currentURL)
        }
        currentURL = nil
    }

    func deleteLastCapture() {
        guard activeEngine == nil, let currentURL else { return }
        try? FileManager.default.removeItem(at: currentURL)
        self.currentURL = nil
    }

    func captureSize(at url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    func deleteCapture(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        if currentURL == url { currentURL = nil }
    }

    private func finishCapture() -> AudioCaptureWriter.Result {
        guard let activeEngine, let captureWriter else { return .empty }

        activeEngine.pauseCapture()
        self.activeEngine = nil
        self.captureWriter = nil

        let result = captureWriter.finish()
        if result != .success, let currentURL {
            try? FileManager.default.removeItem(at: currentURL)
            self.currentURL = nil
        }
        return result
    }
}

/// A narrow internal seam around microphone capture that keeps lifecycle tests
/// deterministic without introducing an application-layer port.
@MainActor
protocol AudioCaptureEngine: AnyObject {
    var inputFormat: AVAudioFormat { get }

    func configure(input: AudioInputSelection) throws
    func startCapture(writer: AudioCaptureWriter) throws
    func pauseCapture()
    func discard()
}

@MainActor
protocol AudioCaptureEngineFactory: AnyObject {
    func makeCaptureEngine() -> any AudioCaptureEngine
}

@MainActor
final class LiveAudioCaptureEngineFactory: AudioCaptureEngineFactory {
    func makeCaptureEngine() -> any AudioCaptureEngine {
        LiveAudioCaptureEngine()
    }
}

@MainActor
final class LiveAudioCaptureEngine: AudioCaptureEngine {
    private var audioUnit: AudioUnit?
    private var callbackContext: HALInputCaptureContext?
    private var configuredInputFormat: AVAudioFormat?
    private var isInitialized = false

    var inputFormat: AVAudioFormat {
        configuredInputFormat ?? AVAudioFormat()
    }

    /// Configures an input-only AUHAL instance.  In particular, output is
    /// explicitly disabled before a device is attached: AVAudioEngine's input
    /// node is duplex by default and can otherwise make Core Audio aggregate
    /// the selected microphone with the AirPods output device.
    func configure(input: AudioInputSelection) throws {
        discard()

        let deviceID: AudioDeviceID
        switch input {
        case .systemDefault:
            guard let defaultDeviceID = Self.defaultInputDeviceID() else {
                throw RecorderError.inputDeviceUnavailable
            }
            deviceID = defaultDeviceID
        case .device(let device):
            guard let selectedDeviceID = Self.deviceID(forUID: device.uid) else {
                throw RecorderError.inputDeviceUnavailable
            }
            deviceID = selectedDeviceID
        }

        let audioUnit = try Self.makeInputOnlyAudioUnit()
        do {
            try Self.setCurrentDevice(deviceID, on: audioUnit)
            let inputFormat = try Self.configureClientFormat(on: audioUnit)
            let context = HALInputCaptureContext(inputFormat: inputFormat, audioUnit: audioUnit)
            try Self.installInputCallback(context, on: audioUnit)
            try Self.initialize(audioUnit)

            self.audioUnit = audioUnit
            callbackContext = context
            configuredInputFormat = inputFormat
            isInitialized = true
        } catch {
            AudioComponentInstanceDispose(audioUnit)
            throw error
        }
    }

    func startCapture(writer: AudioCaptureWriter) throws {
        guard let audioUnit, let callbackContext, isInitialized else {
            throw RecorderError.couldNotStart
        }

        callbackContext.writer = writer
        let status = AudioOutputUnitStart(audioUnit)
        guard status == noErr else {
            callbackContext.writer = nil
            throw RecorderError.audioDevice(status)
        }
    }

    func pauseCapture() {
        guard let audioUnit else { return }
        _ = AudioOutputUnitStop(audioUnit)
        callbackContext?.writer = nil
    }

    func discard() {
        guard let audioUnit else { return }
        _ = AudioOutputUnitStop(audioUnit)
        callbackContext?.writer = nil
        if isInitialized {
            _ = AudioUnitUninitialize(audioUnit)
        }
        _ = AudioComponentInstanceDispose(audioUnit)
        self.audioUnit = nil
        callbackContext = nil
        configuredInputFormat = nil
        isInitialized = false
    }

    /// AVAudioEngine invokes taps on a realtime queue, so the block must not
    /// inherit this recorder's main-actor isolation.
    nonisolated static func makeCaptureTap(
        writer: AudioCaptureWriter
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            writer.append(buffer)
        }
    }

    private nonisolated static func makeInputOnlyAudioUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw RecorderError.couldNotStart
        }

        var audioUnit: AudioUnit?
        let creationStatus = AudioComponentInstanceNew(component, &audioUnit)
        guard creationStatus == noErr, let audioUnit else {
            throw RecorderError.audioDevice(creationStatus)
        }

        do {
            var enabled: UInt32 = 1
            try check(AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &enabled,
                UInt32(MemoryLayout<UInt32>.size)
            ))

            var disabled: UInt32 = 0
            try check(AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &disabled,
                UInt32(MemoryLayout<UInt32>.size)
            ))
            return audioUnit
        } catch {
            AudioComponentInstanceDispose(audioUnit)
            throw error
        }
    }

    private nonisolated static func setCurrentDevice(
        _ deviceID: AudioDeviceID,
        on audioUnit: AudioUnit
    ) throws {
        var mutableDeviceID = deviceID
        try check(AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ))
    }

    private nonisolated static func configureClientFormat(on audioUnit: AudioUnit) throws -> AVAudioFormat {
        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &deviceFormat,
            &size
        ))
        guard deviceFormat.mSampleRate > 0, deviceFormat.mChannelsPerFrame > 0,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: deviceFormat.mSampleRate,
                  channels: deviceFormat.mChannelsPerFrame,
                  interleaved: false
              ) else {
            throw RecorderError.couldNotStart
        }

        var clientDescription = format.streamDescription.pointee
        try check(AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &clientDescription,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ))
        return format
    }

    private nonisolated static func installInputCallback(
        _ context: HALInputCaptureContext,
        on audioUnit: AudioUnit
    ) throws {
        var callback = AURenderCallbackStruct(
            inputProc: halInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
        )
        try check(AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ))
    }

    private nonisolated static func initialize(_ audioUnit: AudioUnit) throws {
        try check(AudioUnitInitialize(audioUnit))
    }

    private nonisolated static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw RecorderError.audioDevice(status) }
    }

    private nonisolated static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private nonisolated static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceUID = uid as CFString
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &deviceUID) { deviceUIDPointer in
            withUnsafeMutablePointer(to: &deviceID) { deviceIDPointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(mutating: deviceUIDPointer),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: deviceIDPointer,
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &size,
                    &translation
                )
            }
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}

/// The AUHAL input callback is serialized by Core Audio. The recorder changes
/// `writer` only after `AudioOutputUnitStop` has returned, so this object can
/// avoid hopping to the main actor for every audio buffer.
private final class HALInputCaptureContext: @unchecked Sendable {
    private let inputFormat: AVAudioFormat
    private let audioUnit: AudioUnit
    private var inputBuffer: AVAudioPCMBuffer
    var writer: AudioCaptureWriter?

    init(inputFormat: AVAudioFormat, audioUnit: AudioUnit) {
        self.inputFormat = inputFormat
        self.audioUnit = audioUnit
        // 8,192 frames covers the usual Core Audio callback size while keeping
        // the realtime path allocation-free in normal operation.
        inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 8_192)!
    }

    func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        guard let writer else { return noErr }
        if inputBuffer.frameCapacity < frameCount {
            guard let replacement = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: frameCount
            ) else {
                return kAudio_ParamError
            }
            inputBuffer = replacement
        }

        // AVAudioPCMBuffer derives each AudioBuffer's mDataByteSize from its
        // frameLength. AudioUnitRender needs the writable byte capacity, not
        // an empty buffer, otherwise it rejects the callback with -50.
        inputBuffer.frameLength = frameCount
        let status = AudioUnitRender(
            audioUnit,
            actionFlags,
            timeStamp,
            busNumber,
            frameCount,
            inputBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return status }
        writer.append(inputBuffer)
        return noErr
    }
}

/// The callback runs on Core Audio's realtime thread. Its context is held by
/// the engine for the whole initialized lifetime, and stopping the unit
/// synchronously precedes changing its writer.
private func halInputCallback(
    _ refCon: UnsafeMutableRawPointer,
    _ actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timeStamp: UnsafePointer<AudioTimeStamp>,
    _ busNumber: UInt32,
    _ frameCount: UInt32,
    _: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let context = Unmanaged<HALInputCaptureContext>.fromOpaque(refCon).takeUnretainedValue()
    return context.render(
        actionFlags: actionFlags,
        timeStamp: timeStamp,
        busNumber: busNumber,
        frameCount: frameCount
    )
}

/// Synchronizes the realtime engine callback with the main-actor lifecycle.
/// A mutex is necessary here because a tap callback is synchronous and cannot
/// await actor isolation without dispatching work for every audio buffer.
final class AudioCaptureWriter: Sendable {
    enum Result: Equatable {
        case success
        case empty
        case failed
    }

    private struct State {
        let converter: AVAudioConverter
        let converterInputFormat: AVAudioFormat
        let file: AVAudioFile
        let outputFormat: AVAudioFormat
        var averagePower: Float = -160
        var didWriteFrames = false
        var didFail = false
        var isFinished = false
    }

    private let state: Mutex<State>

    init(inputFormat: AVAudioFormat, outputURL: URL) throws {
        guard let converterInputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: converterInputFormat, to: outputFormat) else {
            throw RecorderError.couldNotStart
        }

        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        state = Mutex(State(
            converter: converter,
            converterInputFormat: converterInputFormat,
            file: file,
            outputFormat: outputFormat
        ))
    }

    var averagePower: Float {
        state.withLock { $0.averagePower }
    }

    func append(_ input: AVAudioPCMBuffer) {
        state.withLock { state in
            guard !state.isFinished, !state.didFail else { return }
            state.averagePower = Self.averagePower(for: input)

            guard let monoInput = Self.downmixToMono(
                input,
                format: state.converterInputFormat
            ) else {
                state.didFail = true
                return
            }

            let convertedFrameCount = max(
                Int(monoInput.frameLength),
                Int((Double(monoInput.frameLength) * state.outputFormat.sampleRate / monoInput.format.sampleRate).rounded(.up)) + 32
            )
            guard let output = AVAudioPCMBuffer(
                pcmFormat: state.outputFormat,
                frameCapacity: AVAudioFrameCount(convertedFrameCount)
            ) else {
                state.didFail = true
                return
            }

            let source = ConverterInputBlockSource(monoInput)
            var conversionError: NSError?
            let status = state.converter.convert(to: output, error: &conversionError) { _, inputStatus in
                source.next(into: inputStatus)
            }
            guard conversionError == nil, status != .error, output.frameLength > 0 else {
                state.didFail = true
                return
            }
            do {
                try state.file.write(from: output)
                state.didWriteFrames = true
            } catch {
                state.didFail = true
            }
        }
    }

    func finish() -> Result {
        state.withLock { state in
            guard !state.isFinished else {
                return state.didFail ? .failed : (state.didWriteFrames ? .success : .empty)
            }
            state.isFinished = true
            state.file.close()
            return state.didFail ? .failed : (state.didWriteFrames ? .success : .empty)
        }
    }

    private static func downmixToMono(
        _ input: AVAudioPCMBuffer,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard input.frameLength > 0,
              let inputChannels = input.floatChannelData,
              let output = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: input.frameLength
              ),
              let outputSamples = output.floatChannelData?.pointee else {
            return nil
        }

        output.frameLength = input.frameLength
        let frameCount = Int(input.frameLength)
        let channelCount = Int(input.format.channelCount)
        let scale = 1 / Float(channelCount)
        for frame in 0..<frameCount {
            var mixedSample: Float = 0
            for channel in 0..<channelCount {
                mixedSample += inputChannels[channel][frame]
            }
            outputSamples[frame] = mixedSample * scale
        }
        return output
    }

    private static func averagePower(for buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return -160 }

        var squaredSum: Float = 0
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                let sample = channels[channel][frame]
                squaredSum += sample * sample
            }
        }

        let sampleCount = Float(frameCount * channelCount)
        guard squaredSum > 0, sampleCount > 0 else { return -160 }
        return max(-160, 20 * log10(sqrt(squaredSum / sampleCount)))
    }
}

/// AVAudioConverter invokes this block synchronously while `AudioCaptureWriter`
/// holds its mutex. AVAudioPCMBuffer has no Sendable conformance, so this small
/// wrapper documents the externally synchronized Objective-C boundary rather
/// than leaking an unchecked conformance into the recorder itself.
private final class ConverterInputBlockSource: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var hasProvidedBuffer = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(into status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !hasProvidedBuffer else {
            status.pointee = .noDataNow
            return nil
        }
        hasProvidedBuffer = true
        status.pointee = .haveData
        return buffer
    }
}


enum RecorderError: LocalizedError, LogSafeError, UserFacingErrorProviding {
    case couldNotStart
    case inputDeviceUnavailable
    case audioDevice(OSStatus)

    var errorDescription: String? {
        "Could not start recording. Check microphone permission."
    }

    var userFacingMessage: UserFacingErrorMessage {
        .recordingCouldNotStart
    }

    var logMessage: String {
        switch self {
        case .couldNotStart, .inputDeviceUnavailable:
            "Could not start recording."
        case .audioDevice(let status):
            "Core Audio input selection failed (OSStatus \(status))."
        }
    }
}
