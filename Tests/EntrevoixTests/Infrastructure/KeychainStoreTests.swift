import Foundation
import XCTest
import EntrevoixCore
@testable import EntrevoixAppleAdapters
@testable import Entrevoix

final class KeychainStoreTests: XCTestCase {

    func testCodexCredentialVaultUsesDedicatedKeychainItemAndDeletesIt() async throws {
        let access = MemoryKeychainAccess()
        let vault = CodexCredentialVault(access: access)
        let credentials = CodexCredentials(
            accessToken: "access-secret",
            refreshToken: "refresh-secret",
            expiresAt: .distantFuture,
            accountID: "account",
            computeResidency: "eu"
        )

        try await vault.saveCodexCredentials(credentials)
        let restored = try await vault.readCodexCredentials()
        XCTAssertEqual(restored, credentials)
        XCTAssertTrue(access.upserts.contains { $0.1 == "codex-oauth" })

        try await vault.saveCodexCredentials(nil)
        let removed = try await vault.readCodexCredentials()
        XCTAssertNil(removed)
        XCTAssertTrue(access.deletes.contains { $0.1 == "codex-oauth" })
    }
    private let service = "EntrevoixTests"

    func testSaveReadFilterUpdateAndDelete() throws {
        let access = MemoryKeychainAccess()
        let store = KeychainStore(service: service, legacyService: nil, access: access)
        let first = UUID()
        let second = UUID()

        try store.save([first: "first-key", second: ""])
        XCTAssertEqual(try store.read(profileIDs: [first, second]), [first: "first-key"])
        XCTAssertEqual(access.upserts.map(\.1), ["api-keys"])

        try store.save([first: "updated", second: "second-key"])
        XCTAssertEqual(try store.read(profileID: first), "updated")
        XCTAssertEqual(try store.read(profileIDs: [second]), [second: "second-key"])

        try store.save([:])
        XCTAssertEqual(access.deletes.map(\.1), ["api-keys"])
        XCTAssertEqual(try store.read(profileIDs: []), [:])
    }

    func testMalformedConsolidatedDataAndInvalidUUIDsAreIgnored() throws {
        let access = MemoryKeychainAccess()
        let store = KeychainStore(service: service, legacyService: nil, access: access)
        let requested = UUID()
        access.seed(Data("not-json".utf8), service: service, account: "api-keys")
        XCTAssertEqual(try store.read(profileIDs: [requested]), [:])

        let data = try JSONEncoder().encode([
            "invalid": "ignored",
            requested.uuidString: "kept"
        ])
        access.seed(data, service: service, account: "api-keys")
        XCTAssertEqual(try store.read(profileIDs: [requested]), [requested: "kept"])
    }

    func testLegacyItemsAreReadAndMigrated() throws {
        let access = MemoryKeychainAccess()
        let store = KeychainStore(service: service, legacyService: nil, access: access)
        let first = UUID()
        let second = UUID()
        access.seed(Data("legacy-key".utf8), service: service, account: first.uuidString)

        XCTAssertEqual(try store.read(profileIDs: [first, second]), [first: "legacy-key"])
        XCTAssertEqual(access.reads.first?.1, "api-keys")
        XCTAssertEqual(Set(access.reads.dropFirst().map(\.1)), Set([first.uuidString, second.uuidString]))
        let migratedData = try XCTUnwrap(access.data(service: service, account: "api-keys"))
        let migrated = try JSONDecoder().decode([String: String].self, from: migratedData)
        XCTAssertEqual(migrated, [first.uuidString: "legacy-key"])
    }

    func testHistoricalServiceIsCopiedToCurrentService() throws {
        let access = MemoryKeychainAccess()
        let legacyService = "LegacyServiceTests"
        let store = KeychainStore(service: service, legacyService: legacyService, access: access)
        let profileID = UUID()
        let data = try JSONEncoder().encode([profileID.uuidString: "legacy-key"])
        access.seed(data, service: legacyService, account: "api-keys")

        XCTAssertEqual(try store.read(profileIDs: [profileID]), [profileID: "legacy-key"])
        XCTAssertEqual(access.data(service: service, account: "api-keys"), data)
        XCTAssertEqual(access.data(service: legacyService, account: "api-keys"), data)
    }

    func testBackendErrorsPropagateWithoutSecrets() {
        let access = MemoryKeychainAccess()
        access.readError = KeychainStoreError.unexpectedStatus(-50)
        let store = KeychainStore(service: service, legacyService: nil, access: access)

        XCTAssertThrowsError(try store.read(profileIDs: [UUID()])) { error in
            XCTAssertEqual(error.localizedDescription, "Keychain error (-50).")
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }

        let writeAccess = MemoryKeychainAccess()
        writeAccess.upsertError = KeychainStoreError.unexpectedStatus(-25299)
        XCTAssertThrowsError(try KeychainStore(service: service, legacyService: nil, access: writeAccess).save([UUID(): "key"]))

        let deleteAccess = MemoryKeychainAccess()
        deleteAccess.deleteError = KeychainStoreError.unexpectedStatus(-25300)
        XCTAssertThrowsError(try KeychainStore(service: service, legacyService: nil, access: deleteAccess).save([:]))
    }
}
