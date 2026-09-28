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
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3, args[1].hasPrefix("com.meterusage.tests.") else {
            fatalError("Usage: keychain-smoke com.meterusage.tests.<unique-id> save|read|replace|remove|empty|update")
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
            precondition(SecKeychainUnlock(keychain, UInt32(password.utf8.count), password, true) == errSecSuccess)
        }
        let store = KeychainAPIKeyStore(service: args[1], keychain: keychain)
        let keys = APIKeySession(environment: [:], store: store)
        for provider in [Provider.openAI, .anthropic] {
            switch args[2] {
            case "save":
                let existing = try store.read(provider)
                precondition(existing == nil)
                try keys.set("fixture-original", for: provider)
            case "read":
                precondition(keys.key(for: provider) == "fixture-original")
            case "replace":
                try keys.set("fixture-replacement", for: provider)
                let replacement = try store.read(provider)
                precondition(replacement == "fixture-replacement")
            case "remove":
                try keys.set(nil, for: provider)
            case "empty":
                let remaining = try store.read(provider)
                precondition(remaining == nil)
            case "update":
                // A rebuilt ad-hoc binary can need approval, but its item must still exist.
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                           kSecAttrService as String: args[1],
                                           kSecAttrAccount as String: provider.rawValue,
                                           kSecMatchSearchList as String: [keychain!],
                                           kSecReturnAttributes as String: true]
                var attributes: CFTypeRef?
                precondition(SecItemCopyMatching(query as CFDictionary, &attributes) == errSecSuccess)
                if keys.restoreErrors[provider] != nil {
                    print("\(provider.rawValue): saved item retained; new binary requires Keychain authorization")
                } else {
                    precondition(keys.key(for: provider) == "fixture-original")
                    print("\(provider.rawValue): saved item readable by rebuilt binary")
                }
            default: fatalError("Unknown smoke action")
            }
        }
        if args[2] == "empty" { precondition(SecKeychainDelete(keychain) == errSecSuccess) }
        print("PASS: \(args[2])")
    }
}
