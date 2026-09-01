import XCTest
@testable import EntrevoixCore

final class CleanupPromptLibraryTests: XCTestCase {
    func testSavingTrimsNameAndRejectsDuplicateNamesIgnoringWhitespaceAndCase() {
        let existing = CleanupPrompt(name: "Standard", systemImageName: "wand.and.stars", instructions: "Useful")
        let candidate = CleanupPrompt(name: " standard ", systemImageName: "sparkles", instructions: "Other")

        XCTAssertEqual(
            CleanupPromptLibrary.validatedSaving(candidate, into: [existing]),
            .failure(.duplicateName)
        )
    }

    func testSavingRejectsEmptyValuesAndUnsupportedIcons() {
        XCTAssertEqual(
            CleanupPromptLibrary.validatedSaving(.init(name: " ", systemImageName: "sparkles", instructions: "Text"), into: []),
            .failure(.emptyName)
        )
        XCTAssertEqual(
            CleanupPromptLibrary.validatedSaving(.init(name: "Name", systemImageName: "sparkles", instructions: " "), into: []),
            .failure(.emptyInstructions)
        )
        XCTAssertEqual(
            CleanupPromptLibrary.validatedSaving(.init(name: "Name", systemImageName: "invalid", instructions: "Text"), into: []),
            .failure(.invalidIcon)
        )
    }

    func testImportingMergesValidPromptsWithoutOverwritingExistingEntries() {
        let existing = CleanupPrompt(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Existing",
            systemImageName: "wand.and.stars",
            instructions: "Keep existing."
        )
        let duplicateName = CleanupPrompt(name: " existing ", systemImageName: "sparkles", instructions: "Do not import.")
        let collidingID = CleanupPrompt(id: existing.id, name: "Imported", systemImageName: "quote.bubble", instructions: "Import this.")
        let invalid = CleanupPrompt(name: "Invalid", systemImageName: "circle", instructions: "Do not import.")

        let result = CleanupPromptLibrary.importing([duplicateName, collidingID, invalid], into: [existing])

        XCTAssertEqual(result.importedPrompts.count, 1)
        XCTAssertEqual(result.importedPrompts.first?.name, "Imported")
        XCTAssertNotEqual(result.importedPrompts.first?.id, existing.id)
        XCTAssertEqual(result.skippedCount, 2)
    }
}
