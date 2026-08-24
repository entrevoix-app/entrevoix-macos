import Foundation
import XCTest
import EntrevoixCore
@testable import Entrevoix

enum AppStubError: LocalizedError, LogSafeError, Equatable, Sendable {
    case failure

    var errorDescription: String? { "Visible app failure" }
    var logMessage: String { "Safe app failure" }
}

@MainActor
final class AppRecorderSpy: AudioRecording {
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
        guard stopURL != nil else { return }
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
final class AppPendingPermissionRecorder: AudioRecording {
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

actor AppAudioCaptureTrimmerSpy: AudioCaptureTrimming {
    private(set) var calls: [(URL, String?)] = []
    var result: AudioCaptureTrimResult

    init(result: AudioCaptureTrimResult) {
        self.result = result
    }

    func trimLeadingAndTrailingSilence(in audioURL: URL, language: String?) async -> AudioCaptureTrimResult {
        calls.append((audioURL, language))
        return result
    }
}

@MainActor
final class AudioInputDeviceCatalogSpy: AudioInputDeviceDiscovering {
    var onInputDevicesChanged: (() -> Void)?
    var currentSnapshot: AudioInputDeviceSnapshot

    init(snapshot: AudioInputDeviceSnapshot = AudioInputDeviceSnapshot(devices: [], defaultDeviceUID: nil)) {
        currentSnapshot = snapshot
    }

    func snapshot() -> AudioInputDeviceSnapshot { currentSnapshot }

