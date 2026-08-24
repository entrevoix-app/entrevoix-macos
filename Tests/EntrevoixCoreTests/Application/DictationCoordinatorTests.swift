import Foundation
import XCTest
@testable import EntrevoixCore

final class DictationCoordinatorTests: XCTestCase {
    @MainActor
    func testPermissionDeniedAndErrorDismissal() async {
        let recorder = RecorderSpy()
        let permission = PermissionSpy()
        permission.permission = false
        let context = makeContext(recorder: recorder, permission: permission)

        context.coordinator.startRecording()
        await waitUntil("permission failure") { context.coordinator.state != .requestingPermission }

        XCTAssertEqual(
            context.coordinator.state,
            .error(.microphonePermissionDenied)
        )
        XCTAssertTrue(context.logs.entries.last?.message.hasPrefix("Error: Microphone access") == true)
        context.coordinator.startRecording()
        XCTAssertNotEqual(context.coordinator.state, .requestingPermission)
        context.coordinator.dismissError()
        XCTAssertEqual(context.coordinator.state, .idle)
        context.coordinator.dismissError()
        XCTAssertEqual(context.coordinator.state, .idle)
    }

    @MainActor
    func testCancelWhilePermissionIsPendingIgnoresLateGrant() async {
        let recorder = RecorderSpy()
        let permission = PendingPermissionProvider()
        let context = makeContext(recorder: recorder, permission: permission)

        context.coordinator.startRecording()
        XCTAssertEqual(context.coordinator.state, .requestingPermission)
        await Task.yield()
        context.coordinator.cancelRecording()
        permission.resolvePermission(true)
        await Task.yield()

        XCTAssertEqual(context.coordinator.state, .idle)
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertEqual(recorder.cancelCount, 1)
    }

    @MainActor
    func testRecorderStartFailureUsesSafeLog() async {
        let recorder = RecorderSpy()
        recorder.startError = StubError.failure
        let context = makeContext(recorder: recorder)

        context.coordinator.startRecording()
        await waitUntil("start error") { context.coordinator.state != .requestingPermission }

        XCTAssertEqual(context.coordinator.state, .error(.recordingFailed(message: "Visible failure")))
        XCTAssertEqual(context.logs.entries.last?.message, "Error: Safe failure")
    }

    @MainActor
    func testRecordingStartsWithoutAudioProcessingOptions() async {
        let recorder = RecorderSpy()
        let context = makeContext(recorder: recorder)
        let request = DictationRequest(
            transcription: TranscriptionRequest(
                configuration: testSTTConfiguration,
                apiKey: "stt-secret",
                prompt: "prompt",
                language: "fr"
            ),
            cleanup: nil,
            outputMode: .clipboard
        )

        context.coordinator.startRecording(request: request)
        await waitUntil("recording") { context.coordinator.state == .recording }

        context.coordinator.cancelRecording()
    }

    @MainActor
    func testNoSpeechCaptureDoesNotReachTheTranscriber() async throws {
        let recorder = RecorderSpy()
        recorder.stopURL = try temporaryAudioFile()
        let trimmer = AudioCaptureTrimmerSpy(result: .noSpeechDetected)
        let transcriber = TranscriberSpy()
        let context = makeContext(recorder: recorder, transcriber: transcriber, trimmer: trimmer)

        context.coordinator.startRecording()
        await waitUntil("recording") { context.coordinator.state == .recording }
        context.clock.advance(by: 1)
        context.coordinator.stopRecording(request: testRequest())
        await waitUntil("no speech") {
            context.coordinator.state == .error(.noSpeechDetected)
        }

        let trimCallCount = await trimmer.calls.count
        let transcriptionCalls = await transcriber.calls
        XCTAssertEqual(trimCallCount, 1)
        XCTAssertTrue(transcriptionCalls.isEmpty)
        XCTAssertEqual(recorder.deleteCount, 1)
    }

