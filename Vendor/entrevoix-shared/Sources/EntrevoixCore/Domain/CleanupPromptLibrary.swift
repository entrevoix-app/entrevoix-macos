import Foundation

public enum CleanupPromptValidationError: Error, Equatable, Sendable {
    case emptyName
    case duplicateName
    case emptyInstructions
    case invalidIcon
}

public struct CleanupPromptImportResult: Equatable, Sendable {
    public let importedPrompts: [CleanupPrompt]
    public let skippedCount: Int

    public init(importedPrompts: [CleanupPrompt], skippedCount: Int) {
        self.importedPrompts = importedPrompts
        self.skippedCount = skippedCount
    }
}

public enum CleanupPromptLibrary {
    public static func validatedSaving(
        _ prompt: CleanupPrompt,
        into prompts: [CleanupPrompt]
    ) -> Result<CleanupPrompt, CleanupPromptValidationError> {
        let name = prompt.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyName) }
        guard !prompt.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyInstructions)
        }
        guard CleanupPrompt.allowedSystemImageNames.contains(prompt.systemImageName) else {
            return .failure(.invalidIcon)
        }
        let normalizedName = normalized(name)
        guard !prompts.contains(where: { $0.id != prompt.id && normalized($0.name) == normalizedName }) else {
            return .failure(.duplicateName)
        }
        var value = prompt
        value.name = name
        return .success(value)
    }

    public static func importing(
        _ importedPrompts: [CleanupPrompt],
        into existingPrompts: [CleanupPrompt]
    ) -> CleanupPromptImportResult {
        var acceptedPrompts = existingPrompts
        var imported: [CleanupPrompt] = []
        var skippedCount = 0

        for sourcePrompt in importedPrompts {
            let candidate: CleanupPrompt
            if acceptedPrompts.contains(where: { $0.id == sourcePrompt.id }) {
                candidate = CleanupPrompt(
                    name: sourcePrompt.name,
                    systemImageName: sourcePrompt.systemImageName,
                    instructions: sourcePrompt.instructions
                )
            } else {
                candidate = sourcePrompt
            }

            switch validatedSaving(candidate, into: acceptedPrompts) {
            case .success(let prompt):
                acceptedPrompts.append(prompt)
                imported.append(prompt)
            case .failure:
                skippedCount += 1
            }
        }

        return CleanupPromptImportResult(importedPrompts: imported, skippedCount: skippedCount)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isWhitespace }
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
