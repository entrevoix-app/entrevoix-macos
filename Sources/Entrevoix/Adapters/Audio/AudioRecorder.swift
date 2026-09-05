import AVFoundation
import AudioToolbox
import Dispatch
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
        let engine: any AudioCaptureEngine
        do {
            engine = try captureEngine(for: input)
        } catch {
            logger.log("Audio input selection failed (requested input; no fallback).")
            throw error
        }
        let inputFormat = engine.inputFormat
        guard Self.isSupportedCaptureFormat(inputFormat) else {
            engine.discard()
            preparedEngine = nil
            logger.log("Audio input selection failed (requested input; unsupported source format).")
            throw RecorderError.couldNotStart
        }

        do {
            let writer = try AudioCaptureWriter(inputFormat: inputFormat, outputURL: url)
            try engine.startCapture(writer: writer)
            activeEngine = engine
            captureWriter = writer
            currentURL = url
            logger.log("Audio input selection succeeded (requested input; source \(Self.formatDiagnostic(inputFormat))).")
        } catch {
            engine.discard()
            preparedEngine = nil
            try? FileManager.default.removeItem(at: url)
            logger.log("Audio input capture failed (requested input; source \(Self.formatDiagnostic(inputFormat))).")
            throw error
        }
    }

    private static func isSupportedCaptureFormat(_ format: AVAudioFormat) -> Bool {
        guard format.sampleRate > 0,
              format.channelCount > 0,
              format.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM,
              let floatFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: format.sampleRate,
                  channels: format.channelCount,
                  interleaved: false
              ) else {
            return false
        }
        return AVAudioConverter(from: format, to: floatFormat) != nil
    }

    private static func formatDiagnostic(_ format: AVAudioFormat) -> String {
        let encoding = format.commonFormat == .pcmFormatFloat32 ? "float32" : "linear-pcm"
        return "rate=\(Int(format.sampleRate)) channels=\(format.channelCount) encoding=\(encoding)"
    }

    /// Keep only the selected input's prepared engine to avoid startup latency.
    /// Discarding the previous selection prevents a paused Bluetooth input from
    /// retaining its hands-free profile after the user switches microphones.
    private func captureEngine(for input: AudioInputSelection) throws -> any AudioCaptureEngine {
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
        if result == .failed {
            logger.log("Audio input capture failed (render or writer failure).")
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
    func isReusable(for input: AudioInputSelection) -> Bool
    func startCapture(writer: AudioCaptureWriter) throws
    func pauseCapture()
    func discard()
}

extension AudioCaptureEngine {
    /// Concrete test engines do not observe Core Audio device changes.
    func isReusable(for _: AudioInputSelection) -> Bool { true }
}

@MainActor
protocol AudioCaptureEngineFactory: AnyObject {
    func makeCaptureEngine() -> any AudioCaptureEngine
}

@MainActor
final class LiveAudioCaptureEngineFactory: AudioCaptureEngineFactory {
    func makeCaptureEngine() -> any AudioCaptureEngine {
        HALInputCaptureEngine()
    }
}

@MainActor
final class HALInputCaptureEngine: AudioCaptureEngine {
    private var audioUnit: AudioUnit?
    private var callbackContext: HALInputCaptureContext?
    private var configuredInputFormat: AVAudioFormat?
    private var configuredDeviceID: AudioDeviceID?

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
            let configurator = CoreAudioHALInputConfigurator(audioUnit: audioUnit)
            var configuredContext: HALInputCaptureContext?
            let inputFormat = try Self.configureAUHAL(
                deviceID: deviceID,
                using: configurator
            ) { inputFormat in
                let context = try HALInputCaptureContext(inputFormat: inputFormat, audioUnit: audioUnit)
                configuredContext = context
                return AURenderCallbackStruct(
                    inputProc: halInputCallback,
                    inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
                )
            }
            guard let context = configuredContext else { throw RecorderError.couldNotStart }
            try Self.initialize(audioUnit)

            self.audioUnit = audioUnit
            callbackContext = context
            configuredInputFormat = inputFormat
            configuredDeviceID = deviceID
        } catch {
            AudioComponentInstanceDispose(audioUnit)
            throw error
        }
    }

    func isReusable(for input: AudioInputSelection) -> Bool {
        guard let configuredDeviceID else { return false }
        guard case .systemDefault = input else { return true }
        return configuredDeviceID == Self.defaultInputDeviceID()
    }

    func startCapture(writer: AudioCaptureWriter) throws {
        guard let audioUnit, let callbackContext else {
            throw RecorderError.couldNotStart
        }

        try callbackContext.startCapture(writer: writer)
        let status = AudioOutputUnitStart(audioUnit)
        guard status == noErr else {
            callbackContext.discardCapture()
            throw RecorderError.audioDevice(status)
        }
    }

    func pauseCapture() {
        guard let audioUnit else { return }
        _ = AudioOutputUnitStop(audioUnit)
        callbackContext?.pauseCapture()
    }

    func discard() {
        guard let audioUnit else { return }
        _ = AudioOutputUnitStop(audioUnit)
        callbackContext?.discardCapture()
        _ = AudioUnitUninitialize(audioUnit)
        _ = AudioComponentInstanceDispose(audioUnit)
        self.audioUnit = nil
        callbackContext = nil
        configuredInputFormat = nil
        configuredDeviceID = nil
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

        return audioUnit
    }

    static func configureAUHAL(
        deviceID: AudioDeviceID,
        using configurator: any HALInputAudioUnitConfiguring,
        makeCallback: (AVAudioFormat) throws -> AURenderCallbackStruct
    ) throws -> AVAudioFormat {
        try configurator.setIO(enabled: 1, scope: kAudioUnitScope_Input, element: 1)
        try configurator.setIO(enabled: 0, scope: kAudioUnitScope_Output, element: 0)
        try configurator.setDevice(deviceID, scope: kAudioUnitScope_Global, element: 0)
        let inputFormat = try configurator.inputFormat(scope: kAudioUnitScope_Input, element: 1)
        let clientFormat = try configurator.setClientFormat(inputFormat, scope: kAudioUnitScope_Output, element: 1)
        try configurator.installInputCallback(try makeCallback(clientFormat), scope: kAudioUnitScope_Global, element: 0)
        return clientFormat
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

@MainActor
protocol HALInputAudioUnitConfiguring: AnyObject {
    func setIO(enabled: UInt32, scope: AudioUnitScope, element: AudioUnitElement) throws
    func setDevice(_ deviceID: AudioDeviceID, scope: AudioUnitScope, element: AudioUnitElement) throws
    func inputFormat(scope: AudioUnitScope, element: AudioUnitElement) throws -> AVAudioFormat
    func setClientFormat(_ format: AVAudioFormat, scope: AudioUnitScope, element: AudioUnitElement) throws -> AVAudioFormat
    func installInputCallback(_ callback: AURenderCallbackStruct, scope: AudioUnitScope, element: AudioUnitElement) throws
}

@MainActor
private final class CoreAudioHALInputConfigurator: HALInputAudioUnitConfiguring {
    private let audioUnit: AudioUnit
    private var nativeInputDescription: AudioStreamBasicDescription?

    init(audioUnit: AudioUnit) {
        self.audioUnit = audioUnit
    }

    func setIO(enabled: UInt32, scope: AudioUnitScope, element: AudioUnitElement) throws {
        var enabled = enabled
        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, scope, element, &enabled, UInt32(MemoryLayout<UInt32>.size)))
    }

    func setDevice(_ deviceID: AudioDeviceID, scope: AudioUnitScope, element: AudioUnitElement) throws {
        var deviceID = deviceID
        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, scope, element, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)))
    }

    func inputFormat(scope: AudioUnitScope, element: AudioUnitElement) throws -> AVAudioFormat {
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, scope, element, &description, &size))
        guard description.mSampleRate > 0, description.mChannelsPerFrame > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: description.mSampleRate, channels: description.mChannelsPerFrame, interleaved: false) else {
            throw RecorderError.couldNotStart
        }
        nativeInputDescription = description
        return format
    }

    func setClientFormat(_ format: AVAudioFormat, scope: AudioUnitScope, element: AudioUnitElement) throws -> AVAudioFormat {
        var description = format.streamDescription.pointee
        let status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, scope, element, &description, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status != noErr else { return format }
        guard var nativeInputDescription,
              let nativeFormat = AVAudioFormat(streamDescription: &nativeInputDescription),
              nativeFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
            throw RecorderError.couldNotStart
        }
        try check(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, scope, element, &nativeInputDescription, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
        return nativeFormat
    }

    func installInputCallback(_ callback: AURenderCallbackStruct, scope: AudioUnitScope, element: AudioUnitElement) throws {
        var callback = callback
        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback, scope, element, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw RecorderError.audioDevice(status) }
    }
}

