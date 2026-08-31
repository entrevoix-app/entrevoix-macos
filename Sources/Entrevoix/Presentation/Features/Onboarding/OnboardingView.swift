import KeyboardShortcuts
import EntrevoixCore
import SwiftUI

struct OnboardingView: View {
    @Bindable var model: AppStore
    @Environment(ProviderStore.self) private var providers
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0

    private let stepCount = 5

    var body: some View {
        let locale = model.interfaceLocale

        VStack(alignment: .leading, spacing: 20) {
            ProgressView(value: Double(step + 1), total: Double(stepCount))
                .accessibilityLabel(EntrevoixLocalization.onboardingStep(step + 1, total: stepCount, locale: locale))

            Group {
                switch step {
                case 0: welcome
                case 1: sttConfiguration
                case 2: connectionTest
                case 3: shortcut
                default: delivery
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if step > 0 {
                    Button(EntrevoixLocalization.text("action.back", defaultValue: "Back", locale: locale)) { step -= 1 }
                }
                Spacer()
                if step < stepCount - 1 {
                    Button(EntrevoixLocalization.text("action.next", defaultValue: "Next", locale: locale)) {
                        if step == 1 {
                            providers.commitConfiguration()
                        } else {
                            model.savePreferences()
                        }
                        step += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(step == 1 && !isSTTConfigurationValid)
                } else {
                    Button(EntrevoixLocalization.text("action.finish", defaultValue: "Finish", locale: locale)) {
                        model.completeOnboarding()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(width: 620, height: 500)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(EntrevoixLocalization.text("onboarding.welcome.title", defaultValue: "Welcome to Entrevoix", locale: model.interfaceLocale), systemImage: "waveform")
                .font(.largeTitle.bold())
            Text(EntrevoixLocalization.text("onboarding.welcome.description", defaultValue: "Entrevoix records your voice locally, then sends the short audio file to your chosen STT provider. A second provider can then clean up the text if you enable that option.", locale: model.interfaceLocale))
            Text(EntrevoixLocalization.text("onboarding.welcome.privacy", defaultValue: "API keys stay in the macOS Keychain. Audio recordings are deleted after transcription by default, but you can choose to retain them. Entrevoix has no servers or user accounts of its own.", locale: model.interfaceLocale))
                .foregroundStyle(.secondary)
            Label(EntrevoixLocalization.text("onboarding.welcome.settings_hint", defaultValue: "You can change all of these choices later in Settings.", locale: model.interfaceLocale), systemImage: "gear")
                .font(.callout)
            Picker(
                EntrevoixLocalization.text("settings.interface_language", defaultValue: "Interface language", locale: model.interfaceLocale),
                selection: Binding(
                    get: { model.preferences.interfaceLanguage },
                    set: { model.setInterfaceLanguage($0) }
                )
            ) {
                ForEach(InterfaceLanguage.allCases) { language in
                    Text(language.title(locale: model.interfaceLocale)).tag(language)
                }
            }
        }
    }

    private var sttConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(EntrevoixLocalization.text("onboarding.transcription.title", defaultValue: "Transcription connection", locale: model.interfaceLocale))
                .font(.title2.bold())
            Text(EntrevoixLocalization.text(
                "onboarding.transcription.description",
                defaultValue: "Choose a ready transcription provider. You can add and edit remote providers later in Settings.",
                locale: model.interfaceLocale
            ))
                .foregroundStyle(.secondary)
            Picker(EntrevoixLocalization.text("field.stt_provider", defaultValue: "STT provider", locale: model.interfaceLocale), selection: Binding(get: { model.preferences.selectedSTTProviderID }, set: { model.setSTTProvider($0) })) {
                Text(EntrevoixLocalization.text("provider.choose", defaultValue: "Choose a provider", locale: model.interfaceLocale)).tag(Optional<ProviderIdentifier>.none)
                ForEach(model.providersSortedForDisplay.filter { $0.id == .apple || $0.remoteProfile?.stt != nil }) { entry in
                    Text(model.providerName(entry)).tag(Optional(entry.id))
                }
            }
            HStack {
                Button(EntrevoixLocalization.text("provider.add_apple", defaultValue: "Add Apple (local)", locale: model.interfaceLocale)) { model.addAppleProvider(); model.setSTTProvider(.apple) }
                    .disabled(model.preferences.providerCatalog.contains { $0.id == .apple })
                Button(EntrevoixLocalization.text("provider.add_openai", defaultValue: "Add OpenAI", locale: model.interfaceLocale)) {
                    _ = providers.addOpenAIProviderForOnboarding()
                }
            }
            if model.preferences.selectedSTTProviderID == .apple {
                Label(EntrevoixLocalization.text(
                    "provider.apple_speech_onboarding_hint",
                    defaultValue: "Apple Speech requires a supported, downloaded speech asset. Choose a language below.",
                    locale: model.interfaceLocale
                ), systemImage: "apple.logo")
                    .foregroundStyle(.secondary)
            } else if let selectedProvider = model.preferences.selectedSTTProviderID,
                      model.preferences.remoteProfile(for: selectedProvider)?.authentication != AuthenticationMode.none {
                SecureField(EntrevoixLocalization.text("field.api_key", defaultValue: "API key", locale: model.interfaceLocale), text: Binding(
                    get: { providers.apiKey(for: selectedProvider) },
                    set: { providers.setAPIKey($0, for: selectedProvider) }
                ))
            }
            Picker(EntrevoixLocalization.text("field.stt_language", defaultValue: "Transcription language", locale: model.interfaceLocale), selection: Binding(
                get: { model.preferences.sttLanguage },
                set: { model.setSTTLanguage($0) }
            )) {
                ForEach(TranscriptionLanguage.sortedForDisplay(locale: model.interfaceLocale, includingAutomatic: model.preferences.selectedSTTProviderID != .apple)) { language in
                    Text(language.title(locale: model.interfaceLocale)).tag(language)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var connectionTest: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(EntrevoixLocalization.text("onboarding.connection.title", defaultValue: "Test the connection", locale: model.interfaceLocale))
                .font(.title2.bold())
            Text(EntrevoixLocalization.text("onboarding.connection.description", defaultValue: "This test is optional: speak a short phrase, then Entrevoix will send it to your STT provider. The test transcription is not retained.", locale: model.interfaceLocale))
                .foregroundStyle(.secondary)
            ConnectionTestControls(model: model.connectionTestStore)
            if model.microphonePermission != .granted {
                Button(EntrevoixLocalization.text("permission.allow_microphone", defaultValue: "Allow Microphone Access", locale: model.interfaceLocale)) {
                    model.requestMicrophonePermission()
                }
            }
        }
    }

    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(EntrevoixLocalization.text("onboarding.shortcut.title", defaultValue: "Global shortcut", locale: model.interfaceLocale))
                .font(.title2.bold())
            Text(EntrevoixLocalization.text("onboarding.shortcut.description", defaultValue: "Choose the shortcut that will trigger Entrevoix, even when another app is in the foreground.", locale: model.interfaceLocale))
                .foregroundStyle(.secondary)
            KeyboardShortcuts.Recorder(EntrevoixLocalization.text("field.shortcut", defaultValue: "Shortcut:", locale: model.interfaceLocale), name: .dictation)
            Picker(EntrevoixLocalization.text("menu.mode", defaultValue: "Mode", locale: model.interfaceLocale), selection: Binding(
                get: { model.mode },
                set: { model.setMode($0) }
            )) {
                ForEach(TriggerMode.allCases) { mode in
                    Text(mode.title(locale: model.interfaceLocale)).tag(mode)
                }
            }
        }
    }

    private var delivery: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(EntrevoixLocalization.text("onboarding.delivery.title", defaultValue: "Delivery and preferences", locale: model.interfaceLocale))
                .font(.title2.bold())
            Picker(EntrevoixLocalization.text("field.dictation_output", defaultValue: "Dictation output", locale: model.interfaceLocale), selection: $model.preferences.outputMode) {
                ForEach(OutputMode.allCases) { Text($0.title(locale: model.interfaceLocale)).tag($0) }
            }
            if model.preferences.outputMode == .paste {
                Text(EntrevoixLocalization.text("permission.accessibility_insertion_hint", defaultValue: "Automatic insertion requires Accessibility permission. Without it, the text will be copied to the clipboard.", locale: model.interfaceLocale))
                    .foregroundStyle(.secondary)
                if model.accessibilityPermission != .granted {
                    Button(EntrevoixLocalization.text("permission.allow_accessibility", defaultValue: "Allow Automatic Insertion", locale: model.interfaceLocale)) {
                        model.requestAccessibilityPermission()
                    }
                }
            }
            Toggle(EntrevoixLocalization.text("settings.launch_at_login", defaultValue: "Launch Entrevoix at login", locale: model.interfaceLocale), isOn: Binding(
                get: { model.launchAtLoginEnabled },
                set: { model.setLaunchAtLogin($0) }
            ))
            Toggle(EntrevoixLocalization.text("settings.play_feedback", defaultValue: "Play a sound when dictation starts and ends", locale: model.interfaceLocale), isOn: $model.preferences.playFeedbackSounds)
        }
    }

    private var isSTTConfigurationValid: Bool {
        guard let entry = model.preferences.provider(for: model.preferences.selectedSTTProviderID) else { return false }
        switch entry {
        case .apple: return model.preferences.sttLanguage != .automatic
        case .codex: return false
        case .remote(let profile): return profile.stt != nil && profile.validationIssues(apiKey: model.apiKey(for: .remote(profile.id))).isEmpty
        }
    }
}
