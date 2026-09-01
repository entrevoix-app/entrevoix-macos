import AVFAudio
import Foundation
import Speech
import EntrevoixCore

public actor AppleSpeechResourceManager {
    private var reservedLocale: Locale?
    private(set) var state: ProviderPreparationState = .checking

    public init() {}

    public func preparationState(for requestedLocale: Locale) async -> ProviderPreparationState {
        guard SpeechTranscriber.isAvailable else { state = .unsupported; return state }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else { state = .unsupported; return state }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: state = .ready
        case .downloading: state = .downloading(progress: nil)
        case .supported: state = .downloadRequired
        case .unsupported: state = .unsupported
        @unknown default: state = .failed
        }
        return state
    }

    public func download(for requestedLocale: Locale) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else { throw AppleProviderError(capability: .stt, reason: .unsupportedLocale) }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            state = .ready
            return
        }
        state = .downloading(progress: request.progress.fractionCompleted)
        do {
            try await request.downloadAndInstall()
            state = .ready
        } catch {
            state = .failed
            throw AppleProviderError(capability: .stt, reason: .speechAssetsUnavailable)
        }
    }

    public func reserve(locale requestedLocale: Locale) async throws -> Locale {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else { throw AppleProviderError(capability: .stt, reason: .unsupportedLocale) }
        guard await preparationState(for: locale) == .ready else { throw AppleProviderError(capability: .stt, reason: .speechAssetsRequired) }
        if reservedLocale == locale { return locale }
        if let reservedLocale { _ = await AssetInventory.release(reservedLocale: reservedLocale) }
        guard try await AssetInventory.reserve(locale: locale) else { throw AppleProviderError(capability: .stt, reason: .speechAssetsUnavailable) }
        reservedLocale = locale
        return locale
    }

    public func release() async {
        if let reservedLocale { _ = await AssetInventory.release(reservedLocale: reservedLocale) }
        reservedLocale = nil
    }
}

public struct AppleSpeechTranscriptionService: SpeechTranscribing {
    public let resources: AppleSpeechResourceManager

    public init(resources: AppleSpeechResourceManager = AppleSpeechResourceManager()) {
        self.resources = resources
    }

    public func preflight(request: TranscriptionRequest) async throws {
        guard case .apple(let identifier, _) = request.target else { return }
        guard SpeechTranscriber.isAvailable else { throw AppleProviderError(capability: .stt, reason: .unsupportedDevice) }
        _ = try await resources.reserve(locale: Locale(identifier: identifier ?? Locale.current.identifier))
    }

    public func transcribe(audioURL: URL, request: TranscriptionRequest) async throws -> String {
        guard case .apple(let identifier, let dictionary) = request.target else { throw AppleProviderError(capability: .stt, reason: .missingConfiguration) }
        let locale = try await resources.reserve(locale: Locale(identifier: identifier ?? Locale.current.identifier))
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings[.general] = dictionary
        try await analyzer.setContext(context)
        let file = try AVAudioFile(forReading: audioURL)
        do {
            async let finalText: String = collectFinalText(from: transcriber)
            let finalTime = try await analyzer.analyzeSequence(from: file)
            if let finalTime {
                try await analyzer.finalizeAndFinish(through: finalTime)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            let collected = try await finalText
            let result = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else { throw AppleProviderError(capability: .stt, reason: .missingConfiguration) }
            return result
        } catch is CancellationError {
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    public func transcribe(audioURL: URL, configuration: ProviderConfiguration, apiKey: String, prompt: String?, language: String?) async throws -> String {
        try await transcribe(audioURL: audioURL, request: TranscriptionRequest(configuration: configuration, apiKey: apiKey, prompt: prompt, language: language, target: .apple(localeIdentifier: language, dictionaryTerms: [])))
    }

    private func collectFinalText(from transcriber: SpeechTranscriber) async throws -> String {
        var values: [String] = []
        for try await result in transcriber.results where result.isFinal {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { values.append(text) }
        }
        return values.joined(separator: " ")
    }
}

typealias AppleProviderError = ProviderUnavailableError
