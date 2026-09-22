import Foundation
import Security

/// Minimal keychain wrapper for the access token and device identity —
/// the pieces that shouldn't live in UserDefaults.
nonisolated enum KeychainStore {
    enum StoreError: LocalizedError {
        case operationFailed(String, OSStatus)
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .operationFailed(let operation, let status):
                "The keychain could not \(operation) credentials (\(status))."
            case .verificationFailed:
                "The keychain did not preserve the saved credential."
            }
        }
    }

    private static let service = "ee.helop.lagoon"

    static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw StoreError.operationFailed("save", addStatus)
            }
        } else if status != errSecSuccess {
            throw StoreError.operationFailed("update", status)
        }
    }

    static func delete(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.operationFailed("delete", status)
        }
    }

    /// Account names only, never values. Lets a forgotten account's Seerr
    /// cookies be removed, including for servers no longer configured.
    static func accountNames() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw StoreError.operationFailed("inspect", status) }
        guard let entries = result as? [[String: Any]] else { throw StoreError.verificationFailed }
        return entries.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

nonisolated protocol AccountCredentialStorage: Sendable {
    func string(for account: String) -> String?
    func set(_ value: String, for account: String) throws
    func delete(_ account: String) throws
    func accountNames() throws -> [String]
}

nonisolated struct SystemAccountCredentials: AccountCredentialStorage {
    func string(for account: String) -> String? { KeychainStore.string(for: account) }
    func set(_ value: String, for account: String) throws { try KeychainStore.set(value, for: account) }
    func delete(_ account: String) throws { try KeychainStore.delete(account) }
    func accountNames() throws -> [String] { try KeychainStore.accountNames() }
}
