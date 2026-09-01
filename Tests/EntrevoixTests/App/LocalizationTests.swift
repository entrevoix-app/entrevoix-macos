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

    func testAboutVersionUsesLocalizedFormat() throws {
        let data = try XCTUnwrap(EntrevoixLocalization.sourceCatalogData())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(object["strings"] as? [String: Any])
        let entry = try XCTUnwrap(strings["settings.version"] as? [String: Any])
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
        let english = try localizedValue(for: "en", in: localizations)
        let french = try localizedValue(for: "fr-FR", in: localizations)

        XCTAssertEqual(
            String(format: english, locale: Locale(identifier: "en"), arguments: ["1.2.3"]),
            "Entrevoix 1.2.3 — MIT License"
        )
        XCTAssertEqual(
            String(format: french, locale: Locale(identifier: "fr-FR"), arguments: ["1.2.3"]),
            "Entrevoix 1.2.3 — Licence MIT"
        )
    }

    func testOnboardingPrivacyUsesTruthfulRetentionCopy() throws {
        let data = try XCTUnwrap(EntrevoixLocalization.sourceCatalogData())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(object["strings"] as? [String: Any])
        let entry = try XCTUnwrap(strings["onboarding.welcome.privacy"] as? [String: Any])
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])

        XCTAssertEqual(
            try localizedValue(for: "en", in: localizations),
            "API keys stay in the macOS Keychain. Audio recordings are deleted after transcription by default, but you can choose to retain them. Entrevoix has no servers or user accounts of its own."
        )
        XCTAssertEqual(
            try localizedValue(for: "fr-FR", in: localizations),
            "Les clés API restent dans le trousseau macOS. Les enregistrements audio sont supprimés après la transcription par défaut, mais vous pouvez choisir de les conserver. Entrevoix n’a ni serveur ni compte utilisateur propre."
        )
    }

    func testMarketingVersionReadsBundleValueAndFallsBackSafely() {
        XCTAssertEqual(
            AppVersion.marketingVersion(in: ["CFBundleShortVersionString": "1.2.3"]),
            "1.2.3"
        )
        XCTAssertEqual(AppVersion.marketingVersion(in: [:]), AppVersion.fallbackMarketingVersion)
    }

    func testCatalogContainsEnglishAndFrenchRepresentativeEntries() throws {
        let data = try XCTUnwrap(EntrevoixLocalization.sourceCatalogData())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(object["strings"] as? [String: Any])

        for key in [
            "cleanup.default_prompt",
            "menu.settings",
            "settings.recordings",
            "settings.delete_audio_after_transcription",
            "settings.open_recordings_folder",
            "settings.open_recordings_folder_failed",
            "settings.interface_language",
            "settings.global_shortcut",
            "settings.sidebar.application",
            "settings.sidebar.processing",
            "settings.sidebar.customization",
            "settings.audio_input",
            "settings.trim_silence",
            "settings.reduce_internal_pauses",
            "settings.trim_resource_checking",
            "settings.trim_resource_download",
            "settings.trim_resource_downloading",
            "settings.trim_resource_failed",
            "settings.trim_resource_ready",
            "settings.trim_resource_required",
            "settings.trim_resource_unsupported",
            "field.audio_input",
            "audio_input.system_default",
            "audio_input.system_default_named",
            "audio_input.unavailable",
            "audio_input.unavailable_warning",
            "field.stt_language",
            "field.stt_upload_format",
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
            "failure.no_speech",
            "menu.prompts_group",
            "menu.workflows_group",
            "settings.workflows",
            "library.active",
            "library.no_results",
            "library.search",
            "prompts.count",
            "prompts.description",
            "prompts.export",
            "prompts.export_failed_title",
            "prompts.export_failed_message",
            "prompts.import",
            "prompts.import_failed_title",
            "prompts.import_invalid_file",
            "prompts.import_unsupported_format",
            "prompts.import_unsupported_version",
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
            "provider.actions",
            "provider.back_to_catalog",
            "provider.configured_title",
            "action.configure",
            "provider.models_load_failed",
            "codex.connect",
            "codex.ttt_only",
            "prompts.actions",
            "prompts.back_to_library",
            "error.codex_not_connected",
            "stt_upload_format.wav",
            "stt_upload_format.wav.description",
            "stt_upload_format.m4a_aac",
            "stt_upload_format.m4a_aac.description",
            "stt_upload_format.flac",
            "stt_upload_format.flac.description",
            "stt_upload_format.compatibility_hint",
            "error.stt_audio_encoding_failed"
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

    func testEnglishIncompatibleStartupMessageWarnsThatTemporaryChangesMayBeUnstableAndUnsaved() {
        let message = EntrevoixLocalization.text(
            "startup.incompatible.message",
            defaultValue: "",
            locale: Locale(identifier: "en")
        )

        XCTAssertTrue(message.contains("may be unstable"))
        XCTAssertTrue(message.contains("will not be saved"))
    }

    func testFrenchIncompatibleStartupMessageWarnsThatTemporaryChangesMayBeUnstableAndUnsaved() {
        let message = EntrevoixLocalization.text(
            "startup.incompatible.message",
            defaultValue: "",
            locale: Locale(identifier: "fr-FR")
        )

        XCTAssertTrue(message.contains("instables"))
        XCTAssertTrue(message.contains("ne seront pas enregistrées"))
    }

    func testEnglishIncompatibleStartupOpenAnywayActionIsLocalized() {
        XCTAssertEqual(
            EntrevoixLocalization.text(
                "startup.incompatible.open_anyway",
                defaultValue: "",
                locale: Locale(identifier: "en")
            ),
            "Open Anyway"
        )
    }

    func testFrenchIncompatibleStartupOpenAnywayActionIsLocalized() {
        XCTAssertEqual(
            EntrevoixLocalization.text(
                "startup.incompatible.open_anyway",
                defaultValue: "",
                locale: Locale(identifier: "fr-FR")
            ),
            "Ouvrir quand même"
        )
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

    private func localizedValue(for locale: String, in localizations: [String: Any]) throws -> String {
        let localization = try XCTUnwrap(localizations[locale] as? [String: Any])
        let stringUnit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
        return try XCTUnwrap(stringUnit["value"] as? String)
    }
}
