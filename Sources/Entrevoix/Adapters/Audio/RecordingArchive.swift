import AppKit
import Foundation

@MainActor
protocol RecordingArchiving: AnyObject {
    @discardableResult func archive(sourceURL: URL) throws -> URL
}

@MainActor
protocol RecordingsFolderOpening: AnyObject {
    func openRecordingsFolder() throws
}

enum RecordingArchiveError: Error, Equatable {
    case directoryCreationFailed
    case destinationCollision
    case sourceCopyFailed
    case permissionUpdateFailed
    case folderCouldNotOpen
}

@MainActor
final class RecordingArchive: RecordingArchiving, RecordingsFolderOpening {
    private let rootURL: URL?
    private let fileManager: FileManager
    private let now: () -> Date
    private let makeUUID: () -> UUID
    private let folderOpener: (URL) -> Bool

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init,
        folderOpener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.now = now
        self.makeUUID = makeUUID
        self.folderOpener = folderOpener
    }

    func archive(sourceURL: URL) throws -> URL {
        let recordingsURL = try protectedRecordingsURL()
        let destinationURL = recordingsURL.appending(path: filename())
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw RecordingArchiveError.destinationCollision
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw RecordingArchiveError.sourceCopyFailed
        }

        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw RecordingArchiveError.permissionUpdateFailed
        }

        return destinationURL
    }

    func openRecordingsFolder() throws {
        let recordingsURL = try protectedRecordingsURL()
        guard folderOpener(recordingsURL) else {
            throw RecordingArchiveError.folderCouldNotOpen
        }
    }

    private func protectedRecordingsURL() throws -> URL {
        guard let rootURL = rootURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RecordingArchiveError.directoryCreationFailed
        }
        let recordingsURL = rootURL.appending(path: "Entrevoix/Recordings", directoryHint: .isDirectory)

        do {
            try fileManager.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordingsURL.path)
        } catch {
            throw RecordingArchiveError.directoryCreationFailed
        }

        return recordingsURL
    }

    private func filename() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "\(formatter.string(from: now()))-\(makeUUID().uuidString.lowercased()).wav"
    }
}
