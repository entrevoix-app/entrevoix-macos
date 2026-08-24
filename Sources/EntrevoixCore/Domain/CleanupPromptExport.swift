import Foundation

/// A portable, versioned representation of a cleanup prompt library.
public struct CleanupPromptExport: Codable, Equatable, Sendable {
    public static let formatIdentifier = "entrevoix.cleanup-prompts"
    public static let currentVersion = 1

    public let format: String
    public let version: Int
    public let prompts: [CleanupPrompt]

    public init(prompts: [CleanupPrompt]) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.prompts = prompts
    }

    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
