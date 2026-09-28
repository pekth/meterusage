// Opt-in native smoke. Compile with Core/APIKeyStore.swift and Core/APIKeySession.swift.
// Runs only against a caller-chosen, isolated synthetic service. No provider requests.
import Foundation
import Security

// The production files only need this provider identity contract.
enum Provider: String { case openAI, anthropic
    var displayName: String { rawValue }
}

@main
struct KeychainSmoke {
    private static let authorizationNeededStatuses: Set<OSStatus> = [
        errSecAuthFailed,
        errSecInteractionNotAllowed,
        errSecUserCanceled,
    ]

    private static func metadata(for provider: Provider, service: String, keychain: SecKeychain) -> OSStatus {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: provider.rawValue,
                                   kSecMatchSearchList as String: [keychain],
                                   kSecReturnAttributes as String: true,
                                   kSecMatchLimit as String: kSecMatchLimitOne]
        var attributes: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &attributes)
    }

    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3, args[1].hasPrefix("com.meterusage.tests.") else {
            fatalError("Usage: keychain-smoke com.meterusage.tests.<unique-id> save|read|read-v1|locked|replace|remove|empty|update-v2")
        }
        // A denied read must return an error, never leave unattended tests at a password prompt.
        SecKeychainSetUserInteractionAllowed(false)
        // An isolated test Keychain avoids unlocking or reading the user's login Keychain.
        let path = NSTemporaryDirectory() + args[1] + ".keychain"
        let password = "synthetic-keychain-password"
        var keychain: SecKeychain?
        if args[2] == "save" {
            precondition(!FileManager.default.fileExists(atPath: path))
            precondition(SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &keychain) == errSecSuccess)
        } else {
            precondition(SecKeychainOpen(path, &keychain) == errSecSuccess)
            if args[2] != "locked" {
                let unlockStatus = SecKeychainUnlock(keychain, UInt32(password.utf8.count), password, true)
                precondition(unlockStatus == errSecSuccess, "unlock status=\(unlockStatus)")
            } else {
                precondition(SecKeychainLock(keychain) == errSecSuccess)
            }
        }
        let isolatedKeychain = keychain!
        let store = KeychainAPIKeyStore(service: args[1], keychain: isolatedKeychain)
        let keys = APIKeySession(environment: [:], store: store)
        for provider in [Provider.openAI, .anthropic] {
            switch args[2] {
            case "save":
                let existing = try store.read(provider)
                precondition(existing == nil)
                try keys.set("fixture-original", for: provider)
            case "read", "read-v1":
                precondition(keys.key(for: provider) == "fixture-original")
            case "locked":
                precondition(keys.restoreErrors[provider] != nil)
                do {
                    _ = try store.read(provider)
                    preconditionFailure("locked read unexpectedly succeeded")
                } catch let error as APIKeyStoreError {
                    precondition(Self.authorizationNeededStatuses.contains(error.status))
                    print("\(provider.rawValue): locked read status=\(error.status) expected=true")
                }
                precondition(Self.metadata(for: provider, service: args[1], keychain: isolatedKeychain) == errSecSuccess)
            case "replace":
                try keys.set("fixture-replacement", for: provider)
                let replacement = try store.read(provider)
                precondition(replacement == "fixture-replacement")
            case "remove":
                try keys.set(nil, for: provider)
            case "empty":
                let remaining = try store.read(provider)
                precondition(remaining == nil)
            case "update-v2":
                // A rebuilt ad-hoc binary can need approval, but its item must still exist.
                precondition(Self.metadata(for: provider, service: args[1], keychain: isolatedKeychain) == errSecSuccess)
                do {
                    _ = try store.read(provider)
                    precondition(keys.restoreErrors[provider] == nil)
                    precondition(keys.key(for: provider) == "fixture-original")
                    print("\(provider.rawValue): saved item readable by rebuilt binary")
                } catch let error as APIKeyStoreError {
                    precondition(Self.authorizationNeededStatuses.contains(error.status))
                    precondition(keys.restoreErrors[provider] != nil)
                    print("\(provider.rawValue): saved item retained; authorization status=\(error.status) expected=true")
                } catch {
                    preconditionFailure("unexpected Keychain error")
                }
            default: fatalError("Unknown smoke action")
            }
        }
        if args[2] == "empty" { precondition(SecKeychainDelete(isolatedKeychain) == errSecSuccess) }
        print("PASS: \(args[2])")
    }
}
