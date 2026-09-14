import Foundation
import XCTest

final class MenuContentTests: XCTestCase {
    func testPromptMenuGatesSelectionSectionsAndKeepsLocalizedFooter() throws {
        let catalog = try localizationCatalogSource()
        XCTAssertTrue(catalog.contains("\"menu.prompt_disabled\" : { \"localizations\" : { \"en\" : { \"stringUnit\" : { \"state\" : \"translated\", \"value\" : \"TTT cleanup disabled\" } }, \"fr-FR\" : { \"stringUnit\" : { \"state\" : \"translated\", \"value\" : \"Nettoyage TTT désactivé\" } } } }"))
        XCTAssertTrue(catalog.contains("\"menu.prompt_enabled\" : { \"localizations\" : { \"en\" : { \"stringUnit\" : { \"state\" : \"translated\", \"value\" : \"TTT cleanup enabled\" } }"))

        let source = try menuContentSource()
        let promptMenuStart = try XCTUnwrap(source.range(of: "Menu(EntrevoixLocalization.text(\"menu.prompt\"").map { source[$0.lowerBound...] })
        let promptMenuClosingBrace = try XCTUnwrap(promptMenuStart.matchingBrace())
        let promptMenu = promptMenuStart[...promptMenuClosingBrace]
        let enabledGate = try XCTUnwrap(promptMenu.range(of: "if model.preferences.cleanupEnabled {"))
        let enabledGateContent = promptMenu[enabledGate.lowerBound...]
        let closingBrace = try XCTUnwrap(enabledGateContent.matchingBrace())
        let gatedSelectionContent = promptMenu[enabledGate.lowerBound...closingBrace]

        XCTAssertTrue(gatedSelectionContent.contains("Section(EntrevoixLocalization.text(\"menu.prompts_group\""))
        XCTAssertTrue(gatedSelectionContent.contains("model.setActiveCleanupPrompt(prompt.id)"))
        XCTAssertTrue(gatedSelectionContent.contains("Section(EntrevoixLocalization.text(\"menu.workflows_group\""))
        XCTAssertTrue(gatedSelectionContent.contains("model.setActiveCleanupWorkflow(workflow.id)"))
        XCTAssertTrue(gatedSelectionContent.contains(".disabled(!workflow.isValid)"))

        let footer = promptMenu[gatedSelectionContent.endIndex...]
        XCTAssertTrue(footer.contains("model.preferences.cleanupEnabled"))
        XCTAssertTrue(footer.contains("\"menu.prompt_enabled\""))
        XCTAssertTrue(footer.contains("\"menu.prompt_disabled\""))
    }

    private func menuContentSource() throws -> String {
        try String(
            contentsOf: repositoryURL.appendingPathComponent("Sources/Entrevoix/Presentation/Features/MenuBar/MenuContent.swift"),
            encoding: .utf8
        )
    }

    private func localizationCatalogSource() throws -> String {
        return try String(
            contentsOf: repositoryURL.appendingPathComponent("Sources/Entrevoix/Resources/Localizable.xcstrings"),
            encoding: .utf8
        )
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private extension Substring {
    func matchingBrace() -> String.Index? {
        guard let openingBrace = firstIndex(of: "{") else { return nil }
        var depth = 0

        for index in indices[openingBrace...] {
            switch self[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }
}
