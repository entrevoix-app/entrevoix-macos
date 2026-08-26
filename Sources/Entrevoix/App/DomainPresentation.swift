import Foundation
import EntrevoixCore

private extension Locale {
    static let english = Locale(identifier: "en")
}

private func localized(_ key: String, _ fallback: String, locale: Locale) -> String {
    EntrevoixLocalization.text(key, defaultValue: fallback, locale: locale)
}

extension AuthenticationMode {
    func title(locale: Locale) -> String {
        switch self {
        case .bearer: localized("auth.bearer", "Bearer", locale: locale)
        case .apiKey: localized("auth.api_key", "API Key", locale: locale)
        case .none: localized("auth.none", "None", locale: locale)
        }
    }

    var title: String { title(locale: .english) }
}

extension CleanupAPIFormat {
    func title(locale: Locale) -> String {
        switch self {
        case .responses: localized("cleanup.responses_api", "Responses API", locale: locale)
        case .chatCompletions: localized("cleanup.chat_completions", "Chat Completions", locale: locale)
        case .anthropicMessages: localized("cleanup.anthropic_messages", "Anthropic Messages", locale: locale)
        }
    }

    var title: String { title(locale: .english) }
}

extension CleanupFailurePolicy {
    func title(locale: Locale) -> String {
        switch self {
        case .useRawTranscript: localized("cleanup.use_raw_transcript", "Use Raw Transcript", locale: locale)
        case .stop: localized("cleanup.stop_with_error", "Stop with an Error", locale: locale)
        }
    }

    var title: String { title(locale: .english) }
}

extension OutputMode {
    func title(locale: Locale) -> String {
        switch self {
        case .clipboard: localized("output.clipboard", "Clipboard", locale: locale)
        case .paste: localized("output.insert_automatically", "Insert Automatically", locale: locale)
        }
    }

    var title: String { title(locale: .english) }
}

extension TriggerMode {
    func title(locale: Locale) -> String {
        switch self {
        case .pushToTalk: localized("trigger.hold_to_talk", "Hold to Talk", locale: locale)
        case .toggle: localized("trigger.press_to_start_stop", "Press to Start/Stop", locale: locale)
        }
    }

    var title: String { title(locale: .english) }
}

extension UpdateChannel {
    func title(locale: Locale) -> String {
        switch self {
        case .stable:
            localized("updates.channel.stable", "Stable", locale: locale)
        case .releaseCandidate:
            localized("updates.channel.rc", "Release Candidate", locale: locale)
        case .development:
            localized("updates.channel.dev", "Development", locale: locale)
        }
    }

    func description(locale: Locale) -> String {
        switch self {
        case .stable:
            localized("updates.channel.stable.description", "Recommended for everyday use.", locale: locale)
        case .releaseCandidate:
            localized("updates.channel.rc.description", "Early access to versions nearing release.", locale: locale)
        case .development:
            localized("updates.channel.dev.description", "The newest builds, with a higher risk of regressions.", locale: locale)
        }
    }
}

extension UserFacingErrorMessage {
    func localizedText(locale: Locale) -> String {
        switch self {
        case .recordingCouldNotStart:
            localized("error.recording_failed", "Could not start recording. Check microphone permission.", locale: locale)
        case .sttInvalidEndpoint:
            localized("error.stt_invalid_endpoint", "The STT endpoint is invalid.", locale: locale)
        case .sttInvalidHeader:
            localized("error.stt_invalid_header", "The authentication header name is invalid.", locale: locale)
        case .sttMissingAPIKey:
            localized("error.stt_missing_api_key", "The STT API key is missing.", locale: locale)
        case .sttFileTooLarge:
            localized("error.stt_file_too_large", "The audio file exceeds the 25 MB limit.", locale: locale)
        case .sttAudioEncodingFailed:
            localized("error.stt_audio_encoding_failed", "The audio file could not be prepared for upload.", locale: locale)
        case .sttInvalidResponse:
            localized("error.stt_invalid_response", "The STT response is invalid.", locale: locale)
        case .sttEmptyResult:
            localized("error.stt_empty_result", "The transcript is empty.", locale: locale)
        case .sttHTTP(let statusCode, let providerMessage):
            localizedHTTP(prefixKey: "error.stt_http", fallback: "STT error (HTTP %lld).", statusCode: statusCode, providerMessage: providerMessage, locale: locale)
        case .tttInvalidEndpoint:
            localized("error.ttt_invalid_endpoint", "The TTT endpoint is invalid.", locale: locale)
        case .tttMissingAPIKey:
            localized("error.ttt_missing_api_key", "The TTT API key is missing.", locale: locale)
        case .tttInvalidHeader:
            localized("error.ttt_invalid_header", "The TTT header name is invalid.", locale: locale)
        case .tttEmptyInput:
            localized("error.ttt_empty_input", "The transcript to clean up is empty.", locale: locale)
        case .tttEmptyPrompt:
            localized("error.ttt_empty_prompt", "The TTT prompt is empty.", locale: locale)
        case .tttInvalidResponse:
            localized("error.ttt_invalid_response", "The TTT response is invalid.", locale: locale)
        case .tttEmptyResult:
            localized("error.ttt_empty_result", "TTT cleanup returned empty text.", locale: locale)
        case .tttHTTP(let statusCode, let providerMessage):
            localizedHTTP(prefixKey: "error.ttt_http", fallback: "TTT error (HTTP %lld).", statusCode: statusCode, providerMessage: providerMessage, locale: locale)
        case .codexNotConnected:
            localized("error.codex_not_connected", "Connect ChatGPT before using OpenAI (Codex).", locale: locale)
        case .codexInvalidRequest:
            localized("error.codex_invalid_request", "The OpenAI (Codex) request is invalid.", locale: locale)
        case .codexConnectionFailed:
            localized("error.codex_connection_failed", "Could not connect to ChatGPT.", locale: locale)
        case .verbatim(let message):
            message
        }
    }

