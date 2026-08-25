import CloudKit
import EntrevoixCore
import Foundation

@MainActor
protocol CleanupLibraryCloudStoring {
    func fetchLibrary() async throws -> CleanupLibrary?
    func saveLibrary(_ library: CleanupLibrary) async throws
}

@MainActor
final class CleanupLibraryCloudSync {
    var onRemoteLibrary: ((CleanupLibrary) -> Void)?

    private let store: any CleanupLibraryCloudStoring
    private var initialSyncTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?

    init(store: any CleanupLibraryCloudStoring = CloudKitCleanupLibraryStore()) {
        self.store = store
    }

    deinit {
        initialSyncTask?.cancel()
        publishTask?.cancel()
    }

    func start(
        with localLibrary: CleanupLibrary,
        publishingLocalLibraryWhenCloudIsEmpty: Bool
    ) {
        initialSyncTask?.cancel()
        initialSyncTask = Task { @MainActor [weak self, store] in
            do {
                let remoteLibrary = try await store.fetchLibrary()
                guard !Task.isCancelled else { return }
                if let remoteLibrary {
                    self?.onRemoteLibrary?(remoteLibrary)
                } else if publishingLocalLibraryWhenCloudIsEmpty {
                    try await store.saveLibrary(localLibrary)
                }
            } catch {
                // CloudKit is optional: a temporary account or network failure must
                // not block local prompt-library edits. The next launch or edit retries.
            }
        }
    }

    func publish(_ preferences: AppPreferences) {
        let library = CleanupLibrary(
            prompts: preferences.cleanupPrompts,
            workflows: preferences.cleanupWorkflows
        )
        publishTask?.cancel()
        publishTask = Task { @MainActor [store] in
            do {
                try await store.saveLibrary(library)
            } catch {
                // Keep the local library usable when CloudKit is unavailable.
            }
        }
    }
}

@MainActor
final class CloudKitCleanupLibraryStore: CleanupLibraryCloudStoring {
    private static let containerIdentifier = "iCloud.app.entrevoix.shared"
    private static let recordType = "CleanupLibrary"
    private static let recordName = "library-v1"
    private static let payloadKey = "payload"

    private let database: CKDatabase

    init() {
        database = CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase
    }

    init(database: CKDatabase) {
        self.database = database
    }

    func fetchLibrary() async throws -> CleanupLibrary? {
        let recordID = CKRecord.ID(recordName: Self.recordName)
        do {
            let record = try await database.record(for: recordID)
            guard let payload = record[Self.payloadKey] as? Data else { return nil }
            return try JSONDecoder().decode(CleanupLibrary.self, from: payload)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func saveLibrary(_ library: CleanupLibrary) async throws {
        let payload = try JSONEncoder().encode(library)
        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(recordName: Self.recordName)
        )
        record[Self.payloadKey] = payload as CKRecordValue
        _ = try await database.save(record)
    }
}

struct CleanupLibrary: Codable, Equatable, Sendable {
    let prompts: [CleanupPrompt]
    let workflows: [CleanupWorkflow]
}
