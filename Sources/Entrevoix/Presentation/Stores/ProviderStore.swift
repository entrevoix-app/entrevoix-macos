import Foundation
import EntrevoixCore
import Observation

@MainActor
@Observable
final class ProviderStore {
    let preferencesStore: PreferencesStore

    private let modelCatalog: any RemoteModelDiscovering
    private let codexCredentialsStore: any CodexCredentialsStoring
    private let codexAuthenticator: any CodexAuthenticating
    private let audioCaptureTrimmingResources: any AudioCaptureTrimmingResourceManaging
    private let logStore: AppLogStore
    private let initialPreferencesAreFresh: Bool

    private(set) var discoveredModels: [UUID: [String]] = [:]
    private(set) var modelDiscoveryErrors: [UUID: String] = [:]
    private(set) var codexConnectionState: CodexConnectionState = .disconnected
    private(set) var audioCaptureTrimmingResourceState: AudioCaptureTrimmingResourceState = .checking

    @ObservationIgnored private var credentialStateTask: Task<Void, Never>?
    @ObservationIgnored private var authenticationTask: Task<Void, Never>?
    @ObservationIgnored private var authenticationGeneration = UUID()
    @ObservationIgnored private var modelDiscoveryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var modelDiscoveryGenerations: [UUID: UUID] = [:]
    @ObservationIgnored private var audioCaptureTrimmingResourceTask: Task<Void, Never>?
    @ObservationIgnored private var audioCaptureTrimmingResourceGeneration = UUID()

    init(
        preferencesStore: PreferencesStore,
        modelCatalog: any RemoteModelDiscovering,
        codexCredentialsStore: any CodexCredentialsStoring,
        codexAuthenticator: any CodexAuthenticating,
        audioCaptureTrimmingResources: any AudioCaptureTrimmingResourceManaging,
        logStore: AppLogStore,
        initialPreferencesAreFresh: Bool
    ) {
        self.preferencesStore = preferencesStore
        self.modelCatalog = modelCatalog
        self.codexCredentialsStore = codexCredentialsStore
        self.codexAuthenticator = codexAuthenticator
        self.audioCaptureTrimmingResources = audioCaptureTrimmingResources
        self.logStore = logStore
        self.initialPreferencesAreFresh = initialPreferencesAreFresh
        refreshCodexConnectionState()
        refreshAudioCaptureTrimmingResourceState()
        if initialPreferencesAreFresh && preferences.trimLeadingAndTrailingSilence && preferences.reduceLongInternalPauses {
            downloadAudioCaptureTrimmingResource()
        }
    }

    var preferences: AppPreferences {
        get { preferencesStore.preferences }
        set { preferencesStore.update(newValue) }
    }

    var interfaceLocale: Locale {
        EntrevoixLocalization.locale(for: preferences.interfaceLanguage)
    }

    var providersSortedForDisplay: [ProviderCatalogEntry] {
        preferences.providerCatalog.sorted {
            providerName($0).localizedCaseInsensitiveCompare(providerName($1)) == .orderedAscending
        }
    }

    func providerName(_ entry: ProviderCatalogEntry) -> String {
        switch entry {
        case .apple:
            EntrevoixLocalization.text("provider.apple_local", defaultValue: "Apple (local)", locale: interfaceLocale)
        case .codex:
            EntrevoixLocalization.text("provider.openai_codex", defaultValue: "OpenAI (Codex)", locale: interfaceLocale)
        case .remote(let profile):
            profile.name
        }
    }

    func apiKey(for provider: ProviderIdentifier?) -> String {
        preferencesStore.apiKey(for: provider)
    }

    func setAPIKey(_ value: String, for provider: ProviderIdentifier?) {
        preferencesStore.setAPIKey(value, for: provider)
    }

    func setSTTProvider(_ id: ProviderIdentifier?) {
        guard id == nil || preferences.provider(for: id)?.supportsSTT == true else { return }
        preferences.selectedSTTProviderID = id
        if id == .apple, preferences.sttLanguage == .automatic {
            preferences.sttLanguage = .english
        }
        preferencesStore.savePreferencesImmediately()
        refreshAudioCaptureTrimmingResourceState()
    }

    func setTTTProvider(_ id: ProviderIdentifier?) {
        guard id == nil || preferences.provider(for: id)?.supportsTTT == true else { return }
        preferences.selectedTTTProviderID = id
        if id == nil { preferences.cleanupEnabled = false }
        preferencesStore.savePreferencesImmediately()
    }

    func addAppleProvider() {
        guard preferences.provider(for: .apple) == nil else { return }
        preferences.providerCatalog.append(.apple)
        preferencesStore.savePreferencesImmediately()
    }

