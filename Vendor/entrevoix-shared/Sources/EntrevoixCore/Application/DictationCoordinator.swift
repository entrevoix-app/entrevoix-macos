import Foundation

@MainActor
public final class DictationCoordinator {
    public private(set) var state: DictationState = .idle {
        didSet { onSnapshot?(snapshot) }
    }
    public private(set) var lastAudioURL: URL? {
        didSet { onSnapshot?(snapshot) }
    }
    public private(set) var lastTranscript: String? {
        didSet { onSnapshot?(snapshot) }
    }

    private let dependencies: DictationDependencies
    private var activeSessionID: UUID?
    private var sessionLease: SessionLease?
    private var didEmitSessionEnded = true
    private var permissionTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var recordingWatchdog: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var frozenRequest: DictationRequest?
    private var frozenAudioInput: AudioInputSelection = .systemDefault
    private var frozenTrimLeadingAndTrailingSilence = true
    private var frozenReduceLongInternalPauses = false
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void

    public var onRecordingTimeout: (() -> Void)?
    public var onRecordingStarted: (() -> Void)?
    public var onRecordingStopped: (() -> Void)?
    public var onTextCleanupStarted: (() -> Void)?
    public var onProcessingFinished: (() -> Void)?
    public var onEvent: ((DictationEvent) -> Void)?
    public var onSnapshot: ((DictationSnapshot) -> Void)? {
        didSet { onSnapshot?(snapshot) }
    }

    public var snapshot: DictationSnapshot {
        DictationSnapshot(state: state, lastAudioURL: lastAudioURL, lastTranscript: lastTranscript)
    }

    public convenience init(dependencies: DictationDependencies) {
        self.init(
            dependencies: dependencies,
            now: Date.init,
            sleep: { duration in try await Task.sleep(for: duration) }
        )
    }

    package init(
        dependencies: DictationDependencies,
        now: @escaping () -> Date,
        sleep: @escaping (Duration) async throws -> Void
    ) {
        self.dependencies = dependencies
        self.now = now
        self.sleep = sleep
    }

