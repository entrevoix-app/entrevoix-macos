import Foundation

public enum CleanupPromptImportError: Error, Equatable, Sendable {
    case unreadableFile
    case invalidFile
    case unsupportedFormat
    case unsupportedVersion
}

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

    public static func decodedJSON(_ data: Data) throws(CleanupPromptImportError) -> Self {
        let exported: Self
        do {
            exported = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw .invalidFile
        }
        guard exported.format == formatIdentifier else { throw .unsupportedFormat }
        guard exported.version == currentVersion else { throw .unsupportedVersion }
        return exported
    }
}