    func replaceSnapshot(_ snapshot: AudioInputDeviceSnapshot) {
        currentSnapshot = snapshot
        onInputDevicesChanged?()
    }
}

actor AppTranscriberSpy: SpeechTranscribing {
    struct Call: Sendable {
        let audioURL: URL
        let configuration: ProviderConfiguration
        let apiKey: String
        let prompt: String?
        let language: String?
    }

    var result: Result<String, AppStubError>
    private(set) var calls: [Call] = []

    init(result: Result<String, AppStubError> = .success("connection transcript")) {
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

actor AppControlledTranscriber: SpeechTranscribing {
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

actor AppControlledCleaner: TextCleaning {
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

actor AppSequencedCleaner: TextCleaning {
    struct Call: Sendable {
        let text: String
        let prompt: String
    }

    private var results: [Result<String, AppStubError>]
    private(set) var calls: [Call] = []

    init(results: [Result<String, AppStubError>]) {
        self.results = results
    }

    func clean(
        text: String,
        configuration: ProviderConfiguration,
        apiKey: String,
        format: CleanupAPIFormat,
        prompt: String
    ) async throws -> String {
        calls.append(Call(text: text, prompt: prompt))
        guard !results.isEmpty else { throw AppStubError.failure }
        return try results.removeFirst().get()
    }
}

struct AppCleanerStub: TextCleaning {
    func clean(
        text: String,
        configuration: ProviderConfiguration,
        apiKey: String,
        format: CleanupAPIFormat,
        prompt: String
    ) async throws -> String { text }
}

@MainActor
final class AppDeliverySpy: TextDelivering {
    private(set) var copied: [String] = []
    private(set) var pasted: [String] = []
    private(set) var delivered: [(String, OutputMode)] = []

    func copy(_ text: String) { copied.append(text) }
    func copyAndPaste(_ text: String) { pasted.append(text) }
    func deliver(_ text: String, mode: OutputMode) -> TextDeliveryResult {
        delivered.append((text, mode))
        return mode == .clipboard ? .copied : .inserted
    }
}

final class PreferencesStoreSpy: PreferencesStoring {
    var preferences: AppPreferences
    private(set) var saved: [AppPreferences] = []
    private(set) var resetCount = 0

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
    }

    func load() -> PreferencesLoadResult { .loaded(preferences) }

    func save(_ preferences: AppPreferences) {
        self.preferences = preferences
        saved.append(preferences)
    }

    func reset() { resetCount += 1 }
}

final class SecretStoreSpy: SecretStoring {
    var secrets: [UUID: String]
    var saveError: (any Error)?
    private(set) var readIDs: [UUID] = []
    private(set) var saves: [[UUID: String]] = []

    init(secrets: [UUID: String] = [:]) {
        self.secrets = secrets
    }

    func read(profileIDs: [UUID]) throws -> [UUID: String] {
        readIDs = profileIDs
        return secrets.filter { profileIDs.contains($0.key) }
    }

    func save(_ secrets: [UUID: String]) throws {
        if let saveError { throw saveError }
        self.secrets = secrets
        saves.append(secrets)
    }
}

@MainActor
final class HotkeySpy: HotkeyHandling {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onEscape: (() -> Void)?
}

@MainActor
final class LaunchAtLoginSpy: LaunchAtLoginControlling {
    var isEnabled = false
    var error: (any Error)?
    private(set) var requestedValues: [Bool] = []

    func setEnabled(_ enabled: Bool) throws {
        requestedValues.append(enabled)
        if let error { throw error }
        isEnabled = enabled
    }
}

@MainActor
final class FeedbackSpy: FeedbackPlaying {
    private(set) var events: [FeedbackEvent] = []
    func play(_ event: FeedbackEvent) { events.append(event) }
}

@MainActor
final class ListeningIndicatorSpy: ListeningIndicatorPresenting {
    private(set) var labels: [String] = []
    private(set) var updatedLabels: [String] = []
    private(set) var hideCount = 0

    func show(label: String) { labels.append(label) }
    func update(label: String) { updatedLabels.append(label) }
    func hide() { hideCount += 1 }
}

@MainActor
final class PermissionSpy: PermissionProviding {
    var microphonePermission: PermissionStatus = .notDetermined
    var accessibilityPermission: PermissionStatus = .notDetermined
    var microphoneResult = true
    var holdMicrophoneRequest = false
    var microphoneResetError: MicrophonePermissionResetError?
    private(set) var microphoneResetCount = 0
    private var microphoneContinuations: [CheckedContinuation<Bool, Never>] = []
    private(set) var accessibilityRequestCount = 0

    func requestMicrophonePermission() async -> Bool {
        if holdMicrophoneRequest {
            return await withCheckedContinuation { microphoneContinuations.append($0) }
        }
        return microphoneResult
    }

    func resolveNextMicrophonePermission(_ granted: Bool) {
        guard !microphoneContinuations.isEmpty else { return }
        microphoneContinuations.removeFirst().resume(returning: granted)
        holdMicrophoneRequest = false
    }

    func requestAccessibilityPermission() { accessibilityRequestCount += 1 }

    func resetMicrophonePermission() async throws(MicrophonePermissionResetError) {
        microphoneResetCount += 1
        if let microphoneResetError {
            throw microphoneResetError
        }
        microphonePermission = .notDetermined
    }
}

@MainActor
final class AppDate {
    var value = Date(timeIntervalSince1970: 2_000)
    func advance(by interval: TimeInterval) { value.addTimeInterval(interval) }
}

final class MemoryKeychainAccess: KeychainAccessing, @unchecked Sendable {
    var storage: [String: Data] = [:]
    var readError: (any Error)?
    var upsertError: (any Error)?
    var deleteError: (any Error)?
    private(set) var reads: [(String, String)] = []
    private(set) var upserts: [(String, String)] = []
    private(set) var deletes: [(String, String)] = []

    func read(service: String, account: String) throws -> Data? {
        reads.append((service, account))
        if let readError { throw readError }
        return storage[key(service, account)]
    }

    func upsert(_ data: Data, service: String, account: String) throws {
        upserts.append((service, account))
        if let upsertError { throw upsertError }
        storage[key(service, account)] = data
    }

    func delete(service: String, account: String) throws {
        deletes.append((service, account))
        if let deleteError { throw deleteError }
        storage.removeValue(forKey: key(service, account))
    }

    func seed(_ data: Data, service: String, account: String) {
        storage[key(service, account)] = data
    }

    func data(service: String, account: String) -> Data? {
        storage[key(service, account)]
    }

    private func key(_ service: String, _ account: String) -> String {
        "\(service)|\(account)"
    }
}

actor HTTPStub: HTTPTransporting {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, URLResponse)

    private let handler: Handler
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try handler(request)
    }
}

func response(
    url: URL = URL(string: "https://example.com")!,
    status: Int = 200,
    data: Data = Data()
) -> (Data, URLResponse) {
    (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

func appTemporaryFile(contents: Data = Data("audio".utf8)) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("entrevoix-app-tests-\(UUID().uuidString)")
        .appendingPathExtension("wav")
    try contents.write(to: url)
    return url
}

@MainActor
func appWaitUntil(
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
