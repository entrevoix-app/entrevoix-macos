import Darwin
import Foundation
import EntrevoixCore

enum LocalizationDiagnostic {
    private static let command = "--verify-localization"

    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let commandIndex = arguments.firstIndex(of: command) else { return false }

        let mode = commandIndex + 1 < arguments.count ? arguments[commandIndex + 1] : ""
        let language: InterfaceLanguage
        switch mode {
        case "automatic": language = .automatic
        case "english": language = .english
        case "french": language = .french
        default:
            fputs("Usage: Entrevoix --verify-localization <automatic|english|french>\n", stderr)
            exit(64)
        }

        guard EntrevoixLocalization.resourceURL(forResource: "openai-blossom", withExtension: "svg") != nil else {
            fputs("Missing OpenAI provider icon resource.\n", stderr)
            exit(1)
        }

        let locale = EntrevoixLocalization.locale(for: language)
        let values = [
            ("locale", locale.identifier),
            ("onboarding.welcome.title", EntrevoixLocalization.text(
                "onboarding.welcome.title",
                defaultValue: "Welcome to Entrevoix",
                locale: locale
            )),
            ("menu.settings", EntrevoixLocalization.text(
                "menu.settings",
                defaultValue: "Settings",
                locale: locale
            )),
            ("action.next", EntrevoixLocalization.text(
                "action.next",
                defaultValue: "Next",
                locale: locale
            ))
        ]
        for (key, value) in values {
            print("\(key)=\(value)")
        }
        return true
    }
}
