import Foundation

public enum ConnectionTestFailure: Equatable, Sendable {
    case invalidConfiguration([ProviderValidationIssue])
    case microphonePermissionDenied
    case recordingFailed(message: UserFacingErrorMessage)
    case insufficientAudio
    case noSpeechDetected
    case transcriptionFailed(message: UserFacingErrorMessage)
}

public enum ConnectionTestState: Equatable, Sendable {
    case idle
    case requestingPermission
    case recording
    case testing
    case succeeded(characterCount: Int)
    case failed(ConnectionTestFailure)

    public var isInactive: Bool {
        switch self {
        case .idle, .succeeded, .failed: true
        case .requestingPermission, .recording, .testing: false
        }
    }
}

public enum ConnectionTestEvent: Equatable, Sendable {
    case recordingStarted
    case recordingStopped
    case succeeded
    case failed
}

public struct ConnectionTestSnapshot: Equatable, Sendable {
    public let state: ConnectionTestState

    public init(state: ConnectionTestState) { self.state = state }
}

@MainActor
public final class ConnectionTestCoordinator {
    private let audioRecorder: any AudioRecording
    private let audioCaptureTrimmer: any AudioCaptureTrimming
    private let microphonePermission: any MicrophonePermissionRequesting
    private let transcriber: any SpeechTranscribing
    private let logger: any LogWriting
    private let now: () -> Date
    private let sessionArbiter: (any SessionArbitrating)?

    public private(set) var state: ConnectionTestState = .idle {
        didSet { onSnapshot?(snapshot) }
    }
    public var onEvent: ((ConnectionTestEvent) -> Void)?
    public var onSnapshot: ((ConnectionTestSnapshot) -> Void)? {
        didSet { onSnapshot?(snapshot) }
    }
    public var snapshot: ConnectionTestSnapshot { ConnectionTestSnapshot(state: state) }

    private var sessionID: UUID?
    private var sessionLease: SessionLease?
    private var startedAt: Date?
    private var task: Task<Void, Never>?
    private var trimLeadingAndTrailingSilence = true
    private var reduceLongInternalPauses = false
    private var activeRequest: TranscriptionRequest?

    public convenience init(
        audioRecorder: any AudioRecording,
        audioCaptureTrimmer: any AudioCaptureTrimming = PassthroughAudioCaptureTrimmer(),
        microphonePermission: any MicrophonePermissionRequesting,
        transcriber: any SpeechTranscribing,
        logger: any LogWriting,
        sessionArbiter: (any SessionArbitrating)? = nil
    ) {
        self.init(audioRecorder: audioRecorder, audioCaptureTrimmer: audioCaptureTrimmer, microphonePermission: microphonePermission, transcriber: transcriber, logger: logger, now: Date.init, sessionArbiter: sessionArbiter)
    }

    public init(
        audioRecorder: any AudioRecording,
        audioCaptureTrimmer: any AudioCaptureTrimming = PassthroughAudioCaptureTrimmer(),
        microphonePermission: any MicrophonePermissionRequesting,
        transcriber: any SpeechTranscribing,
        logger: any LogWriting,
        now: @escaping () -> Date,
        sessionArbiter: (any SessionArbitrating)? = nil
    ) {
        self.audioRecorder = audioRecorder
        self.audioCaptureTrimmer = audioCaptureTrimmer
        self.microphonePermission = microphonePermission
        self.transcriber = transcriber
        self.logger = logger
        self.now = now
        self.sessionArbiter = sessionArbiter
    }

