import Foundation

/// Applies schema migrations that require coordinated changes across preference fields.
///
/// `AppPreferences` remains responsible for tolerant decoding. This type owns the
/// version-aware normalization that is safe to run after decoding and before the
/// preferences are handed to the application models.
public enum PreferencesMigrator {
    public static func migrate(
        _ input: AppPreferences,
        localizedDefaultPrompt: String
    ) -> AppPreferences {
        var preferences = input
        let sourceSchemaVersion = input.schemaVersion

        if sourceSchemaVersion < AppPreferences.currentSchemaVersion {
            preferences.schemaVersion = AppPreferences.currentSchemaVersion
        }

        if sourceSchemaVersion < 6 {
            let wasLocalized = input.cleanupPromptMode != .custom
            var migrated = input.cleanupPrompts.first
                ?? CleanupPrompt(
                    name: wasLocalized ? defaultPromptName : "Existing Prompt",
                    systemImageName: wasLocalized ? defaultPromptIcon : "text.badge.checkmark",
                    instructions: input.cleanupPrompt
                )

            if wasLocalized {
                migrated = CleanupPrompt(
                    id: AppPreferences.defaultCleanupPromptID,
                    name: defaultPromptName,
                    systemImageName: defaultPromptIcon,
                    instructions: localizedDefaultPrompt
                )
            } else {
                migrated.name = "Existing Prompt"
            }

            preferences.cleanupPrompts = [migrated]
            preferences.activeCleanupSelection = .prompt(migrated.id)
        }

        if sourceSchemaVersion < 12 {
            if preferences.cleanupPromptMode == .localizedDefault,
               preferences.cleanupPrompts.count == 1,
               let existingDefault = preferences.cleanupPrompts.first,
               existingDefault.name == defaultPromptName,
               existingDefault.systemImageName == defaultPromptIcon {
                preferences.cleanupPrompts = [CleanupPrompt(
                    id: AppPreferences.defaultCleanupPromptID,
                    name: defaultPromptName,
                    systemImageName: defaultPromptIcon,
                    instructions: localizedDefaultPrompt
                )]
                if preferences.activeCleanupSelection == .prompt(existingDefault.id) {
                    preferences.activeCleanupSelection = .prompt(AppPreferences.defaultCleanupPromptID)
                }
            }
            if preferences.activeCleanupSelection == nil, let firstPrompt = preferences.cleanupPrompts.first {
                preferences.activeCleanupSelection = .prompt(firstPrompt.id)
            }
        }

        preferences.normalizeCleanupSelection()

        if sourceSchemaVersion == AppPreferences.currentSchemaVersion,
           !input.hasCompletedOnboarding,
           input.cleanupPromptMode == .localizedDefault,
           preferences.cleanupPrompts.count == 1,
           preferences.cleanupPrompts[0].instructions == AppPreferences.defaultCleanupPrompt {
            preferences.cleanupPrompts = [CleanupPrompt(
                id: AppPreferences.defaultCleanupPromptID,
                name: defaultPromptName,
                systemImageName: defaultPromptIcon,
                instructions: localizedDefaultPrompt
            )]
            preferences.activeCleanupSelection = .prompt(AppPreferences.defaultCleanupPromptID)
        }

        return preferences
    }

    private static let defaultPromptName = "Standard"
    private static let defaultPromptIcon = "wand.and.stars"
}
