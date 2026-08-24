import Foundation
import XCTest
import EntrevoixCore
@testable import Entrevoix

final class ConnectionTestCoordinatorTests: XCTestCase {
    @MainActor
    func testInvalidConfigurationFailsBeforePermissionOrCapture() async {
        let recorder = AppRecorderSpy()
        let model = ConnectionTestCoordinator(
            audioRecorder: recorder, microphonePermission: PermissionSpy(),
            transcriber: AppTranscriberSpy(), logger: AppLogStore(), now: Date.init
        )
        let request = TranscriptionRequest(
            configuration: ProviderConfiguration(name: "Invalid", baseURL: "", path: "responses", model: ""),
            apiKey: "", prompt: nil, language: nil
        )

        model.start(request: request)

        XCTAssertEqual(model.state, .failed(.invalidConfiguration([.invalidEndpoint, .missingModel, .missingAPIKey])))
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertEqual(recorder.cancelCount, 0)
    }

    @MainActor
    func testPermissionDeniedProducesTypedFailureAndEvent() async {
        let recorder = AppRecorderSpy()
        let permissions = PermissionSpy()
        permissions.microphoneResult = false
        let logStore = AppLogStore()
        let model = ConnectionTestCoordinator(
            audioRecorder: recorder,
            microphonePermission: permissions,
            transcriber: AppTranscriberSpy(),
            logger: logStore,
            now: Date.init
        )
        var events: [ConnectionTestEvent] = []
        model.onEvent = { events.append($0) }

        model.start()
        await appWaitUntil("permission failure") { model.state.isInactive }

        XCTAssertEqual(model.state, .failed(.microphonePermissionDenied))
        XCTAssertEqual(events, [.failed])
        XCTAssertTrue(logStore.entries.contains { $0.message.contains("Microphone access was denied") })
    }

    @MainActor
    func testConnectionTestForwardsSelectedAudioInputAndLogsFallback() async {
        let recorder = AppRecorderSpy()
        recorder.startResult = .fellBackToSystemDefault
        let logStore = AppLogStore()
        let model = ConnectionTestCoordinator(
            audioRecorder: recorder,
            microphonePermission: PermissionSpy(),
            transcriber: AppTranscriberSpy(),
            logger: logStore,
            now: Date.init
        )
        let input = AudioInputSelection.device(.init(uid: "usb-mic", name: "USB Microphone"))

        model.start(audioInput: input)
        await appWaitUntil("recording") { model.state == .recording }

        XCTAssertEqual(recorder.startedInputs, [input])
        XCTAssertTrue(logStore.entries.contains { $0.message == "Selected microphone unavailable; using the macOS default input." })
        model.cancel()
    }

    @MainActor
    func testSuccessfulConnectionForwardsRequestAndCleansCapture() async throws {
        let recorder = AppRecorderSpy()
        let audioURL = try appTemporaryFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        recorder.stopURL = audioURL
        let transcriber = AppTranscriberSpy(result: .success("verified"))
        let permissions = PermissionSpy()
        let clock = AppDate()
        let model = ConnectionTestCoordinator(
            audioRecorder: recorder,
            microphonePermission: permissions,
            transcriber: transcriber,
            logger: AppLogStore(),
            now: { clock.value }
        )
        var events: [ConnectionTestEvent] = []
        model.onEvent = { events.append($0) }
        let request = TranscriptionRequest(
            configuration: .openAITranscription,
            apiKey: "secret",
            prompt: "prompt",
            language: "fr"
        )

        model.start()
        await appWaitUntil("recording") { model.state == .recording }
        clock.advance(by: 1)
        model.finish(request: request)
        await appWaitUntil("connection success") { model.state.isInactive }

        XCTAssertEqual(model.state, .succeeded(characterCount: 8))
        let calls = await transcriber.calls
        XCTAssertEqual(calls.first?.apiKey, "secret")
        XCTAssertEqual(calls.first?.prompt, "prompt")
        XCTAssertEqual(calls.first?.language, "fr")
        XCTAssertEqual(recorder.deleteCount, 1)
        XCTAssertEqual(events, [.recordingStarted, .recordingStopped, .succeeded])
    }

    @MainActor
    func testNoSpeechCaptureDoesNotReachTheConnectionTestTranscriber() async throws {
        let recorder = AppRecorderSpy()
        recorder.stopURL = try appTemporaryFile()
        let trimmer = AppAudioCaptureTrimmerSpy(result: .noSpeechDetected)
        let transcriber = AppTranscriberSpy()
        let clock = AppDate()
        let model = ConnectionTestCoordinator(
            audioRecorder: recorder,
            audioCaptureTrimmer: trimmer,
            microphonePermission: PermissionSpy(),
            transcriber: transcriber,
            logger: AppLogStore(),
            now: { clock.value }
        )

        model.start()
        await appWaitUntil("recording") { model.state == .recording }
        clock.advance(by: 1)
        model.finish(request: TranscriptionRequest(configuration: .openAITranscription, apiKey: "secret", prompt: nil, language: "fr"))
        await appWaitUntil("no speech") { model.state == .failed(.noSpeechDetected) }

        let trimCallCount = await trimmer.calls.count
        let transcriptionCalls = await transcriber.calls
        XCTAssertEqual(trimCallCount, 1)
        XCTAssertTrue(transcriptionCalls.isEmpty)
        XCTAssertEqual(recorder.deleteCount, 1)
    }

    @MainActor
    func testTranscriptionFailureIsTypedAndSafe() async throws {
        let recorder = AppRecorderSpy()
        recorder.stopURL = try appTemporaryFile()
        let clock = AppDate()
        let model = ConnectionTestCoordinator(
            audioRecorder: recorder,
            microphonePermission: PermissionSpy(),
            transcriber: AppTranscriberSpy(result: .failure(.failure)),
            logger: AppLogStore(),
            now: { clock.value }
        )

        model.start()
        await appWaitUntil("recording") { model.state == .recording }
        clock.advance(by: 1)
        model.finish(request: TranscriptionRequest(configuration: .openAITranscription, apiKey: "", prompt: nil, language: nil))
        await appWaitUntil("connection failure") { model.state.isInactive }

        XCTAssertEqual(model.state, .failed(.transcriptionFailed(message: "Visible app failure")))
    }
}
