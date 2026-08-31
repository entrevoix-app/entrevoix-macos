import Foundation
@testable import Entrevoix
import XCTest

@MainActor
final class RecordingArchiveTests: XCTestCase {
    func testArchiveCreatesProtectedRecordingsDirectoryAndCopiesSource() throws {
        let rootURL = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = rootURL.appending(path: "source.wav")
        let bytes = Data([0, 1, 2, 3])
        try bytes.write(to: sourceURL)
        let archive = RecordingArchive(
            rootURL: rootURL,
            now: { self.date("2026-08-31T12:34:56.789Z") },
            makeUUID: { UUID(uuidString: "11111111-1111-1111-1111-111111111111")! }
        )

        let destinationURL = try archive.archive(sourceURL: sourceURL)

        XCTAssertEqual(destinationURL.path, rootURL.appending(path: "Entrevoix/Recordings/20260831-123456-789-11111111-1111-1111-1111-111111111111.wav").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), bytes)
        XCTAssertEqual(try Data(contentsOf: destinationURL), bytes)
        XCTAssertEqual(try permissions(at: destinationURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(at: destinationURL), 0o600)
    }

    func testArchiveUsesUniqueInjectedUUIDs() throws {
        let rootURL = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let firstSource = rootURL.appending(path: "first.wav")
        let secondSource = rootURL.appending(path: "second.wav")
        let firstBytes = Data([1])
        let secondBytes = Data([2])
        try firstBytes.write(to: firstSource)
        try secondBytes.write(to: secondSource)
        var uuids = [
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        ]
        let archive = RecordingArchive(
            rootURL: rootURL,
            now: { self.date("2026-08-31T12:34:56.789Z") },
            makeUUID: { uuids.removeFirst() }
        )

        let firstDestination = try archive.archive(sourceURL: firstSource)
        let secondDestination = try archive.archive(sourceURL: secondSource)

        XCTAssertNotEqual(firstDestination, secondDestination)
        XCTAssertEqual(try Data(contentsOf: firstSource), firstBytes)
        XCTAssertEqual(try Data(contentsOf: secondSource), secondBytes)
        XCTAssertEqual(try Data(contentsOf: firstDestination), firstBytes)
        XCTAssertEqual(try Data(contentsOf: secondDestination), secondBytes)
    }

    func testArchiveMapsMissingSourceToSourceCopyFailed() throws {
        let rootURL = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let archive = RecordingArchive(rootURL: rootURL)

        XCTAssertThrowsError(try archive.archive(sourceURL: rootURL.appending(path: "missing.wav"))) {
            XCTAssertEqual($0 as? RecordingArchiveError, .sourceCopyFailed)
        }
    }

    func testArchiveMapsDirectoryFailure() throws {
        let rootURL = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data().write(to: rootURL.appending(path: "Entrevoix"))
        let archive = RecordingArchive(rootURL: rootURL)

        XCTAssertThrowsError(try archive.archive(sourceURL: rootURL.appending(path: "source.wav"))) {
            XCTAssertEqual($0 as? RecordingArchiveError, .directoryCreationFailed)
        }
    }

    func testArchiveRejectsDestinationCollisionWithoutOverwriting() throws {
        let rootURL = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = rootURL.appending(path: "source.wav")
        let sourceBytes = Data([1])
        let destinationBytes = Data([2])
        try sourceBytes.write(to: sourceURL)
        let recordingsURL = rootURL.appending(path: "Entrevoix/Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
        let destinationURL = recordingsURL.appending(path: "20260831-123456-789-11111111-1111-1111-1111-111111111111.wav")
        try destinationBytes.write(to: destinationURL)
        let archive = RecordingArchive(
            rootURL: rootURL,
            now: { self.date("2026-08-31T12:34:56.789Z") },
            makeUUID: { UUID(uuidString: "11111111-1111-1111-1111-111111111111")! }
        )

        XCTAssertThrowsError(try archive.archive(sourceURL: sourceURL)) {
            XCTAssertEqual($0 as? RecordingArchiveError, .destinationCollision)
        }
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: destinationURL), destinationBytes)
    }

    func testOpenRecordingsFolderCreatesProtectedDirectoryAndInvokesOpener() throws {
        let rootURL = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        var openedURLs: [URL] = []
        let archive = RecordingArchive(rootURL: rootURL, folderOpener: {
            openedURLs.append($0)
            return true
        })

        try archive.openRecordingsFolder()

        let recordingsURL = rootURL.appending(path: "Entrevoix/Recordings", directoryHint: .isDirectory)
        XCTAssertEqual(openedURLs, [recordingsURL])
        XCTAssertEqual(try permissions(at: recordingsURL), 0o700)
    }

    func testOpenRecordingsFolderMapsFalseResult() throws {
        let rootURL = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let archive = RecordingArchive(rootURL: rootURL, folderOpener: { _ in false })

        XCTAssertThrowsError(try archive.openRecordingsFolder()) {
            XCTAssertEqual($0 as? RecordingArchiveError, .folderCouldNotOpen)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appending(path: "Entrevoix/Recordings").path))
    }

    private func makeTemporaryRoot() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)!
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let value = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return value.intValue
    }
}
