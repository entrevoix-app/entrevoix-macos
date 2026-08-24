import Foundation
import Testing
@testable import EntrevoixCore

@Suite("Cleanup workflows")
struct CleanupWorkflowTests {
    @Test func validatesNameAndKeepsRepeatedPromptReferences() {
        let promptID = UUID()
        let valid = CleanupWorkflow(name: " Publish ", promptIDs: [promptID, promptID])

        let result = CleanupWorkflowLibrary.validatedSaving(valid, into: [])

        guard case .success(let saved) = result else {
            Issue.record("Expected a valid workflow")
            return
        }
        #expect(saved.name == "Publish")
        #expect(saved.promptIDs == [promptID, promptID])
        #expect(CleanupWorkflowLibrary.validatedSaving(
            CleanupWorkflow(name: "publish", promptIDs: [promptID]),
            into: [saved]
        ) == .failure(.duplicateName))
        #expect(CleanupWorkflowLibrary.validatedSaving(
            CleanupWorkflow(name: "Empty", promptIDs: []),
            into: []
        ) == .failure(.emptyWorkflow))
    }

    @Test func preferencesRoundTripWorkflowAndExclusiveSelection() throws {
        let prompt = CleanupPrompt(name: "Clean", systemImageName: "sparkles", instructions: "Clean it")
        let workflow = CleanupWorkflow(name: "Publish", promptIDs: [prompt.id, prompt.id])
        let preferences = AppPreferences(
            cleanupPrompts: [prompt],
            cleanupWorkflows: [workflow],
            activeCleanupSelection: .workflow(workflow.id)
        )

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(preferences))

        #expect(decoded.cleanupWorkflows == [workflow])
        #expect(decoded.activeCleanupSelection == .workflow(workflow.id))
        #expect(decoded.activeCleanupPromptID == nil)
    }

    @Test func migratesLocalizedDefaultToReservedIdentifier() {
        let legacyID = UUID()
        let preferences = AppPreferences(
            schemaVersion: 11,
            cleanupPrompts: [CleanupPrompt(
                id: legacyID,
                name: "Standard",
                systemImageName: "wand.and.stars",
                instructions: AppPreferences.defaultCleanupPrompt
            )],
            activeCleanupPromptID: legacyID
        )

        let migrated = PreferencesMigrator.migrate(preferences, localizedDefaultPrompt: "Prompt localisé")

        #expect(migrated.schemaVersion == 14)
        #expect(migrated.cleanupPrompts.first?.id == AppPreferences.defaultCleanupPromptID)
        #expect(migrated.cleanupPrompts.first?.instructions == "Prompt localisé")
        #expect(migrated.activeCleanupSelection == .prompt(AppPreferences.defaultCleanupPromptID))
        #expect(migrated.cleanupWorkflows.isEmpty)
    }
}