    @MainActor
    func testTrimmedCaptureIsSentToTheTranscriber() async throws {
        let recorder = RecorderSpy()
        let originalURL = try temporaryAudioFile()
        let trimmedURL = try temporaryAudioFile()
        recorder.stopURL = originalURL
        let trimmer = AudioCaptureTrimmerSpy(result: .trimmed(trimmedURL))
        let transcriber = TranscriberSpy()
        let context = makeContext(recorder: recorder, transcriber: transcriber, trimmer: trimmer)

        context.coordinator.startRecording()
        await waitUntil("recording") { context.coordinator.state == .recording }
        context.clock.advance(by: 1)
        context.coordinator.stopRecording(request: testRequest())
        await waitUntil("completion") { context.coordinator.state == .idle }

        let transcriptionCalls = await transcriber.calls
        XCTAssertEqual(transcriptionCalls.first?.audioURL, trimmedURL)
        XCTAssertEqual(recorder.deleteCount, 1)
    }

    @MainActor
    func testDisabledSilenceTrimmingBypassesTheTrimmer() async throws {
        let recorder = RecorderSpy()
        recorder.stopURL = try temporaryAudioFile()
        let trimmer = AudioCaptureTrimmerSpy(result: .noSpeechDetected)
        let context = makeContext(recorder: recorder, trimmer: trimmer)
        let request = testRequest()

        context.coordinator.startRecording(
            request: request,
            trimLeadingAndTrailingSilence: false
        )
        await waitUntil("recording") { context.coordinator.state == .recording }
        context.clock.advance(by: 1)
        context.coordinator.stopRecording(request: request)
        await waitUntil("completion") { context.coordinator.state == .idle }

        let trimCallCount = await trimmer.calls.count
        XCTAssertEqual(trimCallCount, 0)
    }

    @MainActor
    func testRecordingForwardsTheFrozenAudioInputToTheRecorder() async {
        let recorder = RecorderSpy()
        let context = makeContext(recorder: recorder)
        let input = AudioInputSelection.device(.init(uid: "usb-mic", name: "USB Microphone"))

        context.coordinator.startRecording(audioInput: input)
        await waitUntil("recording") { context.coordinator.state == .recording }

        XCTAssertEqual(recorder.startedInputs, [input])
        context.coordinator.cancelRecording()
    }

    @MainActor
    func testAudioInputFallbackIsLoggedWithoutDeviceDetails() async {
        let recorder = RecorderSpy()
        recorder.startResult = .fellBackToSystemDefault
        let context = makeContext(recorder: recorder)

        context.coordinator.startRecording(audioInput: .device(.init(uid: "private-uid", name: "Private Mic")))
        await waitUntil("recording") { context.coordinator.state == .recording }

        XCTAssertTrue(context.logs.entries.contains { $0.message == "Selected microphone unavailable; using the macOS default input." })
        XCTAssertFalse(context.logs.entries.contains { $0.message.contains("private-uid") || $0.message.contains("Private Mic") })
        context.coordinator.cancelRecording()
    }

    @MainActor
    func testShortRecordingIsCancelledWithoutTranscription() async {
        let recorder = RecorderSpy()
        let transcriber = TranscriberSpy()
        let context = makeContext(recorder: recorder, transcriber: transcriber)

        context.coordinator.startRecording()
        await waitUntil("recording") { context.coordinator.state == .recording }
        stopCoordinator(context.coordinator)

        XCTAssertEqual(context.coordinator.state, .idle)
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertEqual(recorder.stopCount, 0)
        let calls = await transcriber.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(context.logs.entries.contains { $0.message.contains("less than 250 ms") })
    }

    @MainActor
    func testMissingAudioFileEntersError() async {
        let recorder = RecorderSpy()
        let context = makeContext(recorder: recorder)

        context.coordinator.startRecording()
        await waitUntil("recording") { context.coordinator.state == .recording }
        context.clock.advance(by: 1)
        stopCoordinator(context.coordinator)

        XCTAssertEqual(context.coordinator.state, .error(.audioUnavailable))
        XCTAssertEqual(recorder.stopCount, 1)
    }

