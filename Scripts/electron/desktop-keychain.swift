import Foundation
import LocalAuthentication
import Security

// The helper has one fixed read. Background polling cannot open an auth dialog.
let context = LAContext()
context.interactionNotAllowed = !CommandLine.arguments.contains("--allow-ui")
SecKeychainSetUserInteractionAllowed(!context.interactionNotAllowed)
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "Claude Safe Storage",
    kSecAttrAccount as String: "Claude Key",
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
    kSecUseAuthenticationContext as String: context
]
var result: CFTypeRef?
guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let password = result as? Data, !password.isEmpty else { exit(1) }
// Only the owning main process receives stdout. Never run this helper for QA.
FileHandle.standardOutput.write(password)