    func addCodexProvider() {
        guard preferences.provider(for: .codex) == nil else { return }
        preferences.providerCatalog.append(.codex(CodexProviderProfile()))
        preferencesStore.savePreferencesImmediately()
    }

    func setCodexModel(_ model: CodexModel) {
        guard let index = preferences.providerCatalog.firstIndex(where: { $0.id == .codex }),
              case .codex(var profile) = preferences.providerCatalog[index] else { return }
        profile.model = model
        preferences.providerCatalog[index] = .codex(profile)
        preferencesStore.savePreferencesImmediately()
    }

    func connectCodex() {
        startCodexOperation(state: .connecting) { [codexAuthenticator, codexCredentialsStore] in
            let credentials = try await codexAuthenticator.connect()
            try Task.checkCancellation()
            try await codexCredentialsStore.saveCodexCredentials(credentials)
            return .connected
        }
    }

    func disconnectCodex() {
        startCodexOperation(state: .connecting) { [codexCredentialsStore] in
            try await codexCredentialsStore.saveCodexCredentials(nil)
            return .disconnected
        }
    }

    func removeCodexProvider() {
        guard preferences.provider(for: .codex) != nil else { return }
        startCodexOperation(state: .connecting) { [codexCredentialsStore] in
            try await codexCredentialsStore.saveCodexCredentials(nil)
            return .disconnected
        } onSuccess: { [weak self] in
            self?.removeProviderEntry(.codex)
        }
    }

    func newRemoteProvider(kind: RemoteProviderKind) -> RemoteProviderProfile {
        switch kind {
        case .openAI: RemoteProviderProfile.openAI()
        case .openAICompatible: RemoteProviderProfile.compatible()
        case .anthropic: RemoteProviderProfile.anthropic()
        }
    }

    @discardableResult
    func addOpenAIProviderForOnboarding() -> ProviderIdentifier {
        if let existing = preferences.providerCatalog.first(where: {
            $0.remoteProfile?.kind == .openAI && $0.supportsSTT
        }) {
            setSTTProvider(existing.id)
            return existing.id
        }

        let profile = RemoteProviderProfile.openAI()
        let identifier = ProviderIdentifier.remote(profile.id)
        preferences.providerCatalog.append(.remote(profile))
        preferences.selectedSTTProviderID = identifier
        preferencesStore.savePreferencesImmediately()
        return identifier
    }

    func commitConfiguration() {
        preferencesStore.flushPendingWrites()
    }

    @discardableResult
    func saveRemoteProvider(_ draft: RemoteProviderProfile, apiKey: String) -> [ProviderValidationIssue] {
        var draft = draft
        draft.normalizeFixedProviderFields()
        let names = preferences.providerCatalog.compactMap { entry -> String? in
            guard case .remote(let profile) = entry, profile.id != draft.id else { return nil }
            return profile.name
        }
        let issues = draft.validationIssues(apiKey: apiKey, existingNames: names)
        guard issues.isEmpty else { return issues }
        if let index = preferences.providerCatalog.firstIndex(where: { $0.id == .remote(draft.id) }) {
            preferences.providerCatalog[index] = .remote(draft)
        } else {
            preferences.providerCatalog.append(.remote(draft))
        }
        preferencesStore.setAPIKey(apiKey, for: .remote(draft.id), to: .immediate)
        preferencesStore.savePreferencesImmediately()
        return []
    }

    @discardableResult
    func removeProvider(_ id: ProviderIdentifier) -> Bool {
        guard id != .codex else { return false }
        if let remoteID = id.remoteID, !preferencesStore.removeProviderSecret(remoteID) { return false }
        removeProviderEntry(id)
        return true
    }

    func loadModels(for profile: RemoteProviderProfile) {
        let key = preferencesStore.apiKey(for: .remote(profile.id))
        guard var configuration = profile.configuration(for: profile.stt == nil ? .ttt : .stt) else { return }
        configuration.path = profile.modelsPath

        let generation = UUID()
        modelDiscoveryTasks[profile.id]?.cancel()
        modelDiscoveryGenerations[profile.id] = generation
        modelDiscoveryErrors[profile.id] = nil
        modelDiscoveryTasks[profile.id] = Task { [weak self, modelCatalog] in
            do {
                let models = try await modelCatalog.discoverModels(configuration: configuration, apiKey: key)
                try Task.checkCancellation()
                guard let self, self.modelDiscoveryGenerations[profile.id] == generation else { return }
                self.discoveredModels[profile.id] = models
                self.modelDiscoveryTasks[profile.id] = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.modelDiscoveryGenerations[profile.id] == generation else { return }
                self.modelDiscoveryErrors[profile.id] = EntrevoixLocalization.text(
                    "provider.models_load_failed",
                    defaultValue: "Could not load models. You can still enter one manually.",
                    locale: self.interfaceLocale
                )
                self.modelDiscoveryTasks[profile.id] = nil
            }
        }
    }

