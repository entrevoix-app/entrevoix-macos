import Foundation
import EntrevoixCore

public struct JSONCleanupPromptExportReader: CleanupPromptExportReading {
    public init() {}

    public func readExport(at url: URL) throws(CleanupPromptImportError) -> CleanupPromptExport {
        let hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw .unreadableFile
        }
        return try CleanupPromptExport.decodedJSON(data)
    }
}
