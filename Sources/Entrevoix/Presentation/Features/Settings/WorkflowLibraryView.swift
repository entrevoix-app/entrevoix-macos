import EntrevoixCore
import Foundation
import Observation
import SwiftUI

private enum WorkflowDestination: Hashable {
    case edit(UUID, token: UUID)
    case create(UUID)
}

private struct WorkflowStepDraft: Identifiable, Equatable {
    let id: UUID
    let promptID: UUID
}

@MainActor
@Observable
private final class WorkflowLibraryNavigationState {
    var path: [WorkflowDestination] = []
    var draft: CleanupWorkflow?
    var originalDraft: CleanupWorkflow?
    var steps: [WorkflowStepDraft] = []
    var validationError: CleanupWorkflowValidationError?

    var isDirty: Bool {
        guard var draft else { return false }
        draft.promptIDs = steps.map(\.promptID)
        return draft != originalDraft
    }

    func beginEditing(_ id: UUID, model: AppStore) {
        guard let workflow = model.preferences.cleanupWorkflows.first(where: { $0.id == id }) else { return }
        draft = workflow
        originalDraft = workflow
        steps = workflow.promptIDs.map { WorkflowStepDraft(id: UUID(), promptID: $0) }
        validationError = nil
    }

    func beginCreating(_ id: UUID) {
        draft = CleanupWorkflow(id: id, name: "", promptIDs: [])
        originalDraft = nil
        steps = []
        validationError = nil
    }

    @discardableResult
    func save(model: AppStore) -> Bool {
        guard var draft else { return true }
        draft.promptIDs = steps.map(\.promptID)
        if let error = model.saveCleanupWorkflow(draft) {
            validationError = error
            return false
        }
        self.draft = draft
        originalDraft = draft
        validationError = nil
        return true
    }

    func add(promptID: UUID) {
        steps.append(WorkflowStepDraft(id: UUID(), promptID: promptID))
        validationError = nil
    }

    func remove(stepID: UUID) {
        steps.removeAll { $0.id == stepID }
    }

}

struct WorkflowLibraryView: View {
    @Bindable var model: AppStore
    @State private var navigation = WorkflowLibraryNavigationState()

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.path) {
            WorkflowListPage(model: model, navigation: navigation)
                .navigationDestination(for: WorkflowDestination.self) { destination in
                    WorkflowEditorPage(model: model, navigation: navigation, destination: destination)
                }
        }
    }
}

private struct WorkflowListPage: View {
    @Bindable var model: AppStore
    @Bindable var navigation: WorkflowLibraryNavigationState
    @State private var searchText = ""

    private var filteredWorkflows: [CleanupWorkflow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.preferences.cleanupWorkflows }
        return model.preferences.cleanupWorkflows.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let locale = model.interfaceLocale
        VStack(spacing: 0) {
            SettingsLibraryHeader(
                title: EntrevoixLocalization.text("settings.workflows", defaultValue: "Workflows", locale: locale),
                description: EntrevoixLocalization.text(
                    "workflows.description",
                    defaultValue: "Combine prompts into a sequence for more elaborate cleanups.",
                    locale: locale
                ),
                count: EntrevoixLocalization.workflowCount(model.preferences.cleanupWorkflows.count, locale: locale),
                searchPlaceholder: EntrevoixLocalization.text("library.search", defaultValue: "Search…", locale: locale),
                addAccessibilityLabel: EntrevoixLocalization.text("workflows.add", defaultValue: "Add", locale: locale),
                isAddDisabled: false,
                searchText: $searchText
            ) {
                let id = UUID()
                navigation.beginCreating(id)
                navigation.path.append(.create(id))
            }

            List {
                if filteredWorkflows.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty
                        ? EntrevoixLocalization.text("workflows.none", defaultValue: "No workflows saved", locale: locale)
                        : EntrevoixLocalization.text("library.no_results", defaultValue: "No matching items", locale: locale),
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            } else {
                ForEach(filteredWorkflows) { workflow in
                    Button {
                        navigation.beginEditing(workflow.id, model: model)
                        navigation.path.append(.edit(workflow.id, token: UUID()))
                    } label: {
                        SettingsLibraryRow(
                            title: workflow.name,
                            systemImage: "point.3.connected.trianglepath.dotted",
                            detail: EntrevoixLocalization.workflowStepCount(workflow.promptIDs.count, locale: locale),
                            status: workflowStatus(for: workflow, locale: locale),
                            showsDisclosure: true
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .listRowSeparator(workflow.id == filteredWorkflows.last?.id ? .hidden : .visible, edges: .bottom)
                }
            }
            }
            .listStyle(.inset)
            .contentMargins(.horizontal, SettingsLayout.pageInset, for: .scrollContent)
            .contentMargins(.bottom, SettingsLayout.pageInset, for: .scrollContent)
        }
    }

