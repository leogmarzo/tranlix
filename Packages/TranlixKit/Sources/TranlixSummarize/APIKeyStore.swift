import Foundation
import Security

/// The Anthropic API key, in the login keychain.
///
/// Never in `UserDefaults` and never in the binary: it is a credential that can spend the
/// user's money, and both of those are readable by anything running as them. The keychain at
/// least ties access to this signed application.
public struct APIKeyStore: Sendable {
    /// Keychain service name. Fixed forever — changing it would orphan the stored key.
    public static let defaultService = "com.leomarzo.tranlix.anthropic"

    public let service: String
    public let account: String

    public init(service: String = APIKeyStore.defaultService, account: String = "default") {
        self.service = service
        self.account = account
    }

    public enum KeychainError: Error, LocalizedError, Equatable {
        case failed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case let .failed(status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
                return "No se pudo acceder al llavero: \(detail)"
            }
        }
    }

    // MARK: - Reading

    public func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
                return nil
            }
            return key.isEmpty ? nil : key
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.failed(status)
        }
    }

    public var hasKey: Bool {
        ((try? read()) ?? nil) != nil
    }

    // MARK: - Writing

    /// Stores a key, replacing any previous one. An empty string removes it, so the same
    /// field in Settings both sets and clears.
    public func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try delete() }

        let data = Data(trimmed.utf8)
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.failed(status) }

        var insert = baseQuery
        insert[kSecValueData as String] = data
        // Available without unlocking after the first unlock, and never synced to iCloud:
        // this key belongs to this machine, not to the user's account.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.failed(added) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.failed(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