/// Bridges the AUHAL realtime callback to the asynchronous WAV writer.
///
/// `state` serializes the callback with start/stop on the main actor. This is
/// required because `AudioOutputUnitStop` can overlap a final render callback;
/// closing the writer before that callback completes would race the WAV file.
typealias AudioUnitRenderFunction = (
    AudioUnit,
    UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    UnsafePointer<AudioTimeStamp>,
    UInt32,
    UInt32,
    UnsafeMutablePointer<AudioBufferList>
) -> OSStatus

final class HALInputCaptureContext: @unchecked Sendable {
    private static let chunkFrameCapacity: AVAudioFrameCount = 8_192
    private static let pooledChunkCount = 8

    private struct State {
        var writer: AudioCaptureWriter?
        var activeChunk: AudioCaptureBuffer?
    }

    private let audioUnit: AudioUnit
    private let audioUnitRender: AudioUnitRenderFunction
    private let renderBuffer: AVAudioPCMBuffer
    private let chunkPool: AudioCaptureBufferPool
    private let state: Mutex<State>

    init(
        inputFormat: AVAudioFormat,
        audioUnit: AudioUnit,
        audioUnitRender: @escaping AudioUnitRenderFunction = AudioUnitRender
    ) throws {
        self.audioUnit = audioUnit
        self.audioUnitRender = audioUnitRender
        guard let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: Self.chunkFrameCapacity
        ) else {
            throw RecorderError.couldNotStart
        }
        self.renderBuffer = renderBuffer
        chunkPool = try AudioCaptureBufferPool(
            inputFormat: inputFormat,
            frameCapacity: Self.chunkFrameCapacity,
            count: Self.pooledChunkCount
        )
        state = Mutex(State())
    }

    func startCapture(writer: AudioCaptureWriter) throws {
        guard let chunk = chunkPool.checkout() else {
            throw RecorderError.couldNotStart
        }
        let didStart = state.withLock { state in
            guard state.writer == nil, state.activeChunk == nil else { return false }
            state.writer = writer
            state.activeChunk = chunk
            return true
        }
        if !didStart {
            chunkPool.checkin(chunk)
            throw RecorderError.couldNotStart
        }
    }

    func pauseCapture() {
        flushActiveChunk()
    }

    func discardCapture() {
        let activeChunk = state.withLock { state -> AudioCaptureBuffer? in
            state.writer = nil
            defer { state.activeChunk = nil }
            return state.activeChunk
        }
        if let activeChunk {
            chunkPool.checkin(activeChunk)
        }
    }

    func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        state.withLock { state in
            guard let writer = state.writer, let activeChunk = state.activeChunk else {
                return noErr
            }
            let activeBuffer = activeChunk.buffer
            guard renderBuffer.frameCapacity >= frameCount else {
                writer.markFailed()
                return kAudio_ParamError
            }

            // AVAudioPCMBuffer derives each AudioBuffer's mDataByteSize from
            // frameLength. AudioUnitRender needs the writable byte capacity,
            // not an empty buffer, otherwise it rejects the callback with -50.
            renderBuffer.frameLength = frameCount
            let status = audioUnitRender(
                audioUnit,
                actionFlags,
                timeStamp,
                busNumber,
                frameCount,
                renderBuffer.mutableAudioBufferList
            )
            guard status == noErr else {
                writer.markFailed()
                return status
            }

            guard copy(renderBuffer, into: activeBuffer, frameCount: frameCount) else {
                writer.markFailed()
                return noErr
            }
            guard activeBuffer.frameLength == activeBuffer.frameCapacity else {
                return noErr
            }
            guard let nextChunk = chunkPool.checkout() else {
                writer.markFailed()
                state.writer = nil
                state.activeChunk = nil
                chunkPool.checkin(activeChunk)
                return noErr
            }

            state.activeChunk = nextChunk
            enqueue(activeChunk, with: writer)
            return noErr
        }
    }

    private func flushActiveChunk() {
        let pending = state.withLock { state -> (AudioCaptureWriter, AudioCaptureBuffer)? in
            guard let writer = state.writer else { return nil }
            state.writer = nil
            guard let activeChunk = state.activeChunk else { return nil }
            state.activeChunk = nil
            guard activeChunk.buffer.frameLength > 0 else {
                chunkPool.checkin(activeChunk)
                return nil
            }
            return (writer, activeChunk)
        }
        guard let pending else { return }
        enqueue(pending.1, with: pending.0)
    }

    private func enqueue(_ chunk: AudioCaptureBuffer, with writer: AudioCaptureWriter) {
        writer.enqueue(AudioCaptureBufferLease(
            buffer: chunk,
            pool: chunkPool
        ))
    }

    private func copy(
        _ source: AVAudioPCMBuffer,
        into destination: AVAudioPCMBuffer,
        frameCount: AVAudioFrameCount
    ) -> Bool {
        let destinationOffset = destination.frameLength
        guard destination.frameCapacity - destinationOffset >= frameCount,
              source.format == destination.format else {
            return false
        }
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return false }
        let byteCount = Int(frameCount) * Int(source.format.streamDescription.pointee.mBytesPerFrame)
        for (sourceBuffer, destinationBuffer) in zip(sourceBuffers, destinationBuffers) {
            guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData else {
                return false
            }
            memcpy(
                destinationData.advanced(by: Int(destinationOffset) * Int(destination.format.streamDescription.pointee.mBytesPerFrame)),
                sourceData,
                byteCount
            )
        }
        destination.frameLength = destinationOffset + frameCount
        return true
    }
}

