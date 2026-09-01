import Foundation
import EntrevoixCore

enum EntrevoixLocalization {
    static func locale(
        for language: InterfaceLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Locale {
        switch language {
        case .automatic:
            for preferredLanguage in preferredLanguages {
                let languageCode = Locale(identifier: preferredLanguage)
                    .language.languageCode?.identifier
                if languageCode == "fr" {
                    return Locale(identifier: "fr-FR")
                }
                if languageCode == "en" {
                    return Locale(identifier: "en")
                }
            }
            return Locale(identifier: "en")
        case .english:
            return Locale(identifier: "en")
        case .french:
            return Locale(identifier: "fr-FR")
        }
    }

    static func text(
        _ key: String,
        defaultValue: String = "",
        locale: Locale
    ) -> String {
        let localizedBundle = bundle(for: locale)
        let value = localizedBundle.localizedString(forKey: key, value: defaultValue, table: nil)
        guard value == key || value == defaultValue else { return value }
        guard defaultValue.isEmpty else { return value }
        return sourceCatalogValue(for: key, locale: locale) ?? value
    }

    static func aboutVersion(_ version: String = AppVersion.marketingVersion, locale: Locale) -> String {
        let format = text(
            "settings.version",
            defaultValue: "Entrevoix %@ — MIT License",
            locale: locale
        )
        return String(format: format, locale: locale, arguments: [version])
    }

    static func resourceURL(forResource name: String, withExtension fileExtension: String) -> URL? {
        resourceBundle().url(forResource: name, withExtension: fileExtension)
    }

    private static func bundle(for locale: Locale) -> Bundle {
        let resourceBundle = resourceBundle()
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        if let path = resourceBundle.path(forResource: identifier, ofType: "lproj"),
           let localizedBundle = Bundle(path: path) {
            return localizedBundle
        }
        if let languageCode = locale.language.languageCode?.identifier,
           let path = resourceBundle.path(forResource: languageCode, ofType: "lproj"),
           let localizedBundle = Bundle(path: path) {
            return localizedBundle
        }
        return resourceBundle
    }

    private static func resourceBundle() -> Bundle {
        if let applicationResourceBundle {
            return applicationResourceBundle
        }
        return Bundle.module
    }

    private static var applicationResourceBundle: Bundle? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }

