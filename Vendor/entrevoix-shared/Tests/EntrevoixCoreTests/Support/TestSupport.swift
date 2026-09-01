import Foundation
import XCTest
@testable import EntrevoixCore

enum StubError: LocalizedError, LogSafeError, Sendable {
    case failure

    var errorDescription: String? { "Visible failure" }
    var logMessage: String { "Safe failure" }
}

@MainActor
final class RecorderSpy: AudioRecording {
    var startError: (any Error)?
    var startResult: AudioInputStartResult = .requestedInput
    var stopURL: URL?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var deleteCount = 0
    private(set) var startedInputs: [AudioInputSelection] = []

    @discardableResult
    func start(input: AudioInputSelection) throws -> AudioInputStartResult {
        startCount += 1
        startedInputs.append(input)
        if let startError { throw startError }
        return startResult
    }

    func stop() -> URL? {
        stopCount += 1
        return stopURL
    }

    func cancel() { cancelCount += 1 }
    func deleteLastCapture() {
        deleteCount += 1
        stopURL = nil
    }
    func captureSize(at url: URL) -> Int { 0 }
    func deleteCapture(at url: URL) {
        deleteCount += 1
        try? FileManager.default.removeItem(at: url)
        if stopURL == url { stopURL = nil }
    }
}

@MainActor
final class PendingPermissionRecorder: AudioRecording {
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    @discardableResult
    func start(input: AudioInputSelection) throws -> AudioInputStartResult {
        startCount += 1
        return .requestedInput
    }
    func stop() -> URL? { nil }
    func cancel() { cancelCount += 1 }
    func deleteLastCapture() {}
    func captureSize(at url: URL) -> Int { 0 }
    func deleteCapture(at url: URL) {}
}

actor AudioCaptureTrimmerSpy: AudioCaptureTrimming {
    struct Call: Sendable {
        let audioURL: URL
        let language: String?
        let removeEdgeSilence: Bool
        let reduceInternalPauses: Bool
    }

    private(set) var calls: [Call] = []
    var result: AudioCaptureTrimResult

    init(result: AudioCaptureTrimResult) {
        self.result = result
    }

    func processCapture(
        in audioURL: URL,
        language: String?,
        removeEdgeSilence: Bool,
        reduceInternalPauses: Bool
    ) async -> AudioCaptureTrimResult {
        calls.append(Call(
            audioURL: audioURL,
            language: language,
            removeEdgeSilence: removeEdgeSilence,
            reduceInternalPauses: reduceInternalPauses
        ))
        return result
    }
}

@MainActor
final class PermissionSpy: MicrophonePermissionRequesting {
    var permission = true

    func requestMicrophonePermission() async -> Bool {
        return permission
    }
}

@MainActor
final class PendingPermissionProvider: MicrophonePermissionRequesting {
    private var continuation: CheckedContinuation<Bool, Never>?

    func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation = $0 }
    }

    func resolvePermission(_ granted: Bool) {
        continuation?.resume(returning: granted)
        continuation = nil
    }
}

struct TestLogEntry: Equatable, Sendable {
    let message: String
}

@MainActor
final class TestLogStore: LogWriting {
    private(set) var entries: [TestLogEntry] = []

    func log(_ message: String) {
        entries.append(TestLogEntry(message: message))
    }
}

actor TranscriberSpy: SpeechTranscribing {
    struct Call: Sendable {
        let audioURL: URL
        let configuration: ProviderConfiguration
        let apiKey: String
        let prompt: String?
        let language: String?
    }

    private let result: Result<String, StubError>
    private(set) var calls: [Call] = []

    init(result: Result<String, StubError> = .success("raw transcript")) {
        self.result = result
    }

    func transcribe(
        audioURL: URL,
        configuration: ProviderConfiguration,
        apiKey: String,
        prompt: String?,
        language: String?
    ) async throws -> String {
        calls.append(Call(
            audioURL: audioURL,
            configuration: configuration,
            apiKey: apiKey,
            prompt: prompt,
            language: language
        ))
        return try result.get()
    }
}

