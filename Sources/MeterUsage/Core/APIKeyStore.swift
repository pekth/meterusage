import Foundation
import Security

/// Injected in tests so normal test runs never open the user's Keychain.
protocol APIKeyStore {
    func read(_ provider: Provider) throws -> String?
    func write(_ key: String?, for provider: Provider) throws
}

struct KeychainAPIKeyStore: APIKeyStore {
    let service: String
    private let keychain: SecKeychain?

    init(service: String = "com.meterusage.api-keys", keychain: SecKeychain? = nil) {
        self.service = service
        self.keychain = keychain
    }

    private func query(_ provider: Provider) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: provider.rawValue,
                                   kSecAttrSynchronizable as String: false]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        return query
    }

    func read(_ provider: Provider) throws -> String? {
        var query = query(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw APIKeyStoreError(operation: "read", status: status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw APIKeyStoreError(operation: "read", status: errSecDecode)
        }
        return key
    }

    func write(_ key: String?, for provider: Provider) throws {
        let query = query(provider)
        guard let key else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw APIKeyStoreError(operation: "remove", status: status)
            }
            return
        }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecMatchSearchList as String] = nil
            if let keychain { item[kSecUseKeychain as String] = keychain }
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrLabel as String] = "MeterUsage \(provider.displayName)"
            // Keep macOS's default application access control. Never allow all apps.
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw APIKeyStoreError(operation: "save", status: status) }
    }
}

struct APIKeyStoreError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "Could not \(operation) the API key in macOS Keychain (\(status)). Allow MeterUsage access in Keychain and try again."
    }
}