    public func startRecording(
        request: DictationRequest? = nil,
        audioInput: AudioInputSelection = .systemDefault,
        trimLeadingAndTrailingSilence: Bool = true,
        reduceLongInternalPauses: Bool = false
    ) {
        guard state == .idle else { return }
        if let sessionArbiter = dependencies.sessionArbiter {
            guard let lease = sessionArbiter.acquire(.dictation) else { return }
            sessionLease = lease
        }
        didEmitSessionEnded = false
        let sessionID = UUID()
        activeSessionID = sessionID
        frozenRequest = request
        frozenAudioInput = audioInput
        frozenTrimLeadingAndTrailingSilence = trimLeadingAndTrailingSilence
        frozenReduceLongInternalPauses = reduceLongInternalPauses
        state = .requestingPermission
        permissionTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let request { try await self.dependencies.transcriber.preflight(request: request.transcription) }
            } catch is CancellationError {
                return
            } catch {
                guard self.activeSessionID == sessionID else { return }
                self.activeSessionID = nil
                self.endSession()
                self.dependencies.logger.log("Error: \(safeLogMessage(for: error))")
                self.state = .error(.transcriptionFailed(message: userFacingMessage(for: error)))
                return
            }
            guard self.activeSessionID == sessionID, self.state == .requestingPermission else { return }
            guard await self.dependencies.microphonePermission.requestMicrophonePermission() else {
                guard self.activeSessionID == sessionID else { return }
                self.activeSessionID = nil
                self.endSession()
                let message = "Microphone access was denied. Allow Entrevoix in System Settings."
                self.dependencies.logger.log("Error: \(message)")
                self.state = .error(.microphonePermissionDenied)
                return
            }
            guard self.activeSessionID == sessionID, self.state == .requestingPermission else { return }
            do {
                let startResult = try self.dependencies.audioRecorder.start(input: self.frozenAudioInput)
                if startResult == .fellBackToSystemDefault {
                    self.dependencies.logger.log("Selected microphone unavailable; using the macOS default input.")
                }
                self.dependencies.logger.log("Recording started")
                self.onRecordingStarted?()
                self.onEvent?(.recordingStarted)
                self.recordingStartedAt = self.now()
                self.state = .recording
                self.recordingWatchdog?.cancel()
                let sleep = self.sleep
                self.recordingWatchdog = Task { [weak self] in
                    do {
                        try await sleep(.seconds(DictationTiming.maximumRecordingDuration))
                    } catch {
                        return
                    }
                    guard let self, self.activeSessionID == sessionID, self.state == .recording else { return }
                    self.onRecordingTimeout?()
                    self.onEvent?(.recordingTimedOut)
                }
            } catch {
                guard self.activeSessionID == sessionID else { return }
                self.activeSessionID = nil
                self.endSession()
                self.dependencies.logger.log("Error: \(safeLogMessage(for: error))")
                self.state = .error(.recordingFailed(message: userFacingMessage(for: error)))
            }
        }
    }

    public func dismissError() {
        guard case .error = state else { return }
        state = .idle
    }

    public func stopRecording(request: DictationRequest) {
        guard state == .recording else { return }
        recordingWatchdog?.cancel()
        recordingWatchdog = nil
        let duration = recordingStartedAt.map { now().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        if duration < DictationTiming.minimumRecordingDuration {
            dependencies.audioRecorder.cancel()
            dependencies.logger.log("Record ended")
            dependencies.logger.log("Recording discarded: less than 250 ms")
            activeSessionID = nil
            state = .idle
            endSession()
            return
        }
        lastAudioURL = dependencies.audioRecorder.stop()
        dependencies.logger.log("Record ended")
        onRecordingStopped?()
        onEvent?(.recordingStopped)
        guard let audioURL = lastAudioURL else {
            let message = "No audio file was produced."
            dependencies.logger.log("Error: \(message)")
            state = .error(.audioUnavailable)
            endSession()
            return
        }
        guard let sessionID = activeSessionID else {
            let message = "Recording session not found."
            dependencies.logger.log("Error: \(message)")
            state = .error(.sessionUnavailable)
            endSession()
            return
        }
        let frozenRequest = self.frozenRequest ?? request
        state = .transcribing
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            var captureURL = audioURL
            defer {
                self.dependencies.audioRecorder.deleteCapture(at: captureURL)
                if self.activeSessionID == sessionID {
                    self.activeSessionID = nil
                    self.lastAudioURL = nil
                }
                self.endSession()
            }
            do {
                if self.frozenTrimLeadingAndTrailingSilence || self.frozenReduceLongInternalPauses {
                    switch await self.dependencies.audioCaptureTrimmer.processCapture(
                        in: captureURL,
                        language: frozenRequest.transcription.language,
                        removeEdgeSilence: self.frozenTrimLeadingAndTrailingSilence,
                        reduceInternalPauses: self.frozenReduceLongInternalPauses
                    ) {
                    case .unchanged:
                        break
                    case .trimmed(let trimmedURL):
                        captureURL = trimmedURL
                        self.lastAudioURL = trimmedURL
                    case .noSpeechDetected:
                        guard self.activeSessionID == sessionID else { return }
                        self.activeSessionID = nil
                        self.lastAudioURL = nil
                        self.state = .error(.noSpeechDetected)
                        return
                    }
                }
                try Task.checkCancellation()
                let sizeInBytes = self.dependencies.audioRecorder.captureSize(at: captureURL)
                let sizeInKilobytes = Double(sizeInBytes) / 1024
                switch frozenRequest.transcription.target {
                case .remote:
                    let host = frozenRequest.transcription.configuration.endpointURL?.host ?? "configured endpoint"
                    self.dependencies.logger.log(String(format: "Sending %.1f kB to %@", sizeInKilobytes, host))
                case .apple:
                    self.dependencies.logger.log("Processing audio locally with Apple Speech")
                }
                let text = try await self.dependencies.transcriber.transcribe(audioURL: captureURL, request: frozenRequest.transcription)
                guard self.activeSessionID == sessionID else { return }
                self.dependencies.logger.log("Received \(text.count) chars transcription")
                var finalText = text
                var cleanupUnavailable: ProviderUnavailableError?
                if let cleanup = frozenRequest.cleanup {
                    switch cleanup.target {
                    case .remote:
                        let cleanupHost = cleanup.configuration.endpointURL?.host ?? "configured endpoint"
                        self.dependencies.logger.log("Sending transcription to \(cleanupHost)")
                    case .anthropic:
                        self.dependencies.logger.log("Sending transcription to Anthropic")
                    case .codex:
                        self.dependencies.logger.log("Sending transcription to ChatGPT Codex")
                    case .apple:
                        self.dependencies.logger.log("Improving text locally with Apple Intelligence")
                    }
                    self.onTextCleanupStarted?()
                    switch cleanup.kind {
                    case .prompt:
                        guard let step = cleanup.steps.first else { return }
                        self.onEvent?(.cleanupStarted)
                        do {
                            let enhancedText = try await self.dependencies.cleaner.clean(
                                text: text,
                                request: cleanup.request(for: step)
                            )
                            self.dependencies.logger.log("Received \(enhancedText.count) chars enhanced transcription")
                            finalText = enhancedText
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            self.dependencies.logger.log("Error: \(safeLogMessage(for: error))")
                            if let unavailable = error as? ProviderUnavailableError, case .apple = cleanup.target {
                                cleanupUnavailable = unavailable
                            } else {
                                switch cleanup.failurePolicy {
                                case .useRawTranscript:
                                    self.dependencies.logger.log("Using raw transcription after cleanup error")
                                case .stop:
                                    guard self.activeSessionID == sessionID else { return }
                                    self.lastTranscript = text
                                    self.activeSessionID = nil
                                    self.lastAudioURL = nil
                                    self.state = .error(.cleanupFailed(message: userFacingMessage(for: error)))
                                    self.onProcessingFinished?()
                                    return
                                }
                            }
                        }
                    case .workflow(_, let workflowName):
                        let workflowStartedAt = self.now()
                        for (offset, step) in cleanup.steps.enumerated() {
                            try Task.checkCancellation()
                            guard self.activeSessionID == sessionID else { return }
                            let stepNumber = offset + 1
                            self.onEvent?(.cleanupStepStarted(current: stepNumber, total: cleanup.steps.count))
                            let stepStartedAt = self.now()
                            self.dependencies.logger.log(
                                "Workflow \(workflowName) step \(stepNumber)/\(cleanup.steps.count) started (prompt \(step.promptID.uuidString): \(step.promptName))"
                            )
                            do {
                                finalText = try await self.dependencies.cleaner.clean(
                                    text: finalText,
                                    request: cleanup.request(for: step)
                                )
                                guard self.activeSessionID == sessionID else { return }
                                self.logWorkflowStep(
                                    workflowName: workflowName,
                                    stepNumber: stepNumber,
                                    totalSteps: cleanup.steps.count,
                                    prompt: step,
                                    duration: self.now().timeIntervalSince(stepStartedAt),
                                    error: nil
                                )
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                guard self.activeSessionID == sessionID else { return }
                                self.logWorkflowStep(
                                    workflowName: workflowName,
                                    stepNumber: stepNumber,
                                    totalSteps: cleanup.steps.count,
                                    prompt: step,
                                    duration: self.now().timeIntervalSince(stepStartedAt),
                                    error: error
                                )
                                if let unavailable = error as? ProviderUnavailableError, case .apple = cleanup.target {
                                    cleanupUnavailable = unavailable
                                }
                                self.lastTranscript = finalText
                                self.logDelivery(of: finalText, mode: frozenRequest.outputMode)
                                if let cleanupUnavailable {
                                    self.onEvent?(.providerUnavailable(capability: cleanupUnavailable.capability, reason: cleanupUnavailable.reason))
                                }
                                self.activeSessionID = nil
                                self.lastAudioURL = nil
                                self.state = .error(.cleanupWorkflowFailed(
                                    step: stepNumber,
                                    promptName: step.promptName,
                                    message: userFacingMessage(for: error)
                                ))
                                self.onProcessingFinished?()
                                self.endSession()
                                return
                            }
                        }
                        self.dependencies.logger.log(
                            String(
                                format: "Workflow %@ completed in %.3f s",
                                workflowName,
                                self.now().timeIntervalSince(workflowStartedAt)
                            )
                        )
                    }
                }
                guard self.activeSessionID == sessionID else { return }
                self.lastTranscript = finalText
                self.logDelivery(of: finalText, mode: frozenRequest.outputMode)
                if let cleanupUnavailable {
                    self.onEvent?(.providerUnavailable(capability: cleanupUnavailable.capability, reason: cleanupUnavailable.reason))
                }
                self.activeSessionID = nil
                self.lastAudioURL = nil
                self.state = .idle
                self.onProcessingFinished?()
                self.endSession()
            } catch is CancellationError {
                guard self.activeSessionID == sessionID else { return }
                self.activeSessionID = nil
                self.lastAudioURL = nil
                self.state = .idle
                self.onProcessingFinished?()
                self.endSession()
            } catch {
                guard self.activeSessionID == sessionID else { return }
                self.dependencies.logger.log("Error: \(safeLogMessage(for: error))")
                self.activeSessionID = nil
                self.lastAudioURL = nil
                self.state = .error(.transcriptionFailed(message: userFacingMessage(for: error)))
                self.onProcessingFinished?()
                self.endSession()
            }
        }
    }

    public func cancelRecording() {
        activeSessionID = nil
        permissionTask?.cancel()
        permissionTask = nil
        recordingWatchdog?.cancel()
        recordingWatchdog = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        recordingStartedAt = nil
        dependencies.audioRecorder.cancel()
        frozenRequest = nil
        frozenAudioInput = .systemDefault
        lastAudioURL = nil
        state = .idle
        endSession()
    }

    public func deleteLastCapture() {
        dependencies.audioRecorder.deleteLastCapture()
        lastAudioURL = nil
    }

    private func releaseSessionLease() {
        guard let sessionLease else { return }
        dependencies.sessionArbiter?.release(sessionLease)
        self.sessionLease = nil
    }

    private func logWorkflowStep(
        workflowName: String,
        stepNumber: Int,
        totalSteps: Int,
        prompt: CleanupStep,
        duration: TimeInterval,
        error: (any Error)?
    ) {
        let durationText = String(format: "%.3f", duration)
        if let error {
            dependencies.logger.log(
                "Error: Workflow \(workflowName) step \(stepNumber)/\(totalSteps) failed after \(durationText) s (prompt \(prompt.promptID.uuidString): \(prompt.promptName)): \(safeLogMessage(for: error))"
            )
        } else {
            dependencies.logger.log(
                "Workflow \(workflowName) step \(stepNumber)/\(totalSteps) completed in \(durationText) s (prompt \(prompt.promptID.uuidString): \(prompt.promptName))"
            )
        }
    }

    private func logDelivery(of text: String, mode: OutputMode) {
        let deliveryResult = dependencies.textDelivery.deliver(text, mode: mode)
        switch deliveryResult {
        case .copied:
            dependencies.logger.log("Delivered transcription to clipboard")
        case .inserted:
            dependencies.logger.log("Inserted transcription in active field")
        case .fallbackCopied(let reason):
            dependencies.logger.log("Automatic insertion unavailable; copied to clipboard (\(reason))")
        case .secureFieldCopied:
            dependencies.logger.log("Secure field detected; copied to clipboard")
        }
    }

    private func endSession() {
        releaseSessionLease()
        guard !didEmitSessionEnded else { return }
        didEmitSessionEnded = true
        onEvent?(.sessionEnded)
    }
}
