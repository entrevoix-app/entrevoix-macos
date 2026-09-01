import Foundation

/// The synchronizable prompt and workflow library, excluding device-local selection.
public struct CleanupLibrary: Codable, Equatable, Sendable {
    public var prompts: [CleanupPrompt]
    public var workflows: [CleanupWorkflow]

    public init(prompts: [CleanupPrompt], workflows: [CleanupWorkflow]) {
        self.prompts = prompts
        self.workflows = workflows
    }
}

/// A granular change to a cleanup library suitable for cross-device synchronization.
public enum CleanupLibraryMutation: Equatable, Sendable {
    case savePrompt(CleanupPrompt)
    case deletePrompt(UUID)
    case saveWorkflow(CleanupWorkflow)
    case deleteWorkflow(UUID)
}
