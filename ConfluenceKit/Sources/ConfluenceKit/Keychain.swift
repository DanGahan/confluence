import Foundation
import Security

/// Persistence for credentials. The app uses `Keychain`; tests use an in-memory double.
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

/// In-memory credential store — used for UI tests so they never touch the real Keychain
/// (which, for unsigned/ad-hoc builds, pops a system prompt on every access).
public final class EphemeralSecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func set(_ data: Data, for account: String) throws { lock.withLock { items[account] = data } }
    public func get(_ account: String) throws -> Data? { lock.withLock { items[account] } }
    public func delete(_ account: String) throws { lock.withLock { _ = items.removeValue(forKey: account) } }
    public func deleteAll() throws { lock.withLock { items.removeAll() } }
}

/// Thin wrapper over the Security framework for generic-password items.
/// All credentials in Confluence live here — never in UserDefaults, files, or logs.
/// Items are `kSecAttrAccessibleWhenUnlocked`.
///
/// Prefers the data-protection keychain (correct for a signed, sandboxed app), but
/// falls back to the legacy keychain when it reports `errSecMissingEntitlement` — which
/// happens for unsigned / ad-hoc dev builds that have no team-derived access group.
// ponytail: the fallback is only for unsigned dev builds. A distributed (signed) build
// always uses the data-protection keychain and never falls back.
public struct Keychain: SecureStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public enum KeychainError: Error, Equatable, LocalizedError {
        case unexpectedStatus(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Couldn't access the Keychain (\(status): \(detail))."
            }
        }
    }

    private func query(dataProtection: Bool, _ extra: [String: Any] = [:]) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        query.merge(extra) { $1 }
        return query
    }

    public func set(_ data: Data, for account: String) throws {
        // Writes go to the data-protection keychain; only fall back to legacy when it
        // reports a missing entitlement (unsigned dev build).
        do {
            try write(data, account: account, dataProtection: true)
        } catch KeychainError.unexpectedStatus(errSecMissingEntitlement) {
            try write(data, account: account, dataProtection: false)
        }
    }

    private func write(_ data: Data, account: String, dataProtection: Bool) throws {
        let base = query(dataProtection: dataProtection, [kSecAttrAccount as String: account])
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
        // A read can't tell "absent" from "wrong keychain" by status, so check both.
        if let data = try read(account, dataProtection: true) { return data }
        return try read(account, dataProtection: false)
    }

    private func read(_ account: String, dataProtection: Bool) throws -> Data? {
        let query = query(dataProtection: dataProtection, [
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound, errSecMissingEntitlement:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func delete(_ account: String) throws {
        try deleteMatching(query(dataProtection: true, [kSecAttrAccount as String: account]))
        try deleteMatching(query(dataProtection: false, [kSecAttrAccount as String: account]))
    }

    /// Removes every item for this service, from both keychains. Used on logout.
    public func deleteAll() throws {
        try deleteMatching(query(dataProtection: true))
        try deleteMatching(query(dataProtection: false))
    }

    private func deleteMatching(_ query: [String: Any]) throws {
        // Data-protection deletes all matches at once; legacy deletes one at a time.
        var status = SecItemDelete(query as CFDictionary)
        while status == errSecSuccess {
            status = SecItemDelete(query as CFDictionary)
        }
        guard status == errSecItemNotFound || status == errSecMissingEntitlement else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
