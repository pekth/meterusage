import Foundation
import LocalAuthentication
import Security

// The helper has two fixed provider modes. Background polling cannot open an auth dialog.
let context = LAContext()
context.interactionNotAllowed = !CommandLine.arguments.contains("--allow-ui")
SecKeychainSetUserInteractionAllowed(!context.interactionNotAllowed)
let grok = CommandLine.arguments.contains("--grok-bot")
guard CommandLine.arguments.dropFirst().allSatisfy({ ["--allow-ui", "--grok-bot"].contains($0) }) else { exit(1) }
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: grok ? "Grok Bot Safe Storage" : "Claude Safe Storage",
    kSecAttrAccount as String: grok ? "Grok Bot Key" : "Claude Key",
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
    kSecUseAuthenticationContext as String: context
]
var result: CFTypeRef?
guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let password = result as? Data, !password.isEmpty else { exit(1) }
// Only the owning main process receives stdout. Never run this helper for QA.
FileHandle.standardOutput.write(password)