        guard let resourceURL = Bundle.main.resourceURL else {
            preconditionFailure("Entrevoix application has no Contents/Resources directory.")
        }
        guard let bundleURL = applicationResourceBundleURL(
            bundleURL: Bundle.main.bundleURL,
            resourceURL: resourceURL
        ) else {
            preconditionFailure("Entrevoix application has no localization resource path.")
        }
        guard let bundle = Bundle(url: bundleURL) else {
            preconditionFailure("Entrevoix localization bundle is missing at \(bundleURL.path).")
        }
        return bundle
    }

    static func applicationResourceBundleURL(bundleURL: URL, resourceURL: URL?) -> URL? {
        guard bundleURL.pathExtension == "app", let resourceURL else { return nil }
        return resourceURL.appendingPathComponent("Entrevoix_Entrevoix.bundle", isDirectory: true)
    }

    static func characterCount(_ count: Int, locale: Locale) -> String {
        let format = text(
            "connection_test.received_characters",
            defaultValue: "Connection verified: received %lld characters.",
            locale: locale
        )
        return String(format: format, locale: locale, arguments: [count])
    }

    static func dictationDictionaryCount(_ count: Int, locale: Locale) -> String {
        let format = text(
            "dictation_dictionary.count",
            defaultValue: "%lld strings",
            locale: locale
        )
        return String(format: format, locale: locale, arguments: [count])
    }

    static func promptCount(_ count: Int, locale: Locale) -> String {
        localizedCount(count, key: "prompts.count", defaultValue: "%lld prompts", locale: locale)
    }

    static func workflowCount(_ count: Int, locale: Locale) -> String {
        localizedCount(count, key: "workflows.count", defaultValue: "%lld workflows", locale: locale)
    }

    static func workflowStepCount(_ count: Int, locale: Locale) -> String {
        localizedCount(count, key: "workflows.step_count", defaultValue: "%lld steps", locale: locale)
    }

    private static func localizedCount(_ value: Int, key: String, defaultValue: String, locale: Locale) -> String {
        let format = text(key, defaultValue: defaultValue, locale: locale)
        return String(format: format, locale: locale, arguments: [value])
    }

    static func onboardingStep(_ step: Int, total: Int, locale: Locale) -> String {
        let format = text("onboarding.step", defaultValue: "Step %lld of %lld", locale: locale)
        return String(format: format, locale: locale, arguments: [step, total])
    }

    static func connectionStatus(_ status: String, locale: Locale) -> String {
        let format = text("accessibility.connection_status", defaultValue: "Connection test status: %@", locale: locale)
        return String(format: format, locale: locale, arguments: [status])
    }

    static func permissionStatus(name: String, status: String, locale: Locale) -> String {
        let format = text("accessibility.permission_status", defaultValue: "%@ status: %@", locale: locale)
        return String(format: format, locale: locale, arguments: [name, status])
    }

    static func defaultCleanupPrompt(locale: Locale) -> String {
        text(
            "cleanup.default_prompt",
            defaultValue: "Clean up the transcript without changing its meaning. Correct punctuation, mistakes, and hesitations. Return only the final text.",
            locale: locale
        )
    }

    static func sourceCatalogData() -> Data? {
        guard let url = resourceURL(forResource: "Localizable", withExtension: "xcstrings") else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func sourceCatalogValue(for key: String, locale: Locale) -> String? {
        guard
            let data = sourceCatalogData(),
            let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let strings = catalog["strings"] as? [String: Any],
            let entry = strings[key] as? [String: Any],
            let localizations = entry["localizations"] as? [String: Any]
        else {
            return nil
        }
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let language = locale.language.languageCode?.identifier
        for identifier in [identifier, language].compactMap({ $0 }) {
            if let value = ((localizations[identifier] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String {
                return value
            }
        }
        return nil
    }
}

extension InterfaceLanguage {
    func title(locale: Locale) -> String {
        switch self {
        case .automatic:
            EntrevoixLocalization.text("language.automatic", defaultValue: "Automatic", locale: locale)
        case .english:
            "English"
        case .french:
            "Français"
        }
    }
}

extension TranscriptionLanguage {
    static func sortedForDisplay(locale: Locale, includingAutomatic: Bool = true) -> [Self] {
        let languages = includingAutomatic ? allCases : selectableCases
        return languages.sorted {
            $0.title(locale: locale).compare(
                $1.title(locale: locale),
                options: [.caseInsensitive, .diacriticInsensitive],
                range: nil,
                locale: locale
            ) == .orderedAscending
        }
    }

    func title(locale: Locale) -> String {
        switch self {
        case .automatic:
            localizedName(key: "language.automatic", english: "Automatic", french: "Automatique", locale: locale)
        case .arabic:
            localizedName(key: "language.arabic", english: "Arabic", french: "Arabe", locale: locale)
        case .chinese:
            localizedName(key: "language.chinese", english: "Chinese", french: "Chinois", locale: locale)
        case .dutch:
            localizedName(key: "language.dutch", english: "Dutch", french: "Néerlandais", locale: locale)
        case .english:
            localizedName(key: "language.english", english: "English", french: "Anglais", locale: locale)
        case .french:
            localizedName(key: "language.french", english: "French", french: "Français", locale: locale)
        case .german:
            localizedName(key: "language.german", english: "German", french: "Allemand", locale: locale)
        case .hindi:
            localizedName(key: "language.hindi", english: "Hindi", french: "Hindi", locale: locale)
        case .indonesian:
            localizedName(key: "language.indonesian", english: "Indonesian", french: "Indonésien", locale: locale)
        case .italian:
            localizedName(key: "language.italian", english: "Italian", french: "Italien", locale: locale)
        case .japanese:
            localizedName(key: "language.japanese", english: "Japanese", french: "Japonais", locale: locale)
        case .korean:
            localizedName(key: "language.korean", english: "Korean", french: "Coréen", locale: locale)
        case .polish:
            localizedName(key: "language.polish", english: "Polish", french: "Polonais", locale: locale)
        case .portuguese:
            localizedName(key: "language.portuguese", english: "Portuguese", french: "Portugais", locale: locale)
        case .russian:
            localizedName(key: "language.russian", english: "Russian", french: "Russe", locale: locale)
        case .spanish:
            localizedName(key: "language.spanish", english: "Spanish", french: "Espagnol", locale: locale)
        case .turkish:
            localizedName(key: "language.turkish", english: "Turkish", french: "Turc", locale: locale)
        case .ukrainian:
            localizedName(key: "language.ukrainian", english: "Ukrainian", french: "Ukrainien", locale: locale)
        case .vietnamese:
            localizedName(key: "language.vietnamese", english: "Vietnamese", french: "Vietnamien", locale: locale)
        }
    }

    private func localizedName(key: String, english: String, french: String, locale: Locale) -> String {
        if locale.language.languageCode?.identifier == "fr" {
            return french
        }
        return EntrevoixLocalization.text(key, defaultValue: english, locale: locale)
    }
}
