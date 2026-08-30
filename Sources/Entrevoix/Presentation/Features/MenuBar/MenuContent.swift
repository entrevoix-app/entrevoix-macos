import AppKit
import EntrevoixCore
import SwiftUI

struct MenuContent: View {
    @Bindable var model: AppStore
    let openUserFacingWindow: (String) -> Void

    var body: some View {
        let locale = model.interfaceLocale

        Menu(EntrevoixLocalization.text("menu.language", defaultValue: "Language", locale: locale)) {
            if model.preferences.selectedSTTProviderID != .apple {
                Button {
                    model.setSTTLanguage(.automatic)
                } label: {
                    languageMenuLabel(.automatic, locale: locale, isSelected: model.preferences.sttLanguage == .automatic)
                }
            }

            if !model.preferences.sttFavoriteLanguages.isEmpty {
                Divider()
                ForEach(TranscriptionLanguage.sortedForDisplay(locale: locale, includingAutomatic: false).filter { model.preferences.sttFavoriteLanguages.contains($0) }) { language in
                    Button {
                        model.setSTTLanguage(language)
                    } label: {
                        languageMenuLabel(language, locale: locale, isSelected: model.preferences.sttLanguage == language)
                    }
                }
            }
        }

        Menu(EntrevoixLocalization.text("menu.mode", defaultValue: "Mode", locale: locale)) {
            ForEach(TriggerMode.allCases) { mode in
                Button {
                    model.setMode(mode)
                } label: {
                    if model.mode == mode {
                        Label(mode.title(locale: locale), systemImage: "checkmark")
                    } else {
                        Text(mode.title(locale: locale))
                    }
                }
            }
        }

        Menu(EntrevoixLocalization.text("field.audio_input", defaultValue: "Microphone", locale: locale)) {
            Button {
                model.audioInput.setSelection(.systemDefault)
            } label: {
                audioInputMenuLabel(
                    systemDefaultInputTitle(locale: locale),
                    selection: .systemDefault,
                    locale: locale
                )
            }

            if !model.audioInput.devices.isEmpty {
                Divider()
                ForEach(model.audioInput.devices) { device in
                    Button {
                        model.audioInput.setSelection(.device(device))
                    } label: {
                        audioInputMenuLabel(
                            device.name,
                            selection: .device(device),
                            locale: locale
                        )
                    }
                }
            }

            if let unavailableDevice = model.audioInput.unavailableSelection {
                Divider()
                Button {} label: {
                    audioInputMenuLabel(
                        unavailableInputTitle(unavailableDevice.name, locale: locale),
                        selection: .device(unavailableDevice),
                        locale: locale
                    )
                }
                .disabled(true)
            }
        }

        Menu(EntrevoixLocalization.text("menu.prompt", defaultValue: "Prompt", locale: locale)) {
            Section(EntrevoixLocalization.text("menu.prompts_group", defaultValue: "Prompts", locale: locale)) {
                if model.preferences.cleanupPrompts.isEmpty {
                    Text(EntrevoixLocalization.text("prompts.none", defaultValue: "No prompts saved", locale: locale))
                } else {
                    ForEach(model.preferences.cleanupPrompts) { prompt in
                        Button {
                            model.setActiveCleanupPrompt(prompt.id)
                        } label: {
                            transformationMenuLabel(
                                prompt.name,
                                selection: .prompt(prompt.id),
                                locale: locale
                            )
                        }
                    }
                }
            }
            Section(EntrevoixLocalization.text("menu.workflows_group", defaultValue: "Workflows", locale: locale)) {
                if model.preferences.cleanupWorkflows.isEmpty {
                    Text(EntrevoixLocalization.text("workflows.none", defaultValue: "No workflows saved", locale: locale))
                } else {
                    ForEach(model.preferences.cleanupWorkflows) { workflow in
                        Button {
                            model.setActiveCleanupWorkflow(workflow.id)
                        } label: {
                            transformationMenuLabel(
                                workflow.name,
                                selection: .workflow(workflow.id),
                                locale: locale
                            )
                        }
                        .disabled(!workflow.isValid)
                    }
                }
            }
            Divider()
            Text(
                model.preferences.cleanupEnabled
                    ? EntrevoixLocalization.text("menu.prompt_enabled", defaultValue: "TTT cleanup enabled", locale: locale)
                    : EntrevoixLocalization.text("menu.prompt_disabled", defaultValue: "TTT cleanup disabled", locale: locale)
            )
            .foregroundStyle(.secondary)
        }

        Divider()

        Button {
            openUserFacingWindow("settings")
        } label: {
            Label(EntrevoixLocalization.text("menu.settings", defaultValue: "Settings", locale: locale), systemImage: "gear")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button {
            openUserFacingWindow("logs")
        } label: {
            Label(EntrevoixLocalization.text("menu.logs", defaultValue: "Logs", locale: locale), systemImage: "terminal")
        }

        Button {
            openUserFacingWindow("onboarding")
        } label: {
            Label(EntrevoixLocalization.text("menu.getting_started", defaultValue: "Getting Started", locale: locale), systemImage: "questionmark.circle")
        }

        Divider()

        Button(EntrevoixLocalization.text("menu.check_for_updates", defaultValue: "Check for Updates…", locale: locale)) {
            model.updates.checkForUpdates()
        }

        Button(EntrevoixLocalization.text("menu.quit", defaultValue: "Quit", locale: locale)) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func audioInputMenuLabel(
        _ title: String,
        selection: AudioInputSelection,
        locale: Locale
    ) -> some View {
        HStack {
            Text(title)
            if model.audioInput.selection == selection {
                Spacer()
                Image(systemName: "checkmark")
                    .accessibilityLabel(EntrevoixLocalization.text("accessibility.selected", defaultValue: "Selected", locale: locale))
            }
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

    private func languageMenuLabel(_ language: TranscriptionLanguage, locale: Locale, isSelected: Bool) -> some View {
        HStack {
            Text(language.title(locale: locale))
            if isSelected {
                Spacer()
                Image(systemName: "checkmark")
            }
        }
    }

    private func transformationMenuLabel(
        _ name: String,
        selection: CleanupTransformationSelection,
        locale: Locale
    ) -> some View {
        HStack {
            Text(name)
            if model.promptLibrary.activeSelection == selection {
                Spacer()
                Image(systemName: "checkmark")
                    .accessibilityLabel(EntrevoixLocalization.text("accessibility.selected", defaultValue: "Selected", locale: locale))
            }
        }
    }
}
