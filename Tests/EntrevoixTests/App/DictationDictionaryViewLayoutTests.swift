import Foundation
import XCTest

final class DictationDictionaryViewLayoutTests: XCTestCase {
    func testEmptyDictionaryStateFillsAndCentersItsAvailableSpace() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot.appending(path: "Sources/Entrevoix/Presentation/Features/Settings/SettingsFeatureViews.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let emptyStateStart = try XCTUnwrap(
            source.components(separatedBy: "if filteredTerms.isEmpty, !isAdding {").dropFirst().first
        )
        let emptyState = try XCTUnwrap(emptyStateStart.components(separatedBy: "} else {").first)

        XCTAssertTrue(
            emptyState.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)"),
            "Empty dictionary state must occupy and center within available list space."
        )
    }
}
