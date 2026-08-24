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
    private struct CaptureEngineKey: Hashable {
        let input: AudioInputSelection
    }

    private var cachedEngines: [CaptureEngineKey: any AudioCaptureEngine] = [:]
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
            try startCapture(
                at: url,
                key: CaptureEngineKey(input: .systemDefault)
            )
            return .requestedInput
        case .device(let device):
            do {
                try startCapture(
                    at: url,
                    key: CaptureEngineKey(input: .device(device))
                )
                return .requestedInput
            } catch {
                try? FileManager.default.removeItem(at: url)
                try startCapture(
                    at: url,
                    key: CaptureEngineKey(input: .systemDefault)
                )
                return .fellBackToSystemDefault
            }
        }
    }

    private func startCapture(
        at url: URL,
        key: CaptureEngineKey
    ) throws {
        let engine = try captureEngine(for: key)
        let inputFormat = engine.inputFormat
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            engine.discard()
            cachedEngines[key] = nil
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
            cachedEngines[key] = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func captureEngine(for key: CaptureEngineKey) throws -> any AudioCaptureEngine {
        if let existing = cachedEngines[key] {
            return existing
        }

        let engine = captureEngineFactory.makeCaptureEngine()
        do {
            try engine.configure(input: key.input)
            cachedEngines[key] = engine
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

/// A narrow internal seam around AVAudioEngine that keeps lifecycle tests
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
    private let engine = AVAudioEngine()
    private let inputNode: AVAudioInputNode
    private var hasInstalledTap = false

    init() {
        inputNode = engine.inputNode
    }

    var inputFormat: AVAudioFormat {
        inputNode.outputFormat(forBus: 0)
    }

    func configure(input: AudioInputSelection) throws {
        guard case .device(let device) = input else { return }
        guard let deviceID = Self.deviceID(forUID: device.uid) else {
            throw RecorderError.inputDeviceUnavailable
        }
        guard let audioUnit = inputNode.audioUnit else {
            throw RecorderError.couldNotStart
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw RecorderError.audioDevice(status) }
    }

    func startCapture(writer: AudioCaptureWriter) throws {
        inputNode.installTap(
            onBus: 0,
            bufferSize: 8_192,
            format: inputFormat,
            block: Self.makeCaptureTap(writer: writer)
        )
        hasInstalledTap = true
        do {
            engine.prepare()
            try engine.start()
        } catch {
            removeTap()
            engine.stop()
            throw error
        }
    }

    func pauseCapture() {
        engine.pause()
        removeTap()
    }

    func discard() {
        engine.stop()
        removeTap()
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

    private func removeTap() {
        guard hasInstalledTap else { return }
        inputNode.removeTap(onBus: 0)
        hasInstalledTap = false
    }

    private nonisolated static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let value = uid as CFString
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: value) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
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
