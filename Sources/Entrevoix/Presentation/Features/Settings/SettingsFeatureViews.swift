import KeyboardShortcuts
import EntrevoixCore
import Observation
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var model: AppStore

    var body: some View {
        let locale = model.interfaceLocale
        Form {
            Section(EntrevoixLocalization.text("settings.general", defaultValue: "General", locale: locale)) {
                Picker(EntrevoixLocalization.text("settings.interface_language", defaultValue: "Interface language", locale: locale), selection: Binding(
                    get: { model.preferences.interfaceLanguage },
                    set: { model.setInterfaceLanguage($0) }
                )) {
                    ForEach(InterfaceLanguage.allCases) { language in
                        Text(language.title(locale: locale)).tag(language)
                    }
                }
                Toggle(EntrevoixLocalization.text("settings.launch_at_login", defaultValue: "Launch Entrevoix at login", locale: locale), isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Toggle(EntrevoixLocalization.text("settings.play_feedback", defaultValue: "Play a sound when dictation starts and ends", locale: locale), isOn: $model.preferences.playFeedbackSounds)
                if let launchAtLoginError = model.launchAtLoginError {
                    Label(launchAtLoginError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Section(EntrevoixLocalization.text("settings.audio_input", defaultValue: "Audio Input", locale: locale)) {
                Picker(
                    EntrevoixLocalization.text("field.audio_input", defaultValue: "Microphone", locale: locale),
                    selection: Binding(
                        get: { model.audioInput.selection },
                        set: { model.audioInput.setSelection($0) }
                    )
                ) {
                    Text(systemDefaultInputTitle(locale: locale))
                        .tag(AudioInputSelection.systemDefault)
                    ForEach(model.audioInput.devices) { device in
                        Text(device.name)
                            .tag(AudioInputSelection.device(device))
                    }
                    if let unavailableDevice = model.audioInput.unavailableSelection {
                        Text(unavailableInputTitle(unavailableDevice.name, locale: locale))
                            .tag(AudioInputSelection.device(unavailableDevice))
                    }
                }
                .pickerStyle(.menu)

                if model.audioInput.unavailableSelection != nil {
                    Label(
                        EntrevoixLocalization.text(
                            "audio_input.unavailable_warning",
                            defaultValue: "Entrevoix will use the macOS default microphone until this device reconnects.",
                            locale: locale
                        ),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                }
            }

            Section(EntrevoixLocalization.text("settings.updates", defaultValue: "Updates", locale: locale)) {
                Picker(EntrevoixLocalization.text("settings.update_channel", defaultValue: "Update channel", locale: locale), selection: Binding(
                    get: { model.updates.selectedChannel },
                    set: { model.updates.requestChannel($0) }
                )) {
                    ForEach(UpdateChannel.allCases) { channel in
                        VStack(alignment: .leading) {
                            Text(channel.title(locale: locale))
                            Text(channel.description(locale: locale))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(channel)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(EntrevoixLocalization.text(
                    "settings.update_channel_hint",
                    defaultValue: "Stable updates are always included. Returning to Stable never downgrades an installed version.",
                    locale: locale
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(EntrevoixLocalization.text("settings.global_shortcut", defaultValue: "Global Shortcuts", locale: locale)) {
                KeyboardShortcuts.Recorder(EntrevoixLocalization.text("field.primary_shortcut", defaultValue: "Primary shortcut:", locale: locale), name: .dictation)
                KeyboardShortcuts.Recorder(EntrevoixLocalization.text("field.secondary_shortcut", defaultValue: "Secondary shortcut (optional):", locale: locale), name: .dictationSecondary)
                Picker(EntrevoixLocalization.text("menu.mode", defaultValue: "Mode", locale: locale), selection: Binding(
                    get: { model.mode },
                    set: { model.setMode($0) }
                )) {
                    ForEach(TriggerMode.allCases) { mode in
                        Text(mode.title(locale: locale)).tag(mode)
                    }
                }
            }

            Section(EntrevoixLocalization.text("settings.delivery", defaultValue: "Delivery", locale: locale)) {
                Picker(EntrevoixLocalization.text("field.output", defaultValue: "Output", locale: locale), selection: $model.preferences.outputMode) {
                    ForEach(OutputMode.allCases) { Text($0.title(locale: locale)).tag($0) }
                }
            }

            PermissionsSettings(model: model)

            Section(EntrevoixLocalization.text("settings.about", defaultValue: "About", locale: locale)) {
                Text(EntrevoixLocalization.text("settings.version", defaultValue: "Entrevoix 0.1.0 — MIT License", locale: locale))
                Link(EntrevoixLocalization.text("settings.source_code", defaultValue: "Source code on GitHub", locale: locale), destination: URL(string: "https://github.com/entrevoix-app/entrevoix-macos")!)
            }
        }
        .formStyle(.grouped)
        .settingsGroupedFormContentMargins()
        .alert(
            updateConfirmationTitle(locale: locale),
            isPresented: Binding(
                get: { model.updates.isConfirmationPresented },
                set: { isPresented in
                    if !isPresented { model.updates.cancelPendingChannelChange() }
                }
            )
        ) {
            Button(updateConfirmationAction(locale: locale)) {
                model.updates.confirmPendingChannelChange()
            }
            Button(EntrevoixLocalization.text("action.cancel", defaultValue: "Cancel", locale: locale), role: .cancel) {
                model.updates.cancelPendingChannelChange()
            }
        } message: {
            Text(EntrevoixLocalization.text(
                "updates.channel.confirmation_message",
                defaultValue: "Pre-release updates may be less stable. Returning to Stable will not downgrade an already installed version.",
                locale: locale
            ))
        }
    }

    private func updateConfirmationTitle(locale: Locale) -> String {
        switch model.updates.pendingChannel {
        case .releaseCandidate:
            EntrevoixLocalization.text("updates.channel.confirm_rc", defaultValue: "Use Release Candidate updates?", locale: locale)
        case .development:
            EntrevoixLocalization.text("updates.channel.confirm_dev", defaultValue: "Use Development updates?", locale: locale)
        case .stable, .none:
            EntrevoixLocalization.text("updates.channel.confirm", defaultValue: "Change update channel?", locale: locale)
        }
    }

    private func updateConfirmationAction(locale: Locale) -> String {
        switch model.updates.pendingChannel {
        case .releaseCandidate:
            EntrevoixLocalization.text("updates.channel.use_rc", defaultValue: "Use Release Candidate", locale: locale)
        case .development:
            EntrevoixLocalization.text("updates.channel.use_dev", defaultValue: "Use Development", locale: locale)
        case .stable, .none:
            EntrevoixLocalization.text("updates.channel.confirm_action", defaultValue: "Change Channel", locale: locale)
        }
    }

    private func systemDefaultInputTitle(locale: Locale) -> String {
        guard let device = model.audioInput.defaultDevice else {
            return EntrevoixLocalization.text(
                "audio_input.system_default",
                defaultValue: "macOS Default Microphone",
                locale: locale
            )
        }
        let format = EntrevoixLocalization.text(
            "audio_input.system_default_named",
            defaultValue: "macOS Default Microphone (%@)",
            locale: locale
        )
        return String(format: format, locale: locale, arguments: [device.name])
    }

    private func unavailableInputTitle(_ name: String, locale: Locale) -> String {
        let format = EntrevoixLocalization.text(
            "audio_input.unavailable",
            defaultValue: "%@ (Unavailable)",
            locale: locale
        )
        return String(format: format, locale: locale, arguments: [name])
    }
}

private struct PermissionsSettings: View {
    @Bindable var model: AppStore

    var body: some View {
        let locale = model.interfaceLocale
        Section(EntrevoixLocalization.text("settings.permissions", defaultValue: "Permissions", locale: locale)) {
            permissionRow(EntrevoixLocalization.text("permission.microphone", defaultValue: "Microphone", locale: locale), status: model.microphonePermission, locale: locale)
            if model.microphonePermission != .granted {
                Button(EntrevoixLocalization.text("permission.allow_microphone", defaultValue: "Allow Microphone Access", locale: locale)) {
                    model.requestMicrophonePermission()
                }
                .disabled(model.isResettingMicrophonePermission)
            }
            if model.microphonePermission == .denied {
                Button(EntrevoixLocalization.text("permission.reset_microphone", defaultValue: "Repair Microphone Access", locale: locale)) {
                    model.resetMicrophonePermission()
                }
                .disabled(model.isResettingMicrophonePermission)
            }
            if model.isResettingMicrophonePermission {
                Label(
                    EntrevoixLocalization.text("permission.resetting_microphone", defaultValue: "Resetting microphone access…", locale: locale),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            if let feedback = model.microphonePermissionRepairFeedback {
                repairFeedbackView(feedback, locale: locale)
            }
            permissionRow(EntrevoixLocalization.text("permission.accessibility", defaultValue: "Accessibility", locale: locale), status: model.accessibilityPermission, locale: locale)
            if model.accessibilityPermission != .granted {
                Button(EntrevoixLocalization.text("permission.allow_accessibility", defaultValue: "Allow Automatic Insertion", locale: locale)) { model.requestAccessibilityPermission() }
            }
            Button(EntrevoixLocalization.text("permission.refresh", defaultValue: "Refresh Permissions", locale: locale)) { model.refreshPermissions() }
            Text(EntrevoixLocalization.text("permission.accessibility_insertion_hint", defaultValue: "Accessibility permission is only required for automatic insertion. Without it, Entrevoix uses the clipboard.", locale: locale))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func permissionRow(_ name: String, status: PermissionStatus, locale: Locale) -> some View {
        HStack {
            Text(name)
            Spacer()
            Label(status.title(locale: locale), systemImage: status == .granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status == .granted ? .green : .orange)
        }
        .accessibilityLabel(EntrevoixLocalization.permissionStatus(name: name, status: status.title(locale: locale), locale: locale))
    }

    private func repairFeedbackView(
        _ feedback: MicrophonePermissionRepairFeedback,
        locale: Locale
    ) -> some View {
        let message: String
        let symbol: String
        switch feedback {
        case .succeeded:
            message = EntrevoixLocalization.text(
                "permission.reset_succeeded",
                defaultValue: "Permission reset. Allow microphone access now.",
                locale: locale
            )
            symbol = "checkmark.circle.fill"
        case .failed:
            message = EntrevoixLocalization.text(
                "permission.reset_failed",
                defaultValue: "macOS could not reset microphone access.",
                locale: locale
            )
            symbol = "exclamationmark.triangle.fill"
        }
        return Label(message, systemImage: symbol)
            .foregroundStyle(feedback == .succeeded ? .green : .orange)
            .accessibilityElement(children: .combine)
    }
}

struct STTSettingsView: View {
    @Bindable var model: AppStore

    var body: some View {
        let locale = model.interfaceLocale
        Form {
            Section(EntrevoixLocalization.text("settings.stt", defaultValue: "STT Transcription", locale: locale)) {
                Picker(EntrevoixLocalization.text("field.provider", defaultValue: "Provider", locale: locale), selection: Binding(get: { model.preferences.selectedSTTProviderID }, set: { model.setSTTProvider($0) })) {
                    Text(EntrevoixLocalization.text("provider.none_selected", defaultValue: "No provider selected", locale: locale)).tag(Optional<ProviderIdentifier>.none)
                    ForEach(model.providersSortedForDisplay.filter { entry in entry.id == .apple || entry.remoteProfile?.stt != nil }) { entry in
                        Text(model.providerName(entry)).tag(Optional(entry.id))
                    }
                }
                if model.preferences.selectedSTTProviderID == nil {
                    Label(EntrevoixLocalization.text("provider.stt_missing", defaultValue: "Add and configure a provider in the Providers section before dictating.", locale: locale), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if model.preferences.selectedSTTProviderID == .apple {
                    Label(EntrevoixLocalization.text("provider.apple_speech_hint", defaultValue: "Apple Speech runs locally. A supported speech asset must be downloaded and ready before recording.", locale: locale), systemImage: "apple.logo")
                        .foregroundStyle(.secondary)
                } else {
                    Text(EntrevoixLocalization.text("provider.edit_hint", defaultValue: "Edit endpoint, credentials, routes, and model in Providers.", locale: locale)).foregroundStyle(.secondary)
                }
                Picker(EntrevoixLocalization.text("field.stt_language", defaultValue: "Transcription language", locale: locale), selection: Binding(
                    get: { model.preferences.sttLanguage },
                    set: { model.setSTTLanguage($0) }
                )) {
                    ForEach(TranscriptionLanguage.sortedForDisplay(locale: locale, includingAutomatic: model.preferences.selectedSTTProviderID != .apple)) { language in
                        Text(language.title(locale: locale)).tag(language)
                    }
                }
                .pickerStyle(.menu)
                ConnectionTestControls(model: model.connectionTestStore)
            }
            Section(EntrevoixLocalization.text("field.stt_favorite_languages", defaultValue: "Languages in the menu", locale: locale)) {
                ForEach(TranscriptionLanguage.sortedForDisplay(locale: locale, includingAutomatic: false)) { language in
                    Toggle(language.title(locale: locale), isOn: Binding(
                        get: { model.preferences.sttFavoriteLanguages.contains(language) },
                        set: { model.setSTTFavoriteLanguage(language, enabled: $0) }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
        }
        .formStyle(.grouped)
        .settingsGroupedFormContentMargins()
    }
}

struct DictationDictionaryView: View {
    @Bindable var model: AppStore
    @State private var searchText = ""
    @State private var isAdding = false
    @State private var editingTerm: String?
    @State private var newTerm = ""
    @State private var addError = false
    @FocusState private var newTermIsFocused: Bool

    private var filteredTerms: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.preferences.dictationDictionary }
        return model.preferences.dictationDictionary.filter {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let locale = model.interfaceLocale
        List {
            SettingsLibraryHeader(
                title: EntrevoixLocalization.text("settings.dictation_dictionary", defaultValue: "Dictation Dictionary", locale: locale),
                description: EntrevoixLocalization.text(
                    "dictation_dictionary.description",
                    defaultValue: "Add names, acronyms, or technical terms that should be recognized by dictation.",
                    locale: locale
                ),
                systemImage: SettingsSection.dictationDictionary.systemImageName
            )
            Label {
                Text(EntrevoixLocalization.text(
                    "dictation_dictionary.warning",
                    defaultValue: "This may improve recognition, but it is not 100% effective and depends on the selected transcription model.",
                    locale: locale
                ))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, SettingsLayout.sectionSpacing)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if isAdding {
                dictionaryTermEditor(
                    locale: locale,
                    showsBottomSeparator: !filteredTerms.isEmpty
                )
            }

            if filteredTerms.isEmpty, !isAdding {
                ContentUnavailableView(
                    searchText.isEmpty
                        ? EntrevoixLocalization.text("dictation_dictionary.none", defaultValue: "No terms saved", locale: locale)
                        : EntrevoixLocalization.text("library.no_results", defaultValue: "No matching items", locale: locale),
                    systemImage: "textformat.abc"
                )
            } else {
                ForEach(filteredTerms, id: \.self) { term in
                    if editingTerm == term {
                        dictionaryTermEditor(
                            locale: locale,
                            showsBottomSeparator: term != filteredTerms.last
                        )
                    } else {
                        HStack(spacing: 8) {
                            Button {
                                beginEditing(term)
                            } label: {
                                SettingsLibraryRow(title: term, systemImage: "textformat.abc")
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())

                            Menu {
                                Button {
                                    beginEditing(term)
                                } label: {
                                    Label(
                                        EntrevoixLocalization.text("dictation_dictionary.edit", defaultValue: "Edit term", locale: locale),
                                        systemImage: "pencil"
                                    )
                                }
                                Divider()
                                Button(role: .destructive) {
                                    model.removeDictationDictionaryTerm(term)
                                } label: {
                                    Label(
                                        EntrevoixLocalization.text("dictation_dictionary.remove", defaultValue: "Remove term", locale: locale),
                                        systemImage: "trash"
                                    )
                                }
                            }
                            label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .accessibilityLabel(EntrevoixLocalization.text("dictation_dictionary.actions", defaultValue: "Term actions", locale: locale))
                        }
                        .listRowSeparator(term == filteredTerms.last ? .hidden : .visible, edges: .bottom)
                    }
                }
            }
        }
        .listStyle(.inset)
        .settingsPageContentMargins()
        .scrollBounceBehavior(.always)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .contentMargins(.bottom, SettingsLayout.pageInset, for: .scrollContent)
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: EntrevoixLocalization.text("dictation_dictionary.search", defaultValue: "Search…", locale: locale)
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: beginAdding) {
                    Label(
                        EntrevoixLocalization.text("dictation_dictionary.add", defaultValue: "Add term", locale: locale),
                        systemImage: "plus"
                    )
                }
                .disabled(isAdding || editingTerm != nil)
            }
        }
        .onChange(of: isAdding) { _, adding in
            if adding { newTermIsFocused = true }
        }
        .onChange(of: editingTerm) { _, editingTerm in
            if editingTerm != nil { newTermIsFocused = true }
        }
    }

    private func dictionaryTermEditor(
        locale: Locale,
        showsBottomSeparator: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "textformat.abc")
                .foregroundStyle(.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    TextField(
                        EntrevoixLocalization.text("dictation_dictionary.entry_placeholder", defaultValue: "Term", locale: locale),
                        text: $newTerm
                    )
                    .textFieldStyle(.plain)
                    .focused($newTermIsFocused)
                    .onSubmit(commitDictionaryTerm)
                    .onExitCommand(perform: cancelDictionaryTerm)
                    .onChange(of: newTerm) { _, _ in addError = false }

                    Button(action: commitDictionaryTerm) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(EntrevoixLocalization.text("action.save", defaultValue: "Save", locale: locale))

                    Button(action: cancelDictionaryTerm) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(EntrevoixLocalization.text("dictation_dictionary.cancel", defaultValue: "Cancel", locale: locale))
                }
                if addError {
                    Text(EntrevoixLocalization.text(
                        "dictation_dictionary.invalid_entry",
                        defaultValue: "Enter a non-empty term that is not already in the dictionary.",
                        locale: locale
                    ))
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(Color(nsColor: .controlBackgroundColor))
        .listRowSeparator(.hidden, edges: .bottom)
        .overlay(alignment: .bottom) {
            if showsBottomSeparator {
                Divider()
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func beginEditing(_ term: String) {
        guard !isAdding else { return }
        editingTerm = term
        newTerm = term
        addError = false
        newTermIsFocused = true
    }

    private func beginAdding() {
        guard !isAdding, editingTerm == nil else { return }
        newTerm = ""
        addError = false
        isAdding = true
        newTermIsFocused = true
    }

    private func commitDictionaryTerm() {
        let didSave: Bool
        if let editingTerm {
            didSave = model.updateDictationDictionaryTerm(editingTerm, to: newTerm)
        } else {
            didSave = model.addDictationDictionaryTerm(newTerm)
        }
        guard didSave else {
            addError = true
            newTermIsFocused = true
            return
        }
        isAdding = false
        editingTerm = nil
        newTerm = ""
        addError = false
    }

    private func cancelDictionaryTerm() {
        isAdding = false
        editingTerm = nil
        newTerm = ""
        addError = false
        newTermIsFocused = false
    }
}

struct CleanupSettingsView: View {
    @Bindable var model: AppStore

    var body: some View {
        let locale = model.interfaceLocale
        Form {
            Section(EntrevoixLocalization.text("settings.ttt", defaultValue: "TTT Cleanup", locale: locale)) {
                Picker(EntrevoixLocalization.text("field.provider", defaultValue: "Provider", locale: locale), selection: Binding(get: { model.preferences.selectedTTTProviderID }, set: { model.setTTTProvider($0) })) {
                    Text(EntrevoixLocalization.text("provider.none_selected", defaultValue: "No provider selected", locale: locale)).tag(Optional<ProviderIdentifier>.none)
                    ForEach(model.providersSortedForDisplay.filter { entry in entry.id == .apple || entry.id == .codex || entry.remoteProfile?.ttt != nil }) { entry in
                        Text(model.providerName(entry)).tag(Optional(entry.id))
                    }
                }
                Toggle(EntrevoixLocalization.text("settings.enable_cleanup", defaultValue: "Enable cleanup", locale: locale), isOn: $model.preferences.cleanupEnabled)
                    .disabled(model.preferences.selectedTTTProviderID == nil || !model.hasActiveCleanupTransformation)
                if model.preferences.cleanupEnabled {
                    if !model.hasActiveCleanupTransformation {
                        Label(EntrevoixLocalization.text("cleanup.no_selection_warning", defaultValue: "No usable prompt or workflow is available. Add or repair one before enabling cleanup.", locale: locale), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Picker(EntrevoixLocalization.text("cleanup.active_transformation", defaultValue: "Active transformation", locale: locale), selection: Binding<CleanupTransformationSelection?>(
                        get: { model.promptLibrary.activeSelection },
                        set: { model.promptLibrary.setActiveSelection($0) }
                    )) {
                        Text(EntrevoixLocalization.text("prompts.none", defaultValue: "None", locale: locale)).tag(Optional<CleanupTransformationSelection>.none)
                        Section(EntrevoixLocalization.text("menu.prompts_group", defaultValue: "Prompts", locale: locale)) {
                            ForEach(model.preferences.cleanupPrompts) { prompt in
                                Text(prompt.name).tag(Optional(CleanupTransformationSelection.prompt(prompt.id)))
                            }
                        }
                        Section(EntrevoixLocalization.text("menu.workflows_group", defaultValue: "Workflows", locale: locale)) {
                            ForEach(model.preferences.cleanupWorkflows) { workflow in
                                Text(workflow.name)
                                    .tag(Optional(CleanupTransformationSelection.workflow(workflow.id)))
                                    .disabled(!workflow.isValid)
                            }
                        }
                    }
                    Picker(EntrevoixLocalization.text("cleanup.on_failure", defaultValue: "On failure", locale: locale), selection: $model.preferences.cleanupFailurePolicy) {
                        ForEach(CleanupFailurePolicy.allCases) { Text($0.title(locale: locale)).tag($0) }
                    }
                    Text(EntrevoixLocalization.text("provider.models_compatibility_hint", defaultValue: "Model discovery only lists identifiers; it does not guarantee TTT compatibility.", locale: locale)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text(EntrevoixLocalization.text("prompts.settings_hint", defaultValue: "Manage prompt names, icons, and instructions in the Prompts section.", locale: locale))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .settingsGroupedFormContentMargins()
    }
}

enum PromptDestination: Hashable {
    case edit(UUID, token: UUID)
    case create(UUID)
}

enum PromptPendingAction {
    case back
    case leaveSettings(SettingsSection?)
}

@MainActor
@Observable
final class PromptLibraryNavigationState {
    var path: [PromptDestination] = []
    var draft: CleanupPrompt?
    var originalDraft: CleanupPrompt?
    var validationError: CleanupPromptValidationError?
    var pendingAction: PromptPendingAction?
    var showUnsavedConfirmation = false
    var showDeleteConfirmation = false
    var showResetConfirmation = false

    var isDirty: Bool { draft != originalDraft }

    func openPrompt(_ id: UUID) {
        path.append(.edit(id, token: UUID()))
    }

    func beginEditing(_ id: UUID, model: AppStore) {
        guard draft?.id != id || originalDraft == nil else { return }
        draft = model.preferences.cleanupPrompts.first { $0.id == id }
        originalDraft = draft
        validationError = nil
    }

    func beginCreating(_ id: UUID) {
        guard draft?.id != id else { return }
        draft = CleanupPrompt(id: id, name: "", systemImageName: "sparkles", instructions: "")
        originalDraft = nil
        validationError = nil
    }

    @discardableResult
    func save(model: AppStore) -> Bool {
        guard let draft else { return true }
        if let validationError = model.saveCleanupPrompt(draft) {
            self.validationError = validationError
            return false
        }
        let savedDraft = model.preferences.cleanupPrompts.first { $0.id == draft.id }
        self.draft = savedDraft
        originalDraft = savedDraft
        self.validationError = nil
        return true
    }

    func discard() {
        draft = originalDraft
        validationError = nil
    }

    func resetTransientState() {
        path.removeAll()
        draft = nil
        originalDraft = nil
        validationError = nil
        pendingAction = nil
        showUnsavedConfirmation = false
        showDeleteConfirmation = false
        showResetConfirmation = false
    }
}

struct PromptLibraryView: View {
    @Bindable var model: AppStore
    @Bindable var state: PromptLibraryNavigationState
    let onLeaveSettings: (SettingsSection?) -> Void

    var body: some View {
        let locale = model.interfaceLocale
        NavigationStack(path: $state.path) {
            PromptListPage(model: model, state: state)
                .navigationDestination(for: PromptDestination.self) { destination in
                    PromptEditorPage(model: model, state: state, destination: destination)
                }
        }
        .alert(EntrevoixLocalization.text("prompts.unsaved_title", defaultValue: "Unsaved changes", locale: locale), isPresented: $state.showUnsavedConfirmation) {
            Button(EntrevoixLocalization.text("action.save", defaultValue: "Save", locale: locale)) {
                guard state.save(model: model) else {
                    state.showUnsavedConfirmation = true
                    return
                }
                resolvePendingAction(discard: false)
            }
            Button(EntrevoixLocalization.text("action.discard", defaultValue: "Discard", locale: locale), role: .destructive) {
                resolvePendingAction(discard: true)
            }
            Button(EntrevoixLocalization.text("action.cancel", defaultValue: "Cancel", locale: locale), role: .cancel) {
                state.pendingAction = nil
            }
        } message: {
            Text(EntrevoixLocalization.text("prompts.unsaved_message", defaultValue: "Save your changes before leaving this prompt?", locale: locale))
        }
        .onChange(of: model.preferences.cleanupPrompts) { _, prompts in
            guard let draftID = state.draft?.id,
                  prompts.contains(where: { $0.id == draftID }) else { return }
            if !state.isDirty {
                state.beginEditing(draftID, model: model)
            }
        }
    }

    private func resolvePendingAction(discard: Bool) {
        if discard { state.discard() }
        let action = state.pendingAction
        state.pendingAction = nil
        switch action {
        case .back:
            state.path.removeLast()
        case .leaveSettings(let section):
            state.resetTransientState()
            onLeaveSettings(section)
        case nil:
            break
        }
    }
}

private struct PromptListPage: View {
    @Bindable var model: AppStore
    @Bindable var state: PromptLibraryNavigationState
    @State private var searchText = ""

    private var filteredPrompts: [CleanupPrompt] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.preferences.cleanupPrompts }
        return model.preferences.cleanupPrompts.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.instructions.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let locale = model.interfaceLocale
        List {
            SettingsLibraryHeader(
                title: EntrevoixLocalization.text("settings.prompts", defaultValue: "Prompts", locale: locale),
                description: EntrevoixLocalization.text(
                    "prompts.description",
                    defaultValue: "Create reusable instructions to refine your dictations.",
                    locale: locale
                ),
                systemImage: "text.badge.checkmark"
            )

            if filteredPrompts.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty
                        ? EntrevoixLocalization.text("prompts.none", defaultValue: "No prompts saved", locale: locale)
                        : EntrevoixLocalization.text("library.no_results", defaultValue: "No matching items", locale: locale),
                    systemImage: "text.badge.checkmark"
                )
            } else {
                ForEach(filteredPrompts) { prompt in
                    Button {
                        state.openPrompt(prompt.id)
                    } label: {
                        SettingsLibraryRow(
                            title: prompt.name,
                            systemImage: prompt.systemImageName,
                            detail: prompt.instructions,
                            status: model.promptLibrary.activeSelection == .prompt(prompt.id)
                                ? .active(EntrevoixLocalization.text("library.active", defaultValue: "Active", locale: locale))
                                : nil,
                            showsDisclosure: true
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .listRowSeparator(prompt.id == filteredPrompts.last?.id ? .hidden : .visible, edges: .bottom)
                }
            }

            Section {
                Button {
                    if model.cleanupPromptLibraryDiffersFromDefault {
                        state.showResetConfirmation = true
                    } else {
                        model.resetPromptLibrary()
                    }
                } label: {
                    Label(EntrevoixLocalization.text("prompts.reset", defaultValue: "Reset List", locale: locale), systemImage: "arrow.counterclockwise")
                }
                .disabled(state.isDirty)
                .listRowSeparator(.hidden, edges: .bottom)
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.inset)
        .settingsPageContentMargins()
        .scrollBounceBehavior(.always)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .contentMargins(.bottom, SettingsLayout.pageInset, for: .scrollContent)
        .navigationBarBackButtonHidden(true)
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: EntrevoixLocalization.text("library.search", defaultValue: "Search…", locale: locale)
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let id = UUID()
                    state.beginCreating(id)
                    state.path.append(.create(id))
                } label: {
                    Label(
                        EntrevoixLocalization.text("prompts.add", defaultValue: "Add", locale: locale),
                        systemImage: "plus"
                    )
                }
                .disabled(state.isDirty)
            }
        }
        .alert(EntrevoixLocalization.text("prompts.reset_title", defaultValue: "Reset prompt list?", locale: locale), isPresented: $state.showResetConfirmation) {
            Button(EntrevoixLocalization.text("prompts.reset", defaultValue: "Reset List", locale: locale), role: .destructive) {
                model.resetPromptLibrary()
            }
            Button(EntrevoixLocalization.text("action.cancel", defaultValue: "Cancel", locale: locale), role: .cancel) { }
        } message: {
            Text(EntrevoixLocalization.text("prompts.reset_message", defaultValue: "This replaces the current prompt list with the localized example prompt.", locale: locale))
        }
    }
}

private struct PromptEditorPage: View {
    @Bindable var model: AppStore
    @Bindable var state: PromptLibraryNavigationState
    let destination: PromptDestination

    var body: some View {
        let locale = model.interfaceLocale
        editorContent(locale: locale)
        .navigationTitle(isExistingPrompt
            ? EntrevoixLocalization.text("prompts.edit_title", defaultValue: "Edit Prompt", locale: locale)
            : EntrevoixLocalization.text("prompts.new_title", defaultValue: "New Prompt", locale: locale))
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: ToolbarItemPlacement.navigation) {
                Button(action: requestBack) {
                    Image(systemName: "chevron.left")
                        .accessibilityLabel(EntrevoixLocalization.text("action.back", defaultValue: "Back", locale: locale))
                }
            }
        }
        .onAppear {
            switch destination {
            case .edit(let id, _): state.beginEditing(id, model: model)
            case .create(let id): state.beginCreating(id)
            }
        }
        .alert(EntrevoixLocalization.text("prompts.delete_title", defaultValue: "Delete prompt?", locale: locale), isPresented: $state.showDeleteConfirmation) {
            Button(EntrevoixLocalization.text("prompts.delete", defaultValue: "Delete", locale: locale), role: .destructive) {
                deleteAndReturn()
            }
            Button(EntrevoixLocalization.text("action.cancel", defaultValue: "Cancel", locale: locale), role: .cancel) { }
        }
    }

    private var isExistingPrompt: Bool {
        if case .edit = destination { return true }
        return false
    }

    @ViewBuilder
    private func editorContent(locale: Locale) -> some View {
        if state.draft != nil {
            PromptEditor(
                draft: Binding(get: { state.draft! }, set: { state.draft = $0 }),
                error: $state.validationError,
                onSave: saveAndReturn,
                onCancel: requestCancel,
                onDelete: requestDelete,
                showsDelete: isExistingPrompt,
                locale: locale
            )
        } else {
            ContentUnavailableView(
                EntrevoixLocalization.text("prompts.select", defaultValue: "Select a prompt", locale: locale),
                systemImage: "text.badge.checkmark"
            )
        }
    }

    private func saveAndReturn() {
        guard state.save(model: model) else { return }
        state.path.removeLast()
    }

    private func requestCancel() {
        requestBack()
    }

    private func requestBack() {
        if state.isDirty {
            state.pendingAction = .back
            state.showUnsavedConfirmation = true
        } else {
            state.discard()
            state.path.removeLast()
        }
    }

    private func requestDelete() {
        state.showDeleteConfirmation = true
    }

    private func deleteAndReturn() {
        guard let id = state.draft?.id else { return }
        model.deleteCleanupPrompt(id: id)
        state.resetTransientState()
    }
}

private struct PromptEditor: View {
    @Binding var draft: CleanupPrompt
    @Binding var error: CleanupPromptValidationError?
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    let showsDelete: Bool
    let locale: Locale

    var body: some View {
        Form {
            Section(EntrevoixLocalization.text("prompts.details", defaultValue: "Prompt details", locale: locale)) {
                TextField(EntrevoixLocalization.text("field.name", defaultValue: "Name", locale: locale), text: $draft.name)
                Picker(EntrevoixLocalization.text("prompts.icon", defaultValue: "Icon", locale: locale), selection: $draft.systemImageName) {
                    ForEach(PromptIcon.allCases) { icon in
                        Label(icon.label(locale: locale), systemImage: icon.rawValue).tag(icon.rawValue)
                    }
                }
            }
            Section(EntrevoixLocalization.text("prompts.instructions", defaultValue: "Instructions", locale: locale)) {
                TextEditor(text: $draft.instructions)
                    .font(.body)
                    .frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 1))
                if let error {
                    Label(error.message(locale: locale), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            if showsDelete {
                Section {
                    Button(role: .destructive, action: onDelete) {
                        Label(EntrevoixLocalization.text("prompts.delete", defaultValue: "Delete", locale: locale), systemImage: "trash")
                    }
                }
            }
            HStack {
                Spacer()
                Button(EntrevoixLocalization.text("action.cancel", defaultValue: "Cancel", locale: locale), action: onCancel)
                Button(EntrevoixLocalization.text("action.save", defaultValue: "Save", locale: locale), action: onSave)
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .settingsGroupedFormContentMargins()
    }
}

private enum PromptIcon: String, CaseIterable, Identifiable {
    case wandAndStars = "wand.and.stars"
    case sparkles
    case textBadgeCheckmark = "text.badge.checkmark"
    case docText = "doc.text"
    case envelope
    case message
    case briefcase
    case graduationcap
    case terminal
    case quoteBubble = "quote.bubble"

    var id: Self { self }

    func label(locale: Locale) -> String {
        switch self {
        case .wandAndStars: "Wand and stars"
        case .sparkles: "Sparkles"
        case .textBadgeCheckmark: "Checked text"
        case .docText: "Document"
        case .envelope: "Envelope"
        case .message: "Message"
        case .briefcase: "Briefcase"
        case .graduationcap: "Graduation cap"
        case .terminal: "Terminal"
        case .quoteBubble: "Quote bubble"
        }
    }
}

private extension CleanupPromptValidationError {
    func message(locale: Locale) -> String {
        switch self {
        case .emptyName: EntrevoixLocalization.text("prompts.error_name", defaultValue: "A prompt name is required.", locale: locale)
        case .duplicateName: EntrevoixLocalization.text("prompts.error_duplicate", defaultValue: "Prompt names must be unique.", locale: locale)
        case .emptyInstructions: EntrevoixLocalization.text("prompts.error_instructions", defaultValue: "Prompt instructions are required.", locale: locale)
        case .invalidIcon: EntrevoixLocalization.text("prompts.error_icon", defaultValue: "Choose an icon from the available palette.", locale: locale)
        }
    }
}

@ViewBuilder
private func providerValidation(for provider: ProviderConfiguration, apiKey: String, locale: Locale) -> some View {
    if let issue = provider.validationIssues(apiKey: apiKey).first {
        Label(issue.localizedTitle(locale: locale), systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .font(.caption)
    }
}

private extension ProviderValidationIssue {
    func localizedTitle(locale: Locale) -> String {
        switch self {
        case .missingName: "A provider name is required."
        case .duplicateName: "Provider names must be unique."
        case .invalidEndpoint: EntrevoixLocalization.text("validation.invalid_url", defaultValue: "Invalid URL: use http:// or https://", locale: locale)
        case .missingCapability: "Select at least one capability."
        case .missingRoute: "A route is required for each capability."
        case .missingModel: EntrevoixLocalization.text("validation.model_required", defaultValue: "A model is required.", locale: locale)
        case .missingHeaderName: EntrevoixLocalization.text("validation.header_required", defaultValue: "An authentication header name is required.", locale: locale)
        case .missingAPIKey: EntrevoixLocalization.text("validation.api_key_required", defaultValue: "An API key is required for this authentication mode.", locale: locale)
        }
    }
}