    func modelDiscoveryError(for providerID: UUID) -> String? {
        modelDiscoveryErrors[providerID]
    }

    func refreshAudioCaptureTrimmingResourceState() {
        let locale = trimmingResourceLocale
        let generation = UUID()
        audioCaptureTrimmingResourceGeneration = generation
        audioCaptureTrimmingResourceTask?.cancel()
        audioCaptureTrimmingResourceState = .checking
        audioCaptureTrimmingResourceTask = Task { [weak self, audioCaptureTrimmingResources] in
            let state = await audioCaptureTrimmingResources.preparationState(for: locale)
            guard !Task.isCancelled,
                  let self,
                  self.audioCaptureTrimmingResourceGeneration == generation else { return }
            self.audioCaptureTrimmingResourceState = state
            self.audioCaptureTrimmingResourceTask = nil
        }
    }

    func downloadAudioCaptureTrimmingResource() {
        let locale = trimmingResourceLocale
        let generation = UUID()
        audioCaptureTrimmingResourceGeneration = generation
        audioCaptureTrimmingResourceTask?.cancel()
        audioCaptureTrimmingResourceState = .downloading
        audioCaptureTrimmingResourceTask = Task { [weak self, audioCaptureTrimmingResources] in
            do {
                try await audioCaptureTrimmingResources.download(for: locale)
                try Task.checkCancellation()
                let state = await audioCaptureTrimmingResources.preparationState(for: locale)
                guard let self,
                      self.audioCaptureTrimmingResourceGeneration == generation else { return }
                self.audioCaptureTrimmingResourceState = state
                self.audioCaptureTrimmingResourceTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.audioCaptureTrimmingResourceGeneration == generation else { return }
                self.audioCaptureTrimmingResourceState = .failed
                self.logStore.log("Audio trimming resource download failed: \(safeLogMessage(for: error))")
                self.audioCaptureTrimmingResourceTask = nil
            }
        }
    }

    func isValidSTTSelection(_ id: ProviderIdentifier?) -> Bool {
        guard let entry = preferences.provider(for: id), entry.supportsSTT else { return false }
        switch entry {
        case .apple:
            return preferences.sttLanguage != .automatic
        case .codex:
            return false
        case .remote(let profile):
            return profile.validationIssues(apiKey: apiKey(for: .remote(profile.id))).isEmpty
        }
    }

    func makeDictationRequest(
        activeCleanupSelection: CleanupTransformationSelection?,
        cleanupPrompts: [CleanupPrompt],
        cleanupWorkflows: [CleanupWorkflow]
    ) -> DictationRequest? {
        guard let transcription = makeTranscriptionRequest() else { return nil }
        let cleanup = preferences.cleanupEnabled
            ? makeCleanupPlan(
                selection: activeCleanupSelection,
                prompts: cleanupPrompts,
                workflows: cleanupWorkflows
            )
            : nil
        return DictationRequest(
            transcription: transcription,
            cleanup: cleanup,
            outputMode: preferences.outputMode
        )
    }

    func makeTranscriptionRequest() -> TranscriptionRequest? {
        guard let entry = preferences.provider(for: preferences.selectedSTTProviderID) else { return nil }
        switch entry {
        case .apple:
            return TranscriptionRequest(
                configuration: .openAITranscription,
                apiKey: "",
                prompt: preferences.dictationDictionaryPrompt,
                language: preferences.sttLanguage.apiCode,
                target: .apple(
                    localeIdentifier: preferences.sttLanguage == .automatic ? nil : preferences.sttLanguage.apiCode,
                    dictionaryTerms: preferences.dictationDictionary
                )
            )
        case .codex:
            return nil
        case .remote(let profile):
            guard let configuration = profile.configuration(for: .stt),
                  configuration.validationIssues(apiKey: "").filter({ $0 != .missingAPIKey }).isEmpty else { return nil }
            return TranscriptionRequest(
                configuration: configuration,
                apiKey: preferencesStore.apiKey(for: .remote(profile.id)),
                prompt: preferences.dictationDictionaryPrompt,
                language: preferences.sttLanguage.apiCode
            )
        }
    }