    private func workflowStatus(for workflow: CleanupWorkflow, locale: Locale) -> SettingsLibraryRowStatus? {
        if !workflow.isValid {
            return .warning(EntrevoixLocalization.text("workflows.needs_prompt", defaultValue: "Needs a prompt", locale: locale))
        }
        if model.promptLibrary.activeSelection == .workflow(workflow.id) {
            return .active(EntrevoixLocalization.text("library.active", defaultValue: "Active", locale: locale))
        }
        return nil
    }
}

private struct WorkflowEditorPage: View {
    @Bindable var model: AppStore
    @Bindable var navigation: WorkflowLibraryNavigationState
    let destination: WorkflowDestination
    @State private var showDeleteConfirmation = false

    var body: some View {
        let locale = model.interfaceLocale
        Group {
            if navigation.draft != nil {
                WorkflowEditor(
                    draft: Binding(get: { navigation.draft! }, set: { navigation.draft = $0 }),
                    steps: $navigation.steps,
                    validationError: $navigation.validationError,
                    prompts: model.preferences.cleanupPrompts,
                    onAdd: navigation.add,
                    onRemove: navigation.remove,
                    locale: locale
                )
            } else {
                ContentUnavailableView(
                    EntrevoixLocalization.text("workflows.select", defaultValue: "Select a workflow", locale: locale),
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            }
        }
        .navigationTitle(isExisting ? EntrevoixLocalization.text("workflows.edit_title", defaultValue: "Edit Workflow", locale: locale) : EntrevoixLocalization.text("workflows.new_title", defaultValue: "New Workflow", locale: locale))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(EntrevoixLocalization.text("action.save", defaultValue: "Save", locale: locale)) {
                    guard navigation.save(model: model) else { return }
                    navigation.path.removeLast()
                }
            }
            if isExisting {
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label(EntrevoixLocalization.text("workflows.delete", defaultValue: "Delete", locale: locale), systemImage: "trash")
                    }
                }
            }
        }
        .onAppear {
            switch destination {
            case .edit(let id, _): navigation.beginEditing(id, model: model)
            case .create(let id): navigation.beginCreating(id)
            }
        }
        .alert(EntrevoixLocalization.text("workflows.delete_title", defaultValue: "Delete workflow?", locale: locale), isPresented: $showDeleteConfirmation) {
            Button(EntrevoixLocalization.text("workflows.delete", defaultValue: "Delete", locale: locale), role: .destructive) {
                if let id = navigation.draft?.id {
                    model.deleteCleanupWorkflow(id: id)
                }
                navigation.path.removeLast()
            }
            Button(EntrevoixLocalization.text("action.cancel", defaultValue: "Cancel", locale: locale), role: .cancel) { }
        }
    }

    private var isExisting: Bool {
        if case .edit = destination { return true }
        return false
    }
}

