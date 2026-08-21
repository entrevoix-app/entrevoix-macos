import Foundation
import XCTest
import EntrevoixCore
@testable import Entrevoix

final class LocalizationTests: XCTestCase {
    func testExplicitAndAutomaticLanguageResolution() {
        XCTAssertEqual(EntrevoixLocalization.locale(for: .english).identifier, "en")
        XCTAssertEqual(EntrevoixLocalization.locale(for: .french).identifier, "fr-FR")
        XCTAssertEqual(
            EntrevoixLocalization.locale(for: .automatic, preferredLanguages: ["fr-CA", "en-US"]).identifier,
            "fr-FR"
        )
        XCTAssertEqual(
            EntrevoixLocalization.locale(for: .automatic, preferredLanguages: ["de-DE"]).identifier,
            "en"
        )
        XCTAssertEqual(
            EntrevoixLocalization.locale(for: .automatic, preferredLanguages: ["de-DE", "fr-CA"]).identifier,
            "fr-FR"
        )
    }

    func testCatalogContainsEnglishAndFrenchRepresentativeEntries() throws {
        let data = try XCTUnwrap(EntrevoixLocalization.sourceCatalogData())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(object["strings"] as? [String: Any])

        for key in [
            "cleanup.default_prompt",
            "menu.settings",
            "settings.interface_language",
            "settings.global_shortcut",
            "settings.sidebar.application",
            "settings.sidebar.processing",
            "settings.sidebar.customization",
            "settings.duck_other_audio",
            "settings.audio_input",
            "field.audio_input",
            "audio_input.system_default",
            "audio_input.system_default_named",
            "audio_input.unavailable",
            "audio_input.unavailable_warning",
            "field.stt_language",
            "field.primary_shortcut",
            "field.secondary_shortcut",
            "field.stt_favorite_languages",
            "settings.dictation_dictionary",
            "dictation_dictionary.description",
            "dictation_dictionary.count",
            "dictation_dictionary.none",
            "dictation_dictionary.search",
            "dictation_dictionary.add",
            "dictation_dictionary.actions",
            "dictation_dictionary.edit",
            "dictation_dictionary.remove",
            "dictation_dictionary.warning",
            "menu.language",
            "language.french",
            "language.german",
            "connection_test.received_characters",
            "dictation.transcribing",
            "dictation.improving",
            "dictation.improving_progress",
            "failure.workflow_step_failed",
            "menu.prompts_group",
            "menu.workflows_group",
            "settings.workflows",
            "library.active",
            "library.no_results",
            "library.search",
            "prompts.count",
            "prompts.description",
            "workflows.count",
            "workflows.description",
            "workflows.empty_warning",
            "workflows.needs_prompt",
            "workflows.step_count",
            "permission.reset_failed",
            "permission.reset_microphone",
            "permission.reset_succeeded",
            "permission.resetting_microphone",
            "action.quit",
            "startup.incompatible.title",
            "startup.incompatible.message",
            "startup.recovered.title",
            "startup.recovered.message",
            "settings.updates",
            "settings.update_channel",
            "settings.update_channel_hint",
            "updates.channel.stable",
            "updates.channel.rc",
            "updates.channel.dev",
            "updates.channel.stable.description",
            "updates.channel.rc.description",
            "updates.channel.dev.description",
            "updates.channel.confirm",
            "updates.channel.confirm_rc",
            "updates.channel.confirm_dev",
            "updates.channel.confirmation_message",
            "updates.channel.use_rc",
            "updates.channel.use_dev",
            "updates.channel.confirm_action",
            "provider.openai_codex",
            "provider.add_another",
            "provider.back_to_catalog",
            "provider.configured_title",
            "action.configure",
            "provider.models_load_failed",
            "codex.connect",
            "codex.ttt_only",
            "error.codex_not_connected"
        ] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            XCTAssertNotNil(localizations["en"])
            XCTAssertNotNil(localizations["fr-FR"])
        }

        XCTAssertEqual(TranscriptionLanguage.french.title(locale: Locale(identifier: "en")), "French")
        XCTAssertEqual(TranscriptionLanguage.french.title(locale: Locale(identifier: "fr-FR")), "Français")

        let englishOrder = TranscriptionLanguage.sortedForDisplay(locale: Locale(identifier: "en"))
        XCTAssertEqual(englishOrder.first, .arabic)
        XCTAssertEqual(englishOrder.last, .vietnamese)

        let frenchOrder = TranscriptionLanguage.sortedForDisplay(locale: Locale(identifier: "fr-FR"))
        XCTAssertEqual(frenchOrder.first, .german)
        XCTAssertEqual(frenchOrder.last, .vietnamese)

    }

    func testEveryLocalizationKeyUsedBySourceHasEnglishAndFrenchValues() throws {
        let data = try XCTUnwrap(EntrevoixLocalization.sourceCatalogData())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(object["strings"] as? [String: Any])
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryURL.appendingPathComponent("Sources/Entrevoix", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: nil
        ))
        let expression = try NSRegularExpression(
            pattern: #"(?:EntrevoixLocalization\.)?(?:text|localized)\(\s*"([^"]+)""#,
            options: [.dotMatchesLineSeparators]
        )
        var usedKeys = Set<String>()

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                usedKeys.insert(String(source[keyRange]))
            }
        }

        XCTAssertFalse(usedKeys.isEmpty)
        for key in usedKeys.sorted() {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing localization key: \(key)")
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                "Missing localizations for: \(key)"
            )
            XCTAssertNotNil(localizations["en"], "Missing English localization: \(key)")
            XCTAssertNotNil(localizations["fr-FR"], "Missing French localization: \(key)")
        }
    }

    func testApplicationBundleResourcePathUsesContentsResources() {
        let appURL = URL(fileURLWithPath: "/tmp/Entrevoix.app")
        let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)

        XCTAssertEqual(
            EntrevoixLocalization.applicationResourceBundleURL(bundleURL: appURL, resourceURL: resourcesURL),
            resourcesURL.appendingPathComponent("Entrevoix_Entrevoix.bundle", isDirectory: true)
        )
        XCTAssertNil(
            EntrevoixLocalization.applicationResourceBundleURL(
                bundleURL: URL(fileURLWithPath: "/tmp/Entrevoix_Entrevoix.bundle"),
                resourceURL: resourcesURL
            )
        )
    }

    func testUserFacingErrorKeepsProviderDetails() {
        let message = UserFacingErrorMessage.sttHTTP(statusCode: 503, providerMessage: "Provider unavailable")
        XCTAssertEqual(message.localizedText(locale: Locale(identifier: "en")), "STT error (HTTP 503).: Provider unavailable")
    }
}