/// Wraps an AVAudioPCMBuffer while a single owner has exclusive access to it.
private final class AudioCaptureBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// A bounded pool keeps the realtime callback allocation-free. Each checked
/// out buffer is exclusively owned by either the callback or the writer queue.
private final class AudioCaptureBufferPool: @unchecked Sendable {
    private struct State {
        var available: [AudioCaptureBuffer]
    }

    private let state: Mutex<State>

    init(
        inputFormat: AVAudioFormat,
        frameCapacity: AVAudioFrameCount,
        count: Int
    ) throws {
        var buffers: [AudioCaptureBuffer] = []
        buffers.reserveCapacity(count)
        for _ in 0..<count {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: frameCapacity
            ) else {
                throw RecorderError.couldNotStart
            }
            buffers.append(AudioCaptureBuffer(buffer))
        }
        state = Mutex(State(available: buffers))
    }

    func checkout() -> AudioCaptureBuffer? {
        state.withLock { $0.available.popLast() }
    }

    func checkin(_ buffer: AudioCaptureBuffer) {
        buffer.buffer.frameLength = 0
        state.withLock { $0.available.append(buffer) }
    }
}

/// Holds a pooled non-Sendable AVAudioPCMBuffer while it is exclusively owned
/// by the serial writer queue.
fileprivate final class AudioCaptureBufferLease: @unchecked Sendable {
    let buffer: AudioCaptureBuffer
    private let pool: AudioCaptureBufferPool

    init(buffer: AudioCaptureBuffer, pool: AudioCaptureBufferPool) {
        self.buffer = buffer
        self.pool = pool
    }

    func recycle() {
        pool.checkin(buffer)
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
        let inputConverter: AVAudioConverter?
        let floatInputFormat: AVAudioFormat
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
    private let processingQueue = DispatchQueue(
        label: "com.d9beuD.Entrevoix.audio-capture-writer",
        qos: .userInitiated
    )
    private let pendingWrites = DispatchGroup()

    init(inputFormat: AVAudioFormat, outputURL: URL) throws {
        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              inputFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
            throw RecorderError.couldNotStart
        }

        let floatInputFormat: AVAudioFormat
        let inputConverter: AVAudioConverter?
        if inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved {
            floatInputFormat = inputFormat
            inputConverter = nil
        } else {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inputFormat.sampleRate,
                channels: inputFormat.channelCount,
                interleaved: false
            ), let converter = AVAudioConverter(from: inputFormat, to: format) else {
                throw RecorderError.couldNotStart
            }
            floatInputFormat = format
            inputConverter = converter
        }

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
            inputConverter: inputConverter,
            floatInputFormat: floatInputFormat,
            converter: converter,
            converterInputFormat: converterInputFormat,
            file: file,
            outputFormat: outputFormat
        ))
    }

    var averagePower: Float {
        state.withLock { $0.averagePower }
    }

    /// Called from the realtime callback only after it has filled a pooled
    /// chunk. Conversion and disk I/O then run on this dedicated serial queue.
    fileprivate func enqueue(_ lease: AudioCaptureBufferLease) {
        pendingWrites.enter()
        processingQueue.async { [self] in
            append(lease.buffer.buffer)
            lease.recycle()
            pendingWrites.leave()
        }
    }

    func markFailed() {
        state.withLock { $0.didFail = true }
    }

    func append(_ input: AVAudioPCMBuffer) {
        state.withLock { state in
            guard !state.isFinished, !state.didFail else { return }

            guard let floatInput = Self.floatBuffer(
                from: input,
                converter: state.inputConverter,
                format: state.floatInputFormat
            ), let monoInput = Self.downmixToMono(
                floatInput,
                format: state.converterInputFormat
            ) else {
                state.didFail = true
                return
            }
            state.averagePower = Self.averagePower(for: floatInput)

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
        // `HALInputCaptureContext.pauseCapture()` stops new enqueue operations
        // before this waits, so no work can enter the group after the wait.
        pendingWrites.wait()
        return state.withLock { state -> Result in
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

    private static func floatBuffer(
        from input: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let converter else { return input }
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: input.frameLength) else {
            return nil
        }
        let source = ConverterInputBlockSource(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            source.next(into: inputStatus)
        }
        guard error == nil, status != .error, output.frameLength > 0 else { return nil }
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
