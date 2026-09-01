import Foundation

/// A reusable, ordered transformation made of references to saved cleanup prompts.
public struct CleanupWorkflow: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var promptIDs: [UUID]

    public init(id: UUID = UUID(), name: String, promptIDs: [UUID]) {
        self.id = id
        self.name = name
        self.promptIDs = promptIDs
    }

    public var isValid: Bool { !promptIDs.isEmpty }
}

public enum CleanupWorkflowValidationError: Error, Equatable, Sendable {
    case emptyName
    case duplicateName
    case emptyWorkflow
    case missingPrompt
}

public enum CleanupWorkflowLibrary {
    public static func validatedSaving(
        _ workflow: CleanupWorkflow,
        into workflows: [CleanupWorkflow]
    ) -> Result<CleanupWorkflow, CleanupWorkflowValidationError> {
        let name = workflow.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyName) }
        guard !workflow.promptIDs.isEmpty else { return .failure(.emptyWorkflow) }
        let normalizedName = normalized(name)
        guard !workflows.contains(where: { $0.id != workflow.id && normalized($0.name) == normalizedName }) else {
            return .failure(.duplicateName)
        }
        var value = workflow
        value.name = name
        return .success(value)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isWhitespace }
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

/// The single cleanup transformation selected for a future dictation.
public enum CleanupTransformationSelection: Codable, Equatable, Hashable, Sendable {
    case prompt(UUID)
    case workflow(UUID)
}
