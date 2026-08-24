import Foundation
import EntrevoixCore
import Observation

@MainActor
@Observable
final class PromptLibraryStore {
    private let preferencesModel: PreferencesStore
    private let exportReader: any CleanupPromptExportReading

    init(
        preferencesModel: PreferencesStore,
        exportReader: any CleanupPromptExportReading
    ) {
        self.preferencesModel = preferencesModel
        self.exportReader = exportReader
    }

    var activePrompt: CleanupPrompt? {
        guard case .prompt(let activeID) = preferences.activeCleanupSelection else { return nil }
        return preferences.cleanupPrompts.first { $0.id == activeID }
    }

    var activeWorkflow: CleanupWorkflow? {
        guard case .workflow(let activeID) = preferences.activeCleanupSelection else { return nil }
        return preferences.cleanupWorkflows.first { $0.id == activeID && $0.isValid }
    }

    var activeSelection: CleanupTransformationSelection? { preferences.activeCleanupSelection }

    func makeExport() -> CleanupPromptExport {
        CleanupPromptExport(prompts: preferences.cleanupPrompts)
    }

    func importPrompts(from url: URL) -> Result<CleanupPromptImportResult, CleanupPromptImportError> {
        do {
            let export = try exportReader.readExport(at: url)
            let result = CleanupPromptLibrary.importing(export.prompts, into: preferences.cleanupPrompts)
            guard !result.importedPrompts.isEmpty else { return .success(result) }

            preferences.cleanupPrompts.append(contentsOf: result.importedPrompts)
            if preferences.activeCleanupSelection == nil, let first = result.importedPrompts.first {
                preferences.activeCleanupSelection = .prompt(first.id)
                preferences.cleanupPrompt = first.instructions
                preferences.cleanupPromptMode = .custom
            }
            preferencesModel.savePreferencesImmediately()
            return .success(result)
        } catch let error {
            return .failure(error)
        }
    }

    var differsFromDefault: Bool {
        guard preferences.cleanupPrompts.count == 1,
              let prompt = preferences.cleanupPrompts.first else { return true }
        return prompt.name != "Standard"
            || prompt.systemImageName != "wand.and.stars"
            || prompt.instructions != EntrevoixLocalization.defaultCleanupPrompt(locale: interfaceLocale)
    }

    func setActive(_ id: UUID?) {
        let selection = id.map(CleanupTransformationSelection.prompt)
        setActiveSelection(selection)
    }

    func setActiveWorkflow(_ id: UUID?) {
        let selection = id.map(CleanupTransformationSelection.workflow)
        setActiveSelection(selection)
    }

    func setActiveSelection(_ selection: CleanupTransformationSelection?) {
        guard selection == nil || preferences.isValidCleanupSelection(selection) else { return }
        guard preferences.activeCleanupSelection != selection else { return }
        preferences.activeCleanupSelection = selection
        if let activePrompt {
            preferences.cleanupPrompt = activePrompt.instructions
            preferences.cleanupPromptMode = .custom
        }
        preferencesModel.savePreferencesImmediately()
    }

    @discardableResult
    func save(_ prompt: CleanupPrompt) -> CleanupPromptValidationError? {
        let value: CleanupPrompt
        switch CleanupPromptLibrary.validatedSaving(prompt, into: preferences.cleanupPrompts) {
        case .success(let prompt): value = prompt
        case .failure(let error): return error
        }
        if let index = preferences.cleanupPrompts.firstIndex(where: { $0.id == prompt.id }) {
            preferences.cleanupPrompts[index] = value
        } else {
            preferences.cleanupPrompts.append(value)
        }
        if preferences.activeCleanupSelection == nil {
            preferences.activeCleanupSelection = .prompt(value.id)
        }
        if preferences.activeCleanupPromptID == value.id {
            preferences.cleanupPrompt = value.instructions
            preferences.cleanupPromptMode = .custom
        }
        preferencesModel.savePreferencesImmediately()
        return nil
    }

    func delete(id: UUID) {
        guard let index = preferences.cleanupPrompts.firstIndex(where: { $0.id == id }) else { return }
        preferences.cleanupPrompts.remove(at: index)
        removePromptReferences(id: id)
        preferences.normalizeCleanupSelection()
        synchronizeLegacyPrompt()
        preferencesModel.savePreferencesImmediately()
    }

    @discardableResult
    func saveWorkflow(_ workflow: CleanupWorkflow) -> CleanupWorkflowValidationError? {
        guard workflow.promptIDs.allSatisfy({ id in preferences.cleanupPrompts.contains(where: { $0.id == id }) }) else {
            return .missingPrompt
        }
        let value: CleanupWorkflow
        switch CleanupWorkflowLibrary.validatedSaving(workflow, into: preferences.cleanupWorkflows) {
        case .success(let workflow): value = workflow
        case .failure(let error): return error
        }
        if let index = preferences.cleanupWorkflows.firstIndex(where: { $0.id == value.id }) {
            preferences.cleanupWorkflows[index] = value
        } else {
            preferences.cleanupWorkflows.append(value)
        }
        if preferences.activeCleanupSelection == nil {
            preferences.activeCleanupSelection = .workflow(value.id)
        }
        preferencesModel.savePreferencesImmediately()
        return nil
    }

    func deleteWorkflow(id: UUID) {
        guard let index = preferences.cleanupWorkflows.firstIndex(where: { $0.id == id }) else { return }
        preferences.cleanupWorkflows.remove(at: index)
        preferences.normalizeCleanupSelection()
        synchronizeLegacyPrompt()
        preferencesModel.savePreferencesImmediately()
    }

    func reset() {
        let prompt = CleanupPrompt(
            id: AppPreferences.defaultCleanupPromptID,
            name: "Standard",
            systemImageName: "wand.and.stars",
            instructions: EntrevoixLocalization.defaultCleanupPrompt(locale: interfaceLocale)
        )
        preferences.cleanupPrompts = [prompt]
        preferences.cleanupWorkflows = preferences.cleanupWorkflows.map { workflow in
            var value = workflow
            value.promptIDs = []
            return value
        }
        preferences.activeCleanupSelection = .prompt(prompt.id)
        preferences.cleanupPrompt = prompt.instructions
        preferences.cleanupPromptMode = .localizedDefault
        preferencesModel.savePreferencesImmediately()
    }

    private var preferences: AppPreferences {
        get { preferencesModel.preferences }
        set { preferencesModel.update(newValue, to: .immediate) }
    }

    private var interfaceLocale: Locale {
        EntrevoixLocalization.locale(for: preferences.interfaceLanguage)
    }

    private func removePromptReferences(id: UUID) {
        preferences.cleanupWorkflows = preferences.cleanupWorkflows.map { workflow in
            var value = workflow
            value.promptIDs.removeAll { $0 == id }
            return value
        }
    }

    private func synchronizeLegacyPrompt() {
        guard let activePrompt else { return }
        preferences.cleanupPrompt = activePrompt.instructions
        preferences.cleanupPromptMode = .custom
    }
}
