import Foundation
import Security

/// Persistence for credentials. The app uses `Keychain`; tests use an in-memory double.
/// (The real Keychain needs a signed, entitled process, so it can't run under `swift test`.)
public protocol SecureStore: Sendable {
    func set(_ data: Data, for account: String) throws
    func get(_ account: String) throws -> Data?
    func delete(_ account: String) throws
    func deleteAll() throws
}

public extension SecureStore {
    /// Codable convenience — stores JSON.
    func set<T: Encodable>(_ value: T, for account: String) throws {
        try set(JSONEncoder().encode(value), for: account)
    }

    func value<T: Decodable>(_ type: T.Type, for account: String) throws -> T? {
        guard let data = try get(account) else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Thin wrapper over the Security framework for generic-password items.
/// All credentials in Confluence live here — never in UserDefaults, files, or logs.
/// Items are `kSecAttrAccessibleWhenUnlocked`.
public struct Keychain: SecureStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
    }

    // Use the data-protection keychain (not the legacy file-based one) for iOS-consistent
    // semantics, correct bulk delete, and compatibility with the app sandbox.
    private func query(_ extra: [String: Any] = [:]) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        query.merge(extra) { $1 }
        return query
    }

    public func set(_ data: Data, for account: String) throws {
        let base = query([kSecAttrAccount as String: account])
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addStatus = SecItemAdd(base.merging(attributes) { $1 } as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public func get(_ account: String) throws -> Data? {
        let query = query([
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(query([kSecAttrAccount as String: account]) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes every item for this service. Used on logout.
    public func deleteAll() throws {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