    @MainActor
    func testSuccessfulTranscriptionForwardsArgumentsDeletesAudioAndCallsHooks() async throws {
        let recorder = RecorderSpy()
        let audioURL = try temporaryAudioFile()
        recorder.stopURL = audioURL
        let transcriber = TranscriberSpy(result: .success("Hello Entrevoix"))
        let cleaner = CleanerSpy()
        let delivery = DeliverySpy()
        let context = makeContext(recorder: recorder, transcriber: transcriber, cleaner: cleaner, delivery: delivery)
        var started = 0
        var stopped = 0
        context.coordinator.onRecordingStarted = { started += 1 }
        context.coordinator.onRecordingStopped = { stopped += 1 }

        context.coordinator.startRecording()
        await waitUntil("recording") { context.coordinator.state == .recording }
        context.clock.advance(by: 1)
        stopCoordinator(context.coordinator, outputMode: .paste)
        await waitUntil("delivery") { context.coordinator.state == .idle }

        let calls = await transcriber.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].configuration, testSTTConfiguration)
        XCTAssertEqual(calls[0].apiKey, "stt-secret")
        XCTAssertEqual(calls[0].prompt, "prompt")
        XCTAssertEqual(calls[0].language, "fr")
        XCTAssertEqual(delivery.deliveries.first?.0, "Hello Entrevoix")
        XCTAssertEqual(delivery.deliveries.first?.1, .paste)
        XCTAssertEqual(context.coordinator.lastTranscript, "Hello Entrevoix")
        let cleanerCalls = await cleaner.calls
        XCTAssertTrue(cleanerCalls.isEmpty)
        XCTAssertEqual(started, 1)
        XCTAssertEqual(stopped, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertNil(context.coordinator.lastAudioURL)
    }

    @MainActor
    func testCleanupSuccessUsesEnhancedText() async throws {
        let recorder = RecorderSpy()
        recorder.stopURL = try temporaryAudioFile()
        let cleaner = CleanerSpy(result: .success("cleaned"))
        let delivery = DeliverySpy()
        let context = makeContext(recorder: recorder, cleaner: cleaner, delivery: delivery)

        await recordAndStop(context, cleanupEnabled: true)

        XCTAssertEqual(context.coordinator.lastTranscript, "cleaned")
        XCTAssertEqual(delivery.deliveries.first?.0, "cleaned")
        let calls = await cleaner.calls
        XCTAssertEqual(calls.first?.text, "raw transcript")
        XCTAssertEqual(calls.first?.apiKey, "cleanup-secret")
        XCTAssertEqual(calls.first?.prompt, "clean it")
    }

    @MainActor
    func testCleanupFailureCanUseRawTranscriptOrStop() async throws {
        for policy in [CleanupFailurePolicy.useRawTranscript, .stop] {
            let recorder = RecorderSpy()
            recorder.stopURL = try temporaryAudioFile()
            let cleaner = CleanerSpy(result: .failure(.failure))
            let delivery = DeliverySpy()
            let context = makeContext(recorder: recorder, cleaner: cleaner, delivery: delivery)

            await recordAndStop(context, cleanupEnabled: true, cleanupFailurePolicy: policy)

            XCTAssertEqual(context.coordinator.lastTranscript, "raw transcript")
            if policy == .useRawTranscript {
                XCTAssertEqual(context.coordinator.state, .idle)
                XCTAssertEqual(delivery.deliveries.count, 1)
                XCTAssertTrue(context.logs.entries.contains { $0.message.contains("Using raw transcription") })
            } else {
                XCTAssertEqual(context.coordinator.state, .error(.cleanupFailed(message: "Visible failure")))
                XCTAssertTrue(delivery.deliveries.isEmpty)
            }
            XCTAssertFalse(context.logs.entries.contains { $0.message.contains("cleanup-secret") })
        }
    }

    @MainActor
    func testWorkflowRunsEachPromptSequentiallyWithProgressAndSafeLogs() async throws {
        let recorder = RecorderSpy()
        recorder.stopURL = try temporaryAudioFile()
        let cleaner = SequencedCleanerSpy(results: [.success("first result"), .success("second result")])
        let delivery = DeliverySpy()
        let context = makeContext(recorder: recorder, cleaner: cleaner, delivery: delivery)
        let first = CleanupStep(promptID: UUID(), promptName: "Clean", prompt: "secret prompt one")
        let second = CleanupStep(promptID: UUID(), promptName: "Professional", prompt: "secret prompt two")
        let plan = workflowPlan(name: "Publish", steps: [first, second])
        var progress: [(Int, Int)] = []
        context.coordinator.onEvent = { event in
            if case .cleanupStepStarted(let current, let total) = event {
                progress.append((current, total))
            }
        }

        await recordAndStop(context, request: testDictationRequest(cleanup: plan))

        let calls = await cleaner.calls
        XCTAssertEqual(calls.map(\.text), ["raw transcript", "first result"])
        XCTAssertEqual(calls.map(\.prompt), ["secret prompt one", "secret prompt two"])
        XCTAssertEqual(progress.map { "\($0.0)/\($0.1)" }, ["1/2", "2/2"])
        XCTAssertEqual(delivery.deliveries.first?.0, "second result")
        XCTAssertEqual(context.coordinator.state, .idle)
        XCTAssertTrue(context.logs.entries.contains { $0.message.contains("Workflow Publish step 1/2 completed") })
        XCTAssertTrue(context.logs.entries.contains { $0.message.contains("Workflow Publish completed") })
        XCTAssertFalse(context.logs.entries.contains { $0.message.contains("raw transcript") || $0.message.contains("secret prompt") || $0.message.contains("first result") })
    }

    @MainActor
    func testWorkflowFailureDeliversLastSuccessfulResultAndReportsFailingStep() async throws {
        let recorder = RecorderSpy()
        recorder.stopURL = try temporaryAudioFile()
        let cleaner = SequencedCleanerSpy(results: [.success("first result"), .failure(.failure)])
        let delivery = DeliverySpy()
        let context = makeContext(recorder: recorder, cleaner: cleaner, delivery: delivery)
        let plan = workflowPlan(name: "Publish", steps: [
            CleanupStep(promptID: UUID(), promptName: "Clean", prompt: "secret prompt one"),
            CleanupStep(promptID: UUID(), promptName: "Professional", prompt: "secret prompt two"),
            CleanupStep(promptID: UUID(), promptName: "Never reached", prompt: "secret prompt three")
        ])

        await recordAndStop(context, request: testDictationRequest(cleanup: plan))

        let calls = await cleaner.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(delivery.deliveries.first?.0, "first result")
        XCTAssertEqual(context.coordinator.lastTranscript, "first result")
        XCTAssertEqual(
            context.coordinator.state,
            .error(.cleanupWorkflowFailed(step: 2, promptName: "Professional", message: "Visible failure"))
        )
        XCTAssertTrue(context.logs.entries.contains { $0.message.contains("Workflow Publish step 2/3 failed") })
        XCTAssertFalse(context.logs.entries.contains { $0.message.contains("first result") || $0.message.contains("secret prompt") })
    }

    @MainActor
    func testFirstWorkflowFailureDeliversRawTranscript() async throws {
        let recorder = RecorderSpy()
        recorder.stopURL = try temporaryAudioFile()
        let cleaner = SequencedCleanerSpy(results: [.failure(.failure)])
        let delivery = DeliverySpy()
        let context = makeContext(recorder: recorder, cleaner: cleaner, delivery: delivery)
        let plan = workflowPlan(name: "Publish", steps: [
            CleanupStep(promptID: UUID(), promptName: "Clean", prompt: "secret prompt")
        ])

        await recordAndStop(context, request: testDictationRequest(cleanup: plan))

        XCTAssertEqual(delivery.deliveries.first?.0, "raw transcript")
        XCTAssertEqual(
            context.coordinator.state,
            .error(.cleanupWorkflowFailed(step: 1, promptName: "Clean", message: "Visible failure"))
        )
    }

    @MainActor
    func testTranscriptionFailureIsSafeAndDeletesAudio() async throws {
        let recorder = RecorderSpy()
        let audioURL = try temporaryAudioFile()
        recorder.stopURL = audioURL
        let transcriber = TranscriberSpy(result: .failure(.failure))
        let context = makeContext(recorder: recorder, transcriber: transcriber)

        await recordAndStop(context)

        XCTAssertEqual(context.coordinator.state, .error(.transcriptionFailed(message: "Visible failure")))
        XCTAssertEqual(context.logs.entries.last?.message, "Error: Safe failure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    @MainActor
    func testCancellationIgnoresLateTranscriptionAndDeletesAudio() async throws {
        let recorder = RecorderSpy()
        let audioURL = try temporaryAudioFile()
        recorder.stopURL = audioURL
        let transcriber = ControlledTranscriber()
        let delivery = DeliverySpy()
        let context = makeContext(recorder: recorder, transcriber: transcriber, delivery: delivery)

        context.coordinator.startRecording()
        await waitUntil("recording") { context.coordinator.state == .recording }
        context.clock.advance(by: 1)
        stopCoordinator(context.coordinator)
        await waitUntil("transcriber call") { await transcriber.callCount == 1 }
        context.coordinator.cancelRecording()
        await transcriber.succeed(with: "late secret transcript")
        await waitUntil("audio deletion") { !FileManager.default.fileExists(atPath: audioURL.path) }

        XCTAssertEqual(context.coordinator.state, .idle)
        XCTAssertTrue(delivery.deliveries.isEmpty)
        XCTAssertFalse(context.logs.entries.contains { $0.message.contains("late secret transcript") })
    }

    @MainActor
    func testWorkflowCancellationStopsBeforeTheNextStepAndDeletesAudio() async throws {
        let recorder = RecorderSpy()
        let audioURL = try temporaryAudioFile()
        recorder.stopURL = audioURL
        let cleaner = ControlledCleaner()
        let delivery = DeliverySpy()
        let context = makeContext(recorder: recorder, cleaner: cleaner, delivery: delivery)
        let plan = workflowPlan(name: "Publish", steps: [
            CleanupStep(promptID: UUID(), promptName: "Clean", prompt: "secret prompt one"),
            CleanupStep(promptID: UUID(), promptName: "Professional", prompt: "secret prompt two")
        ])

        context.coordinator.startRecording()
        await waitUntil("recording") { context.coordinator.state == .recording }
        context.clock.advance(by: 1)
        context.coordinator.stopRecording(request: testDictationRequest(cleanup: plan))
        await waitUntil("first workflow request") { await cleaner.callCount == 1 }

        context.coordinator.cancelRecording()
        await cleaner.succeed(with: "late intermediate result")
        await waitUntil("audio deletion") { !FileManager.default.fileExists(atPath: audioURL.path) }

        XCTAssertEqual(context.coordinator.state, .idle)
        XCTAssertTrue(delivery.deliveries.isEmpty)
        XCTAssertFalse(context.logs.entries.contains { $0.message.contains("late intermediate result") })
    }

    @MainActor
    func testDeliveryResultsProduceExpectedLogs() async throws {
        let cases: [(TextDeliveryResult, String)] = [
            (.copied, "Delivered transcription to clipboard"),
            (.inserted, "Inserted transcription in active field"),
            (.fallbackCopied(reason: "denied"), "Automatic insertion unavailable; copied to clipboard (denied)"),
            (.secureFieldCopied, "Secure field detected; copied to clipboard")
        ]

        for (result, expectedLog) in cases {
            let recorder = RecorderSpy()
            recorder.stopURL = try temporaryAudioFile()
            let delivery = DeliverySpy()
            delivery.result = result
            let context = makeContext(recorder: recorder, delivery: delivery)
            await recordAndStop(context)
            XCTAssertTrue(context.logs.entries.contains { $0.message == expectedLog })
        }
    }

    @MainActor
    func testWatchdogAndDeleteLastCapture() async {
        let recorder = RecorderSpy()
        let context = makeContext(recorder: recorder, sleep: { _ in })
        var timeoutCount = 0
        context.coordinator.onRecordingTimeout = { timeoutCount += 1 }

        context.coordinator.startRecording()
        await waitUntil("watchdog") { timeoutCount == 1 }
        context.coordinator.deleteLastCapture()

        XCTAssertEqual(recorder.deleteCount, 1)
        context.coordinator.cancelRecording()
    }

    @MainActor
    private func recordAndStop(
        _ context: Context,
        cleanupEnabled: Bool = false,
        cleanupFailurePolicy: CleanupFailurePolicy = .useRawTranscript
    ) async {
        context.coordinator.startRecording()
        await waitUntil("recording") { context.coordinator.state == .recording }
        context.clock.advance(by: 1)
        stopCoordinator(
            context.coordinator,
            cleanupEnabled: cleanupEnabled,
            cleanupFailurePolicy: cleanupFailurePolicy
        )
        await waitUntil("terminal state") {
            context.coordinator.state == .idle || {
                if case .error = context.coordinator.state { return true }
                return false
            }()
        }
    }

    @MainActor
    private func recordAndStop(_ context: Context, request: DictationRequest) async {
        context.coordinator.startRecording()
        await waitUntil("recording") { context.coordinator.state == .recording }
        context.clock.advance(by: 1)
        context.coordinator.stopRecording(request: request)
        await waitUntil("terminal state") {
            context.coordinator.state == .idle || {
                if case .error = context.coordinator.state { return true }
                return false
            }()
        }
    }

    private func testRequest() -> DictationRequest {
        DictationRequest(
            transcription: TranscriptionRequest(
                configuration: testSTTConfiguration,
                apiKey: "stt-secret",
                prompt: nil,
                language: "fr"
            ),
            cleanup: nil,
            outputMode: .clipboard
        )
    }

    private func workflowPlan(name: String, steps: [CleanupStep]) -> CleanupPlan {
        CleanupPlan(
            configuration: .openAIResponses,
            apiKey: "cleanup-secret",
            format: .responses,
            failurePolicy: .stop,
            kind: .workflow(id: UUID(), name: name),
            steps: steps
        )
    }

    @MainActor
    private func makeContext(
        recorder: any AudioRecording = RecorderSpy(),
        transcriber: any SpeechTranscribing = TranscriberSpy(),
        cleaner: any TextCleaning = CleanerSpy(),
        trimmer: any AudioCaptureTrimming = PassthroughAudioCaptureTrimmer(),
        delivery: DeliverySpy = DeliverySpy(),
        permission: any MicrophonePermissionRequesting = PermissionSpy(),
        sleep: @escaping (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) -> Context {
        let clock = MutableDate()
        let logs = TestLogStore()
        let dependencies = DictationDependencies(
            audioRecorder: recorder,
            audioCaptureTrimmer: trimmer,
            microphonePermission: permission,
            textDelivery: delivery,
            transcriber: transcriber,
            cleaner: cleaner,
            logger: logs
        )
        return Context(
            coordinator: DictationCoordinator(
                dependencies: dependencies,
                now: { clock.value },
                sleep: sleep
            ),
            clock: clock,
            logs: logs,
            delivery: delivery
        )
    }
}

@MainActor
private struct Context {
    let coordinator: DictationCoordinator
    let clock: MutableDate
    let logs: TestLogStore
    let delivery: DeliverySpy
}
