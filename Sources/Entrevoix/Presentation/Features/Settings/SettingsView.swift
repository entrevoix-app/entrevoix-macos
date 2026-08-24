import EntrevoixCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppStore
    @State private var selection: SettingsSection? = .general
    @State private var promptNavigation = PromptLibraryNavigationState()

    var body: some View {
        NavigationSplitView {
            settingsSidebar
        } detail: {
            settingsDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle((selection ?? .general).title(locale: model.interfaceLocale))
        .frame(minWidth: 760, idealWidth: 920, minHeight: 520, idealHeight: 700)
    }

    private var settingsSidebar: some View {
        List(selection: settingsSelection) {
            Section(EntrevoixLocalization.text("settings.sidebar.application", defaultValue: "Application", locale: model.interfaceLocale)) {
                settingsRow(.general)
            }

            Section(EntrevoixLocalization.text("settings.sidebar.processing", defaultValue: "Processing", locale: model.interfaceLocale)) {
                settingsRow(.providers)
                settingsRow(.stt)
                settingsRow(.cleanup)
            }

            Section(EntrevoixLocalization.text("settings.sidebar.customization", defaultValue: "Customization", locale: model.interfaceLocale)) {
                settingsRow(.dictationDictionary)
                settingsRow(.prompts)
                settingsRow(.workflows)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    }

    private func settingsRow(_ section: SettingsSection) -> some View {
        Label(section.title(locale: model.interfaceLocale), systemImage: section.systemImageName)
            .tag(section)
    }

    private var settingsSelection: Binding<SettingsSection?> {
        Binding(
            get: { selection },
            set: { newSelection in
                guard newSelection != selection else { return }
                if selection == .prompts, newSelection != .prompts, promptNavigation.isDirty {
                    promptNavigation.pendingAction = .leaveSettings(newSelection)
                    promptNavigation.showUnsavedConfirmation = true
                } else {
                    selection = newSelection
                    if newSelection != .prompts {
                        promptNavigation.resetTransientState()
                    }
                }
            }
        )
    }

    @ViewBuilder private var settingsDetail: some View {
        switch selection ?? .general {
        case .general:
            GeneralSettingsView(model: model)
        case .providers:
            ProvidersSettingsView()
        case .stt:
            STTSettingsView(model: model)
        case .dictationDictionary:
            DictationDictionaryView(model: model)
        case .cleanup:
            CleanupSettingsView(model: model)
        case .prompts:
            PromptLibraryView(model: model, state: promptNavigation) { newSelection in
                selection = newSelection
            }
        case .workflows:
            WorkflowLibraryView(model: model)
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case providers
    case stt
    case dictationDictionary
    case cleanup
    case prompts
    case workflows

    var id: Self { self }

    var systemImageName: String {
        switch self {
        case .general: "gearshape"
        case .providers: "network"
        case .stt: "waveform"
        case .dictationDictionary: "character.book.closed"
        case .cleanup: "wand.and.stars"
        case .prompts: "text.badge.checkmark"
        case .workflows: "point.3.connected.trianglepath.dotted"
        }
    }

    func title(locale: Locale) -> String {
        switch self {
        case .general: EntrevoixLocalization.text("settings.general", defaultValue: "General", locale: locale)
        case .providers: EntrevoixLocalization.text("settings.providers", defaultValue: "Providers", locale: locale)
        case .stt: EntrevoixLocalization.text("settings.stt", defaultValue: "STT Transcription", locale: locale)
        case .dictationDictionary: EntrevoixLocalization.text("settings.dictation_dictionary", defaultValue: "Dictation Dictionary", locale: locale)
        case .cleanup: EntrevoixLocalization.text("settings.ttt", defaultValue: "TTT Cleanup", locale: locale)
        case .prompts: EntrevoixLocalization.text("settings.prompts", defaultValue: "Prompts", locale: locale)
        case .workflows: EntrevoixLocalization.text("settings.workflows", defaultValue: "Workflows", locale: locale)
        }
    }
}