    public func start(
        request: TranscriptionRequest? = nil,
        audioInput: AudioInputSelection = .systemDefault,
        trimLeadingAndTrailingSilence: Bool = true,
        reduceLongInternalPauses: Bool = false
    ) {
        guard state.isInactive else { return }
        if let request {
            let issues = request.configuration.validationIssues(apiKey: request.apiKey)
            guard issues.isEmpty else {
                state = .failed(.invalidConfiguration(issues))
                onEvent?(.failed)
                return
            }
        }
        if let sessionArbiter {
            guard let lease = sessionArbiter.acquire(.connectionTest) else { return }
            sessionLease = lease
        }
        let sessionID = UUID()
        self.sessionID = sessionID
        activeRequest = request
        self.trimLeadingAndTrailingSilence = trimLeadingAndTrailingSilence
        self.reduceLongInternalPauses = reduceLongInternalPauses
        state = .requestingPermission
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if let request { try await self.transcriber.preflight(request: request) }
            } catch is CancellationError {
                return
            } catch {
                guard self.sessionID == sessionID else { return }
                self.sessionID = nil
                self.releaseSessionLease()
                self.state = .failed(.transcriptionFailed(message: userFacingMessage(for: error)))
                self.logger.log("Error: connection test preflight: \(safeLogMessage(for: error))")
                self.onEvent?(.failed)
                return
            }
            guard self.sessionID == sessionID else { return }
            guard await self.microphonePermission.requestMicrophonePermission() else {
                guard self.sessionID == sessionID else { return }
                self.sessionID = nil
                self.releaseSessionLease()
                self.state = .failed(.microphonePermissionDenied)
                self.logger.log("Error: connection test: Microphone access was denied. Allow Entrevoix in System Settings.")
                self.onEvent?(.failed)
                return
            }
            guard self.sessionID == sessionID else { return }
            do {
                let startResult = try self.audioRecorder.start(input: audioInput)
                if startResult == .fellBackToSystemDefault {
                    self.logger.log("Selected microphone unavailable; using the macOS default input.")
                }
                self.startedAt = self.now()
                self.state = .recording
                self.logger.log("Connection test recording started")
                self.onEvent?(.recordingStarted)
            } catch {
                self.sessionID = nil
                self.releaseSessionLease()
                self.state = .failed(.recordingFailed(message: userFacingMessage(for: error)))
                self.logger.log("Error: connection test: \(safeLogMessage(for: error))")
                self.onEvent?(.failed)
            }
        }
    }

    public func finish(request: TranscriptionRequest) {
        guard state == .recording, let sessionID else { return }
        let duration = startedAt.map { now().timeIntervalSince($0) } ?? 0
        startedAt = nil
        guard duration >= DictationTiming.minimumRecordingDuration, let audioURL = audioRecorder.stop() else {
            audioRecorder.cancel()
            self.sessionID = nil
            state = .failed(.insufficientAudio)
            onEvent?(.failed)
            releaseSessionLease()
            return
        }
        let request = activeRequest ?? request
        state = .testing
        logger.log("Connection test recording ended")
        onEvent?(.recordingStopped)
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            var captureURL = audioURL
            defer {
                self.audioRecorder.deleteCapture(at: captureURL)
                if self.sessionID == sessionID { self.sessionID = nil }
                self.releaseSessionLease()
                self.activeRequest = nil
            }
            do {
                if self.trimLeadingAndTrailingSilence || self.reduceLongInternalPauses {
                    switch await self.audioCaptureTrimmer.processCapture(
                        in: captureURL,
                        language: request.language,
                        removeEdgeSilence: self.trimLeadingAndTrailingSilence,
                        reduceInternalPauses: self.reduceLongInternalPauses
                    ) {
                    case .unchanged:
                        break
                    case .trimmed(let trimmedURL):
                        captureURL = trimmedURL
                    case .noSpeechDetected:
                        guard self.sessionID == sessionID else { return }
                        self.sessionID = nil
                        self.state = .failed(.noSpeechDetected)
                        self.onEvent?(.failed)
                        return
                    }
                }
                try Task.checkCancellation()
                let host = request.configuration.endpointURL?.host ?? "configured endpoint"
                self.logger.log("Testing STT connection with \(host)")
                let text = try await self.transcriber.transcribe(audioURL: captureURL, request: request)
                guard self.sessionID == sessionID else { return }
                self.state = .succeeded(characterCount: text.count)
                self.logger.log("STT connection test succeeded (\(text.count) chars)")
                self.onEvent?(.succeeded)
            } catch is CancellationError {
                guard self.sessionID == sessionID else { return }
                self.sessionID = nil
                self.state = .idle
            } catch {
                guard self.sessionID == sessionID else { return }
                self.sessionID = nil
                self.state = .failed(.transcriptionFailed(message: userFacingMessage(for: error)))
                self.logger.log("Error: connection test: \(safeLogMessage(for: error))")
                self.onEvent?(.failed)
            }
        }
    }

    public func cancel() {
        sessionID = nil
        task?.cancel()
        task = nil
        startedAt = nil
        activeRequest = nil
        audioRecorder.cancel()
        state = .idle
        releaseSessionLease()
    }

    private func releaseSessionLease() {
        guard let sessionLease else { return }
        sessionArbiter?.release(sessionLease)
        self.sessionLease = nil
    }
}
