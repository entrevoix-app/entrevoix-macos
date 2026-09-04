import Foundation

public struct AppPreferences: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 16
    public static let defaultCleanupPromptID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    public var schemaVersion: Int
    public var interfaceLanguage: InterfaceLanguage
    public var providerCatalog: [ProviderCatalogEntry]
    public var selectedSTTProviderID: ProviderIdentifier?
    public var selectedTTTProviderID: ProviderIdentifier?
    public var sttLanguage: TranscriptionLanguage
    public var sttFavoriteLanguages: [TranscriptionLanguage]
    public var dictationDictionary: [String]
    public var audioInputSelection: AudioInputSelection
    public var trimLeadingAndTrailingSilence: Bool
    public var reduceLongInternalPauses: Bool
    public var triggerMode: TriggerMode
    public var cleanupEnabled: Bool
    public var cleanupPrompts: [CleanupPrompt]
    public var cleanupWorkflows: [CleanupWorkflow]
    public var activeCleanupSelection: CleanupTransformationSelection?
    public var cleanupPrompt: String
    public var cleanupPromptMode: CleanupPromptMode
    public var cleanupFailurePolicy: CleanupFailurePolicy
    public var outputMode: OutputMode
    public var launchAtLogin: Bool
    public var playFeedbackSounds: Bool
    public var updateChannel: UpdateChannel
    public var hasCompletedOnboarding: Bool
    /// One-shot, in-memory key migration instructions for a malformed schema-8
    /// payload where STT and TTT reused an identifier. This is never encoded.
    public var secretMigrationCopies: [UUID: UUID]

    public init(
        schemaVersion: Int = AppPreferences.currentSchemaVersion,
        interfaceLanguage: InterfaceLanguage = .automatic,
        providerCatalog: [ProviderCatalogEntry] = [],
        selectedSTTProviderID: ProviderIdentifier? = nil,
        selectedTTTProviderID: ProviderIdentifier? = nil,
        sttLanguage: TranscriptionLanguage = .automatic,
        sttFavoriteLanguages: [TranscriptionLanguage] = [.french, .english],
        dictationDictionary: [String] = [],
        audioInputSelection: AudioInputSelection = .systemDefault,
        trimLeadingAndTrailingSilence: Bool = true,
        reduceLongInternalPauses: Bool = true,
        triggerMode: TriggerMode = .pushToTalk,
        cleanupEnabled: Bool = false,
        cleanupPrompt: String = AppPreferences.defaultCleanupPrompt,
        cleanupPromptMode: CleanupPromptMode = .localizedDefault,
        cleanupPrompts: [CleanupPrompt] = [CleanupPrompt(id: AppPreferences.defaultCleanupPromptID, name: "Standard", systemImageName: "wand.and.stars", instructions: AppPreferences.defaultCleanupPrompt)],
        cleanupWorkflows: [CleanupWorkflow] = [],
        activeCleanupSelection: CleanupTransformationSelection? = nil,
        activeCleanupPromptID: UUID? = nil,
        cleanupFailurePolicy: CleanupFailurePolicy = .useRawTranscript,
        outputMode: OutputMode = .clipboard,
        launchAtLogin: Bool = false,
        playFeedbackSounds: Bool = true,
        updateChannel: UpdateChannel = .stable,
        hasCompletedOnboarding: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.interfaceLanguage = interfaceLanguage
        self.providerCatalog = providerCatalog
        self.selectedSTTProviderID = selectedSTTProviderID
        self.selectedTTTProviderID = selectedTTTProviderID
        self.sttLanguage = sttLanguage
        var favorites = Self.normalizedFavoriteLanguages(sttFavoriteLanguages)
        if sttLanguage != .automatic && !favorites.contains(sttLanguage) { favorites.append(sttLanguage) }
        self.sttFavoriteLanguages = favorites
        self.dictationDictionary = Self.normalizedDictationDictionary(dictationDictionary)
        self.audioInputSelection = audioInputSelection
        self.trimLeadingAndTrailingSilence = trimLeadingAndTrailingSilence
        self.reduceLongInternalPauses = reduceLongInternalPauses
        self.triggerMode = triggerMode
        self.cleanupEnabled = cleanupEnabled && selectedTTTProviderID != nil
        self.cleanupPrompts = cleanupPrompts
        self.cleanupWorkflows = cleanupWorkflows
        self.activeCleanupSelection = activeCleanupSelection
            ?? activeCleanupPromptID.map(CleanupTransformationSelection.prompt)
            ?? cleanupPrompts.first.map { .prompt($0.id) }
        self.cleanupPrompt = cleanupPrompt
        self.cleanupPromptMode = cleanupPromptMode
        self.cleanupFailurePolicy = cleanupFailurePolicy
        self.outputMode = outputMode
        self.launchAtLogin = launchAtLogin
        self.playFeedbackSounds = playFeedbackSounds
        self.updateChannel = updateChannel
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.secretMigrationCopies = [:]
        normalizeProviderReferences()
    }

    /// Compatibility projection for call sites that still operate on a prompt-only selection.
    public var activeCleanupPromptID: UUID? {
        get {
            guard case .prompt(let id) = activeCleanupSelection else { return nil }
            return id
        }
        set {
            activeCleanupSelection = newValue.map(CleanupTransformationSelection.prompt)
        }
    }

    public var activeCleanupWorkflowID: UUID? {
        guard case .workflow(let id) = activeCleanupSelection else { return nil }
        return id
    }

    public func isValidCleanupSelection(_ selection: CleanupTransformationSelection?) -> Bool {
        guard let selection else { return false }
        switch selection {
        case .prompt(let id): return cleanupPrompts.contains { $0.id == id }
        case .workflow(let id): return cleanupWorkflows.contains { $0.id == id && $0.isValid }
        }
    }

    public func cleanupFallbackSelection() -> CleanupTransformationSelection? {
        if cleanupPrompts.contains(where: { $0.id == Self.defaultCleanupPromptID }) {
            return .prompt(Self.defaultCleanupPromptID)
        }
        return cleanupPrompts.first.map { .prompt($0.id) }
    }

    public mutating func normalizeCleanupSelection() {
        guard let activeCleanupSelection, !isValidCleanupSelection(activeCleanupSelection) else { return }
        self.activeCleanupSelection = cleanupFallbackSelection()
        if self.activeCleanupSelection == nil {
            cleanupEnabled = false
        }
    }

    public static let defaultCleanupPrompt = "Clean up the transcript without changing its meaning. Correct punctuation, mistakes, and hesitations. Return only the final text."

    public var dictationDictionaryPrompt: String? {
        guard !dictationDictionary.isEmpty else { return nil }
        return dictationDictionary.joined(separator: ", ")
    }

    public func provider(for identifier: ProviderIdentifier?) -> ProviderCatalogEntry? {
        guard let identifier else { return nil }
        return providerCatalog.first { $0.id == identifier }
    }

    public func remoteProfile(for identifier: ProviderIdentifier?) -> RemoteProviderProfile? {
        provider(for: identifier)?.remoteProfile
    }

    /// Transitional projection used by the existing STT client. New UI and request
    /// assembly should resolve a catalogue entry explicitly.
    public var stt: ProviderConfiguration {
        get { remoteProfile(for: selectedSTTProviderID)?.configuration(for: .stt) ?? .openAITranscription }
        set { replaceRemoteCapability(identifier: selectedSTTProviderID, configuration: newValue, capability: .stt) }
    }

    /// Transitional projection used by the existing cleanup client.
    public var cleanupProvider: ProviderConfiguration {
        get { remoteProfile(for: selectedTTTProviderID)?.configuration(for: .ttt) ?? .openAIResponses }
        set { replaceRemoteCapability(identifier: selectedTTTProviderID, configuration: newValue, capability: .ttt) }
    }

    public var cleanupFormat: CleanupAPIFormat {
        get { remoteProfile(for: selectedTTTProviderID)?.ttt?.format ?? .responses }
        set {
            guard case .remote(let id) = selectedTTTProviderID,
                  let index = providerCatalog.firstIndex(where: { $0.id == .remote(id) }),
                  case .remote(var profile) = providerCatalog[index], var capability = profile.ttt else { return }
            capability.format = newValue
            profile.ttt = capability
            profile.normalizeFixedProviderFields()
            providerCatalog[index] = .remote(profile)
        }
    }

    public mutating func normalizeProviderReferences() {
        providerCatalog = providerCatalog.reduce(into: []) { result, entry in
            if entry.id == .apple {
                if !result.contains(where: { $0.id == .apple }) { result.append(entry) }
            } else if !result.contains(where: { $0.id == entry.id }) { result.append(entry) }
        }
        providerCatalog = providerCatalog.map { entry in
            guard case .remote(var profile) = entry else { return entry }
            profile.normalizeFixedProviderFields()
            return .remote(profile)
        }
        if provider(for: selectedSTTProviderID) == nil { selectedSTTProviderID = nil }
        if provider(for: selectedTTTProviderID) == nil { selectedTTTProviderID = nil }
        if selectedTTTProviderID == nil { cleanupEnabled = false }
    }

    private mutating func replaceRemoteCapability(identifier: ProviderIdentifier?, configuration: ProviderConfiguration, capability: ProviderCapability) {
        guard case .remote(let id) = identifier,
              let index = providerCatalog.firstIndex(where: { $0.id == .remote(id) }),
              case .remote(var profile) = providerCatalog[index] else { return }
        profile.name = configuration.name
        profile.baseURL = configuration.baseURL
        profile.authentication = configuration.authentication
        profile.customHeaderName = configuration.customHeaderName
        profile.timeout = configuration.timeout
        switch capability {
        case .stt: profile.stt = STTCapability(path: configuration.path, model: configuration.model)
        case .ttt: profile.ttt = TTTCapability(path: configuration.path, model: configuration.model, format: profile.ttt?.format ?? .responses)
        }
        profile.normalizeFixedProviderFields()
        providerCatalog[index] = .remote(profile)
    }

    public static func normalizedDictationDictionary(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.compactMap { rawTerm in
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term).inserted else { return nil }
            return term
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, interfaceLanguage, providerCatalog, selectedSTTProviderID, selectedTTTProviderID
        case sttLanguage, sttFavoriteLanguages, dictationDictionary, audioInputSelection, trimLeadingAndTrailingSilence, reduceLongInternalPauses, triggerMode, cleanupEnabled
        case cleanupPrompts, cleanupWorkflows, activeCleanupSelection, activeCleanupPromptID
        case cleanupPrompt, cleanupPromptMode, cleanupFailurePolicy
        case outputMode, launchAtLogin, playFeedbackSounds, updateChannel, hasCompletedOnboarding
        // Schema 8 keys, intentionally decode-only.
        case stt, cleanupProvider, cleanupFormat
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sourceVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 8
        schemaVersion = sourceVersion
        interfaceLanguage = try c.decodeIfPresent(InterfaceLanguage.self, forKey: .interfaceLanguage) ?? .automatic
        if let catalogue = try c.decodeIfPresent([ProviderCatalogEntry].self, forKey: .providerCatalog) {
            providerCatalog = catalogue
            selectedSTTProviderID = try c.decodeIfPresent(ProviderIdentifier.self, forKey: .selectedSTTProviderID)
            selectedTTTProviderID = try c.decodeIfPresent(ProviderIdentifier.self, forKey: .selectedTTTProviderID)
            secretMigrationCopies = [:]
        } else {
            let legacySTT = try c.decodeIfPresent(ProviderConfiguration.self, forKey: .stt) ?? .openAITranscription
            let legacyTTT = try c.decodeIfPresent(ProviderConfiguration.self, forKey: .cleanupProvider) ?? .openAIResponses
            let legacyFormat = try c.decodeIfPresent(CleanupAPIFormat.self, forKey: .cleanupFormat) ?? .responses
            var sttProfile = RemoteProviderProfile(id: legacySTT.id, kind: .openAICompatible, name: legacySTT.name, baseURL: legacySTT.baseURL, authentication: legacySTT.authentication, customHeaderName: legacySTT.customHeaderName, timeout: legacySTT.timeout, stt: STTCapability(path: legacySTT.path, model: legacySTT.model))
            // A corrupted old payload can use the same UUID for both secrets. A fresh ID
            // prevents one catalogue entry from silently replacing the other.
            let cleanupID = legacyTTT.id == legacySTT.id ? UUID() : legacyTTT.id
            let cleanupProfile = RemoteProviderProfile(id: cleanupID, kind: .openAICompatible, name: legacyTTT.name, baseURL: legacyTTT.baseURL, authentication: legacyTTT.authentication, customHeaderName: legacyTTT.customHeaderName, timeout: legacyTTT.timeout, ttt: TTTCapability(path: legacyTTT.path, model: legacyTTT.model, format: legacyFormat))
            sttProfile.normalizeFixedOpenAIFields()
            providerCatalog = [.remote(sttProfile), .remote(cleanupProfile)]
            selectedSTTProviderID = .remote(sttProfile.id)
            selectedTTTProviderID = .remote(cleanupProfile.id)
            secretMigrationCopies = cleanupID == legacyTTT.id ? [:] : [cleanupID: legacyTTT.id]
        }
        if let raw = try? c.decode(String.self, forKey: .sttLanguage) { sttLanguage = TranscriptionLanguage(legacyCode: raw) } else { sttLanguage = .automatic }
        if let raw = try? c.decode([String].self, forKey: .sttFavoriteLanguages) { sttFavoriteLanguages = Self.normalizedFavoriteLanguages(raw.map(TranscriptionLanguage.init(legacyCode:))) } else { sttFavoriteLanguages = [.french, .english] }
        if sttLanguage != .automatic && !sttFavoriteLanguages.contains(sttLanguage) { sttFavoriteLanguages.append(sttLanguage) }
        dictationDictionary = Self.normalizedDictationDictionary(try c.decodeIfPresent([String].self, forKey: .dictationDictionary) ?? [])
        audioInputSelection = try c.decodeIfPresent(AudioInputSelection.self, forKey: .audioInputSelection) ?? .systemDefault
        trimLeadingAndTrailingSilence = try c.decodeIfPresent(Bool.self, forKey: .trimLeadingAndTrailingSilence) ?? true
        reduceLongInternalPauses = try c.decodeIfPresent(Bool.self, forKey: .reduceLongInternalPauses) ?? false
        triggerMode = try c.decodeIfPresent(TriggerMode.self, forKey: .triggerMode) ?? .pushToTalk
        cleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? true
        cleanupPrompt = try c.decodeIfPresent(String.self, forKey: .cleanupPrompt) ?? Self.defaultCleanupPrompt
        if let mode = try c.decodeIfPresent(CleanupPromptMode.self, forKey: .cleanupPromptMode) { cleanupPromptMode = mode } else { cleanupPromptMode = cleanupPrompt == Self.defaultCleanupPrompt ? .legacyDefaultPendingChoice : .custom }
        if let prompts = try c.decodeIfPresent([CleanupPrompt].self, forKey: .cleanupPrompts) {
            cleanupPrompts = prompts
        } else {
            let prompt = CleanupPrompt(name: cleanupPromptMode == .custom ? "Existing Prompt" : "Standard", systemImageName: cleanupPromptMode == .custom ? "text.badge.checkmark" : "wand.and.stars", instructions: cleanupPrompt)
            cleanupPrompts = [prompt]
        }
        cleanupWorkflows = try c.decodeIfPresent([CleanupWorkflow].self, forKey: .cleanupWorkflows) ?? []
        if c.contains(.activeCleanupSelection) {
            activeCleanupSelection = try c.decodeIfPresent(CleanupTransformationSelection.self, forKey: .activeCleanupSelection)
        } else {
            activeCleanupSelection = (try c.decodeIfPresent(UUID.self, forKey: .activeCleanupPromptID)).map(CleanupTransformationSelection.prompt)
                ?? cleanupPrompts.first.map { .prompt($0.id) }
        }
        cleanupFailurePolicy = try c.decodeIfPresent(CleanupFailurePolicy.self, forKey: .cleanupFailurePolicy) ?? .useRawTranscript
        outputMode = try c.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? .clipboard
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        playFeedbackSounds = try c.decodeIfPresent(Bool.self, forKey: .playFeedbackSounds) ?? true
        updateChannel = (try? c.decode(UpdateChannel.self, forKey: .updateChannel)) ?? .stable
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? (sourceVersion < 4)
        normalizeProviderReferences()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(interfaceLanguage, forKey: .interfaceLanguage)
        try c.encode(providerCatalog, forKey: .providerCatalog)
        try c.encodeIfPresent(selectedSTTProviderID, forKey: .selectedSTTProviderID)
        try c.encodeIfPresent(selectedTTTProviderID, forKey: .selectedTTTProviderID)
        try c.encode(sttLanguage, forKey: .sttLanguage); try c.encode(sttFavoriteLanguages, forKey: .sttFavoriteLanguages)
        try c.encode(dictationDictionary, forKey: .dictationDictionary); try c.encode(audioInputSelection, forKey: .audioInputSelection); try c.encode(trimLeadingAndTrailingSilence, forKey: .trimLeadingAndTrailingSilence); try c.encode(reduceLongInternalPauses, forKey: .reduceLongInternalPauses); try c.encode(triggerMode, forKey: .triggerMode)
        try c.encode(cleanupEnabled, forKey: .cleanupEnabled); try c.encode(cleanupPrompts, forKey: .cleanupPrompts)
        try c.encode(cleanupWorkflows, forKey: .cleanupWorkflows)
        try c.encode(activeCleanupSelection, forKey: .activeCleanupSelection)
        try c.encode(cleanupPrompt, forKey: .cleanupPrompt); try c.encode(cleanupPromptMode, forKey: .cleanupPromptMode)
        try c.encode(cleanupFailurePolicy, forKey: .cleanupFailurePolicy); try c.encode(outputMode, forKey: .outputMode)
        try c.encode(launchAtLogin, forKey: .launchAtLogin); try c.encode(playFeedbackSounds, forKey: .playFeedbackSounds)
        try c.encode(updateChannel, forKey: .updateChannel)
        try c.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
    }

    private static func normalizedFavoriteLanguages(_ languages: [TranscriptionLanguage]) -> [TranscriptionLanguage] {
        var result: [TranscriptionLanguage] = []
        for language in languages where language != .automatic && !result.contains(language) { result.append(language) }
        return result
    }
}
