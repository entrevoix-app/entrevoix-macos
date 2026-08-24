import Foundation

public protocol CleanupPromptExportReading: Sendable {
    func readExport(at url: URL) throws(CleanupPromptImportError) -> CleanupPromptExport
}