    private func localizedHTTP(
        prefixKey: String,
        fallback: String,
        statusCode: Int,
        providerMessage: String?,
        locale: Locale
    ) -> String {
        let format = localized(prefixKey, fallback, locale: locale)
        let status = String(format: format, locale: locale, arguments: [statusCode])
        guard let providerMessage, !providerMessage.isEmpty else { return status }
        return "\(status): \(providerMessage)"
    }
}

extension DictationFailure {
    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .microphonePermissionDenied:
            return localized("failure.microphone_denied", "Microphone access was denied. Allow Entrevoix in System Settings.", locale: locale)
        case .recordingFailed(let message), .transcriptionFailed(let message), .cleanupFailed(let message):
            return message.localizedText(locale: locale)
        case .cleanupWorkflowFailed(let step, let promptName, let message):
            let format = localized(
                "failure.workflow_step_failed",
                "Workflow step %lld (%@) failed. The last available result was inserted: %@",
                locale: locale
            )
            return String(
                format: format,
                locale: locale,
                arguments: [step, promptName, message.localizedText(locale: locale)]
            )
        case .audioUnavailable:
            return localized("failure.no_audio", "No audio file was produced.", locale: locale)
        case .noSpeechDetected:
            return localized("failure.no_speech", "No speech was detected.", locale: locale)
        case .sessionUnavailable:
            return localized("failure.session_not_found", "Recording session not found.", locale: locale)
        }
    }

    var title: String { localizedTitle(locale: .english) }
}

extension DictationState {
    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .idle: localized("dictation.ready", "Ready", locale: locale)
        case .requestingPermission: localized("dictation.requesting_microphone", "Requesting microphone access…", locale: locale)
        case .recording: localized("dictation.recording", "Recording…", locale: locale)
        case .transcribing: localized("dictation.transcribing", "Transcribing…", locale: locale)
        case .error(let failure): failure.localizedTitle(locale: locale)
        }
    }

    var title: String { localizedTitle(locale: .english) }
}

extension ConnectionTestState {
    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .idle:
            localized("connection_test.ready", "Ready to test the STT connection.", locale: locale)
        case .requestingPermission:
            localized("dictation.requesting_microphone", "Requesting microphone access…", locale: locale)
        case .recording:
            localized("connection_test.recording", "Recording test audio…", locale: locale)
        case .testing:
            localized("connection_test.sending", "Sending the recording to the provider…", locale: locale)
        case .succeeded(let characterCount):
            EntrevoixLocalization.characterCount(characterCount, locale: locale)
        case .failed(let failure):
            switch failure {
            case .invalidConfiguration(let issues):
                issues.map { $0.localizedTitle(locale: locale) }.joined(separator: " ")
            case .microphonePermissionDenied:
                localized("failure.microphone_denied", "Microphone access was denied. Allow Entrevoix in System Settings.", locale: locale)
            case .recordingFailed(let message), .transcriptionFailed(let message):
                message.localizedText(locale: locale)
            case .insufficientAudio:
                localized("connection_test.insufficient_audio", "Record at least one short phrase before running the test.", locale: locale)
            case .noSpeechDetected:
                localized("failure.no_speech", "No speech was detected.", locale: locale)
            }
        }
    }

    var title: String { localizedTitle(locale: .english) }
}

private extension ProviderValidationIssue {
    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .missingName:
            "A provider name is required."
        case .duplicateName:
            "Provider names must be unique."
        case .invalidEndpoint:
            localized("validation.invalid_url", "Invalid URL: use http:// or https://", locale: locale)
        case .missingCapability:
            "Select at least one capability."
        case .missingRoute:
            "A route is required for each capability."
        case .missingModel:
            localized("validation.model_required", "A model is required.", locale: locale)
        case .missingHeaderName:
            localized("validation.header_required", "An authentication header name is required.", locale: locale)
        case .missingAPIKey:
            localized("validation.api_key_required", "An API key is required for this authentication mode.", locale: locale)
        }
    }
}

extension PermissionStatus {
    func title(locale: Locale) -> String {
        switch self {
        case .granted: localized("permission.allowed", "Allowed", locale: locale)
        case .denied: localized("permission.denied", "Denied", locale: locale)
        case .notDetermined: localized("permission.not_allowed_yet", "Not allowed yet", locale: locale)
        }
    }

    var title: String { title(locale: .english) }
}