actor ControlledTranscriber: SpeechTranscribing {
    private var continuation: CheckedContinuation<String, Never>?
    private(set) var callCount = 0

    func transcribe(
        audioURL: URL,
        configuration: ProviderConfiguration,
        apiKey: String,
        prompt: String?,
        language: String?
    ) async throws -> String {
        callCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func succeed(with text: String) {
        continuation?.resume(returning: text)
        continuation = nil
    }
}

actor CleanerSpy: TextCleaning {
    struct Call: Sendable {
        let text: String
        let configuration: ProviderConfiguration
        let apiKey: String
        let format: CleanupAPIFormat
        let prompt: String
    }

    private let result: Result<String, StubError>
    private(set) var calls: [Call] = []

    init(result: Result<String, StubError> = .success("clean transcript")) {
        self.result = result
    }

    func clean(
        text: String,
        configuration: ProviderConfiguration,
        apiKey: String,
        format: CleanupAPIFormat,
        prompt: String
    ) async throws -> String {
        calls.append(Call(
            text: text,
            configuration: configuration,
            apiKey: apiKey,
            format: format,
            prompt: prompt
        ))
        return try result.get()
    }
}

actor SequencedCleanerSpy: TextCleaning {
    private var results: [Result<String, StubError>]
    private(set) var calls: [CleanerSpy.Call] = []

    init(results: [Result<String, StubError>]) {
        self.results = results
    }

    func clean(
        text: String,
        configuration: ProviderConfiguration,
        apiKey: String,
        format: CleanupAPIFormat,
        prompt: String
    ) async throws -> String {
        calls.append(CleanerSpy.Call(
            text: text,
            configuration: configuration,
            apiKey: apiKey,
            format: format,
            prompt: prompt
        ))
        guard !results.isEmpty else { throw StubError.failure }
        return try results.removeFirst().get()
    }
}

actor ControlledCleaner: TextCleaning {
    private var continuation: CheckedContinuation<String, Never>?
    private(set) var callCount = 0

    func clean(
        text: String,
        configuration: ProviderConfiguration,
        apiKey: String,
        format: CleanupAPIFormat,
        prompt: String
    ) async throws -> String {
        callCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func succeed(with text: String) {
        continuation?.resume(returning: text)
        continuation = nil
    }
}

@MainActor
final class DeliverySpy: TextDelivering {
    var result: TextDeliveryResult = .copied
    private(set) var copiedTexts: [String] = []
    private(set) var pastedTexts: [String] = []
    private(set) var deliveries: [(String, OutputMode)] = []

    func copy(_ text: String) { copiedTexts.append(text) }
    func copyAndPaste(_ text: String) { pastedTexts.append(text) }

    func deliver(_ text: String, mode: OutputMode) -> TextDeliveryResult {
        deliveries.append((text, mode))
        return result
    }
}

@MainActor
final class MutableDate {
    var value = Date(timeIntervalSince1970: 1_000)
    func advance(by interval: TimeInterval) { value.addTimeInterval(interval) }
}

@MainActor
func waitUntil(
    _ description: String,
    iterations: Int = 1_000,
    condition: @escaping @MainActor () async -> Bool
) async {
    for _ in 0..<iterations {
        if await condition() { return }
        await Task.yield()
    }
    XCTFail("Timed out waiting for \(description)")
}

func temporaryAudioFile(contents: Data = Data("audio".utf8)) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("entrevoix-tests-\(UUID().uuidString)")
        .appendingPathExtension("wav")
    try contents.write(to: url)
    return url
}

let testSTTConfiguration = ProviderConfiguration(
    name: "Test STT",
    baseURL: "https://stt.example.com/v1",
    path: "audio/transcriptions",
    model: "test-model"
)

@MainActor
func stopCoordinator(
    _ coordinator: DictationCoordinator,
    cleanupEnabled: Bool = false,
    cleanupFailurePolicy: CleanupFailurePolicy = .useRawTranscript,
    outputMode: OutputMode = .clipboard
) {
    coordinator.stopRecording(request: DictationRequest(
        transcription: TranscriptionRequest(
            configuration: testSTTConfiguration,
            apiKey: "stt-secret",
            prompt: "prompt",
            language: "fr"
        ),
        cleanup: cleanupEnabled ? CleanupPlan(
            configuration: .openAIResponses,
            apiKey: "cleanup-secret",
            format: .responses,
            failurePolicy: cleanupFailurePolicy,
            kind: .prompt,
            steps: [CleanupStep(promptID: UUID(), promptName: "Clean", prompt: "clean it")]
        ) : nil,
        outputMode: outputMode
    ))
}

func testDictationRequest(cleanup: CleanupPlan?) -> DictationRequest {
    DictationRequest(
        transcription: TranscriptionRequest(
            configuration: testSTTConfiguration,
            apiKey: "stt-secret",
            prompt: "prompt",
            language: "fr"
        ),
        cleanup: cleanup,
        outputMode: .clipboard
    )
}