private struct WorkflowEditor: View {
    @Binding var draft: CleanupWorkflow
    @Binding var steps: [WorkflowStepDraft]
    @Binding var validationError: CleanupWorkflowValidationError?
    let prompts: [CleanupPrompt]
    let onAdd: (UUID) -> Void
    let onRemove: (UUID) -> Void
    let locale: Locale

    var body: some View {
        List {
            Section(EntrevoixLocalization.text("workflows.details", defaultValue: "Workflow details", locale: locale)) {
                TextField(EntrevoixLocalization.text("field.name", defaultValue: "Name", locale: locale), text: $draft.name)
            }
            Section(EntrevoixLocalization.text("workflows.prompts", defaultValue: "Prompts", locale: locale)) {
                if steps.isEmpty {
                    Label(EntrevoixLocalization.text("workflows.empty_warning", defaultValue: "Add at least one prompt before saving this workflow.", locale: locale), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                ForEach(steps) { step in
                    WorkflowStepCard(
                        title: promptName(for: step.promptID),
                        systemImage: prompt(for: step.promptID)?.systemImageName ?? "questionmark",
                        removeAccessibilityLabel: EntrevoixLocalization.text(
                            "workflows.remove_prompt",
                            defaultValue: "Remove Prompt",
                            locale: locale
                        ),
                        reorderAccessibilityLabel: EntrevoixLocalization.text(
                            "workflows.reorder_prompt",
                            defaultValue: "Reorder Prompt",
                            locale: locale
                        ),
                        onRemove: { onRemove(step.id) }
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
                }
                .onMove(perform: moveSteps)
                Menu {
                    ForEach(prompts) { prompt in
                        Button(prompt.name) { onAdd(prompt.id) }
                    }
                } label: {
                    Label(EntrevoixLocalization.text("workflows.add_prompt", defaultValue: "Add Prompt", locale: locale), systemImage: "plus")
                }
                .disabled(prompts.isEmpty)
                .listRowSeparator(.hidden)
            }
            if let validationError {
                Label(validationError.message(locale: locale), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .listStyle(.inset)
    }

    private func moveSteps(from source: IndexSet, to destination: Int) {
        steps.move(fromOffsets: source, toOffset: destination)
    }

    private func prompt(for id: UUID) -> CleanupPrompt? {
        prompts.first(where: { $0.id == id })
    }

    private func promptName(for id: UUID) -> String {
        prompt(for: id)?.name
            ?? EntrevoixLocalization.text("workflows.missing_prompt", defaultValue: "Deleted prompt", locale: locale)
    }
}

private struct WorkflowStepCard: View {
    let title: String
    let systemImage: String
    let removeAccessibilityLabel: String
    let reorderAccessibilityLabel: String
    let onRemove: () -> Void
    @State private var isHovering = false
    @FocusState private var isRemoveFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 20)
                .accessibilityLabel(reorderAccessibilityLabel)
                .help(reorderAccessibilityLabel)

            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering || isRemoveFocused ? 1 : 0)
            .focused($isRemoveFocused)
            .accessibilityLabel(removeAccessibilityLabel)
            .help(removeAccessibilityLabel)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .quaternaryLabelColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovering = $0 }
    }
}

private extension CleanupWorkflowValidationError {
    func message(locale: Locale) -> String {
        switch self {
        case .emptyName:
            EntrevoixLocalization.text("workflows.error.empty_name", defaultValue: "Enter a workflow name.", locale: locale)
        case .duplicateName:
            EntrevoixLocalization.text("workflows.error.duplicate_name", defaultValue: "A workflow with this name already exists.", locale: locale)
        case .emptyWorkflow:
            EntrevoixLocalization.text("workflows.error.empty", defaultValue: "Add at least one prompt to the workflow.", locale: locale)
        case .missingPrompt:
            EntrevoixLocalization.text("workflows.error.missing_prompt", defaultValue: "This workflow references a deleted prompt.", locale: locale)
        }
    }
}
