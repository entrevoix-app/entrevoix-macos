import EntrevoixCore
import SwiftUI
import UniformTypeIdentifiers

struct PromptLibraryExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let export: CleanupPromptExport

    init(export: CleanupPromptExport) {
        self.export = export
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        export = try JSONDecoder().decode(CleanupPromptExport.self, from: data)
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(regularFileWithContents: export.encodedJSON())
    }
}
