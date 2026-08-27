import CloudKit
import CryptoKit
import EntrevoixCore
import Foundation

@MainActor
protocol DictationDictionaryCloudStoring {
    func bootstrap(localTerms: [String], seedLocalTerms: Bool) async throws -> [String]
    func fetchTerms() async throws -> [String]?
    func saveTerms(_ terms: [String], replacing previousTerms: [String]?) async throws
    func ensureSubscription(id: String) async throws
}

@MainActor
final class DictationDictionaryCloudSync {
    static let subscriptionID = "dictation-dictionary-v1-macos"
    var onRemoteTerms: (([String]) -> Void)?

    private let store: any DictationDictionaryCloudStoring
    private var lastTerms: [String]?
    private var syncTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?

    init(store: any DictationDictionaryCloudStoring = CloudKitDictationDictionaryStore()) {
        self.store = store
    }

    deinit {
        syncTask?.cancel()
        publishTask?.cancel()
    }

    func start(with localTerms: [String], seedLocalTerms: Bool) {
        syncTask?.cancel()
        let terms = AppPreferences.normalizedDictationDictionary(localTerms)
        syncTask = Task { @MainActor [weak self, store] in
            do {
                try await store.ensureSubscription(id: Self.subscriptionID)
                let remoteTerms = try await store.bootstrap(localTerms: terms, seedLocalTerms: seedLocalTerms)
                guard !Task.isCancelled else { return }
                self?.lastTerms = remoteTerms
                self?.onRemoteTerms?(remoteTerms)
            } catch { }
        }
    }

    func publish(_ terms: [String]) {
        publishTask?.cancel()
        let normalizedTerms = AppPreferences.normalizedDictationDictionary(terms)
        let previousTerms = lastTerms
        publishTask = Task { @MainActor [weak self, store] in
            do {
                let replacement = if let previousTerms { previousTerms } else { try await store.fetchTerms() }
                try await store.saveTerms(normalizedTerms, replacing: replacement)
                guard !Task.isCancelled else { return }
                self?.lastTerms = normalizedTerms
            } catch { }
        }
    }

    func refresh() {
        syncTask?.cancel()
        syncTask = Task { @MainActor [weak self, store] in
            do {
                guard let terms = try await store.fetchTerms(), !Task.isCancelled else { return }
                self?.lastTerms = terms
                self?.onRemoteTerms?(terms)
            } catch { }
        }
    }
}

@MainActor
final class CloudKitDictationDictionaryStore: DictationDictionaryCloudStoring {
    private static let containerIdentifier = "iCloud.app.entrevoix.shared"
    private static let recordType = "DictationDictionaryItemV1"
    private static let markerRecordName = "dictionary-v1"
    private static let payloadKey = "payload"
    private static let orderKey = "order"
    private static let tombstoneKey = "tombstone"

    private let database: CKDatabase

    init() { database = CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase }
    init(database: CKDatabase) { self.database = database }

    func bootstrap(localTerms: [String], seedLocalTerms: Bool) async throws -> [String] {
        if let terms = try await fetchTerms() { return terms }
        let normalizedTerms = AppPreferences.normalizedDictationDictionary(localTerms)
        if seedLocalTerms { try await saveTerms(normalizedTerms, replacing: nil) }
        return normalizedTerms
    }

    func fetchTerms() async throws -> [String]? {
        let (results, _) = try await database.records(matching: CKQuery(recordType: Self.recordType, predicate: NSPredicate(value: true)))
        var marker = false
        var terms = [(Int, String)]()
        for (_, result) in results {
            let record = try result.get()
            if record.recordID.recordName == Self.markerRecordName { marker = true; continue }
            guard (record[Self.tombstoneKey] as? NSNumber)?.boolValue != true,
                  let payload = record[Self.payloadKey] as? Data else { continue }
            terms.append((record[Self.orderKey] as? Int ?? .max, try JSONDecoder().decode(String.self, from: payload)))
        }
        guard marker else { return nil }
        return AppPreferences.normalizedDictationDictionary(
            terms.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map(\.1)
        )
    }

    func saveTerms(_ terms: [String], replacing previousTerms: [String]?) async throws {
        let normalizedTerms = AppPreferences.normalizedDictationDictionary(terms)
        let previousTerms = AppPreferences.normalizedDictationDictionary(previousTerms ?? [])
        let previousOrders = Dictionary(uniqueKeysWithValues: previousTerms.enumerated().map { ($0.element, $0.offset) })
        var records = [markerRecord()]
        for (order, term) in normalizedTerms.enumerated() where previousOrders[term] != order || previousTerms.isEmpty {
            records.append(try itemRecord(term, order: order))
        }
        for term in Set(previousTerms).subtracting(normalizedTerms) {
            records.append(tombstoneRecord(term))
        }
        _ = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
    }

    func ensureSubscription(id: String) async throws {
        do {
            _ = try await database.subscription(for: CKSubscription.ID(id))
            return
        } catch let error as CKError {
            guard error.code == .unknownItem else { throw error }
        }
        let subscription = CKQuerySubscription(recordType: Self.recordType, predicate: NSPredicate(value: true), subscriptionID: CKSubscription.ID(id), options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        _ = try await database.save(subscription)
    }

    private func markerRecord() -> CKRecord { CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: Self.markerRecordName)) }
    private func itemRecord(_ term: String, order: Int) throws -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: recordID(for: term))
        record[Self.payloadKey] = try JSONEncoder().encode(term) as CKRecordValue
        record[Self.orderKey] = order as CKRecordValue
        record[Self.tombstoneKey] = NSNumber(value: false)
        return record
    }
    private func tombstoneRecord(_ term: String) -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: recordID(for: term))
        record[Self.tombstoneKey] = NSNumber(value: true)
        return record
    }
    private func recordID(for term: String) -> CKRecord.ID {
        let digest = SHA256.hash(data: Data(term.utf8)).map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: "term:\(digest)")
    }
}