    private func makeCleanupPlan(
        selection: CleanupTransformationSelection?,
        prompts: [CleanupPrompt],
        workflows: [CleanupWorkflow]
    ) -> CleanupPlan? {
        guard let selection,
              let entry = preferences.provider(for: preferences.selectedTTTProviderID) else { return nil }

        let kind: CleanupPlanKind
        let steps: [CleanupStep]
        switch selection {
        case .prompt(let id):
            guard let prompt = prompts.first(where: { $0.id == id }) else { return nil }
            kind = .prompt
            steps = [CleanupStep(promptID: prompt.id, promptName: prompt.name, prompt: prompt.instructions)]
        case .workflow(let id):
            guard let workflow = workflows.first(where: { $0.id == id }), workflow.isValid else { return nil }
            steps = workflow.promptIDs.compactMap { promptID in
                guard let prompt = prompts.first(where: { $0.id == promptID }) else { return nil }
                return CleanupStep(promptID: prompt.id, promptName: prompt.name, prompt: prompt.instructions)
            }
            guard steps.count == workflow.promptIDs.count else { return nil }
            kind = .workflow(id: workflow.id, name: workflow.name)
        }

        switch entry {
        case .apple:
            return CleanupPlan(
                configuration: .openAIResponses,
                apiKey: "",
                format: .responses,
                failurePolicy: preferences.cleanupFailurePolicy,
                target: .apple(localeIdentifier: preferences.sttLanguage == .automatic ? nil : preferences.sttLanguage.apiCode),
                kind: kind,
                steps: steps
            )
        case .codex(let profile):
            return CleanupPlan(
                configuration: .codexResponses(model: profile.model),
                apiKey: "",
                format: .responses,
                failurePolicy: preferences.cleanupFailurePolicy,
                target: .codex,
                language: preferences.sttLanguage.apiCode,
                kind: kind,
                steps: steps
            )
        case .remote(let profile):
            guard let configuration = profile.configuration(for: .ttt),
                  configuration.validationIssues(apiKey: "").filter({ $0 != .missingAPIKey }).isEmpty else { return nil }
            return CleanupPlan(
                configuration: configuration,
                apiKey: preferencesStore.apiKey(for: .remote(profile.id)),
                format: profile.ttt?.format ?? .responses,
                failurePolicy: preferences.cleanupFailurePolicy,
                target: profile.kind == .anthropic ? .anthropic : .remote,
                language: preferences.sttLanguage.apiCode,
                kind: kind,
                steps: steps
            )
        }
    }

    private func refreshCodexConnectionState() {
        let generation = UUID()
        authenticationGeneration = generation
        credentialStateTask?.cancel()
        credentialStateTask = Task { [weak self, codexCredentialsStore] in
            do {
                let credentials = try await codexCredentialsStore.readCodexCredentials()
                try Task.checkCancellation()
                guard let self, self.authenticationGeneration == generation else { return }
                self.codexConnectionState = credentials == nil ? .disconnected : .connected
                self.credentialStateTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.authenticationGeneration == generation else { return }
                self.codexConnectionState = .failed
                self.logStore.log("Error: \(safeLogMessage(for: error))")
                self.credentialStateTask = nil
            }
        }
    }

    private var trimmingResourceLocale: Locale {
        Locale(identifier: preferences.sttLanguage.apiCode ?? Locale.current.identifier)
    }

    private func startCodexOperation(
        state: CodexConnectionState,
        operation: @escaping @MainActor () async throws -> CodexConnectionState,
        onSuccess: @escaping @MainActor () -> Void = {}
    ) {
        let generation = UUID()
        authenticationGeneration = generation
        credentialStateTask?.cancel()
        credentialStateTask = nil
        authenticationTask?.cancel()
        codexConnectionState = state
        authenticationTask = Task { [weak self] in
            do {
                let finalState = try await operation()
                try Task.checkCancellation()
                guard let self, self.authenticationGeneration == generation else { return }
                onSuccess()
                self.codexConnectionState = finalState
                self.authenticationTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.authenticationGeneration == generation else { return }
                self.codexConnectionState = .failed
                self.logStore.log("Error: \(safeLogMessage(for: error))")
                self.authenticationTask = nil
            }
        }
    }

    private func removeProviderEntry(_ id: ProviderIdentifier) {
        preferences.providerCatalog.removeAll { $0.id == id }
        if preferences.selectedSTTProviderID == id { preferences.selectedSTTProviderID = nil }
        if preferences.selectedTTTProviderID == id {
            preferences.selectedTTTProviderID = nil
            preferences.cleanupEnabled = false
        }
        preferencesStore.savePreferencesImmediately()
    }
}
