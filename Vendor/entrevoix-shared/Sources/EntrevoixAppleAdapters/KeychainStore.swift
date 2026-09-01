import Foundation
import EntrevoixCore
import Security

enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status): "Keychain error (\(status))."
        }
    }
}

protocol KeychainAccessing: Sendable {
    func read(service: String, account: String) throws -> Data?
    func upsert(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

struct SystemKeychainAccess: KeychainAccessing {
    func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(status) }
        return item as? Data
    }

    func upsert(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public final class KeychainStore: SecretStoring {
    private let service: String
    private let legacyService: String?
    private let secretsAccount = "api-keys"
    private let access: any KeychainAccessing

    public convenience init(
        service: String = "com.d9beuD.Entrevoix",
        legacyService: String? = nil
    ) {
        self.init(
            service: service,
            legacyService: legacyService,
            access: SystemKeychainAccess()
        )
    }

    init(
        service: String,
        legacyService: String?,
        access: any KeychainAccessing = SystemKeychainAccess()
    ) {
        self.service = service
        self.legacyService = legacyService
        self.access = access
    }

    public func read(profileID: UUID) throws -> String? {
        try read(profileIDs: [profileID])[profileID]
    }

    /// Reads the requested secrets from one Keychain item.
    ///
    /// Earlier releases stored one item per profile. They are read only when
    /// the consolidated item does not exist yet, then migrated for subsequent
    /// launches.
    public func read(profileIDs: [UUID]) throws -> [UUID: String] {
        let requestedIDs = Set(profileIDs)
        guard !requestedIDs.isEmpty else { return [:] }

        if let secrets = try readSecretsItem(service: service) {
            return secrets.filter { requestedIDs.contains($0.key) }
        }

        if let legacyService,
           legacyService != service,
           let secrets = try readSecretsItem(service: legacyService) {
            try save(secrets)
            return secrets.filter { requestedIDs.contains($0.key) }
        }

        var legacySecrets = try readLegacySecrets(profileIDs: requestedIDs, service: service)
        if let legacyService, legacyService != service {
            legacySecrets.merge(
                try readLegacySecrets(profileIDs: requestedIDs, service: legacyService),
                uniquingKeysWith: { current, _ in current }
            )
        }
        if !legacySecrets.isEmpty {
            try save(legacySecrets)
        }
        return legacySecrets
    }

    public func save(_ secrets: [UUID: String]) throws {
        let encodedSecrets = Dictionary(uniqueKeysWithValues: secrets.compactMap { profileID, secret in
            secret.isEmpty ? nil : (profileID.uuidString, secret)
        })
        if encodedSecrets.isEmpty {
            try access.delete(service: service, account: secretsAccount)
            return
        }

        let data = try JSONEncoder().encode(encodedSecrets)
        try access.upsert(data, service: service, account: secretsAccount)
    }

    private func readSecretsItem(service: String) throws -> [UUID: String]? {
        guard let data = try access.read(service: service, account: secretsAccount) else { return nil }
        guard
            let encodedSecrets = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }

        var secrets: [UUID: String] = [:]
        for (account, secret) in encodedSecrets {
            guard let profileID = UUID(uuidString: account) else { continue }
            secrets[profileID] = secret
        }
        return secrets
    }

    private func readLegacySecrets(profileIDs: Set<UUID>, service: String) throws -> [UUID: String] {
        var secrets: [UUID: String] = [:]
        for profileID in profileIDs {
            guard let data = try access.read(service: service, account: profileID.uuidString),
                  let secret = String(data: data, encoding: .utf8) else { continue }
            secrets[profileID] = secret
        }
        return secrets
    }
}
