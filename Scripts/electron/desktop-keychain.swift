import Foundation
import LocalAuthentication
import Security

// Only fixed provider items may be read. Background polling cannot open an auth dialog.
let modes = CommandLine.arguments.dropFirst().filter { $0 != "--allow-ui" }
guard modes.count <= 1, modes.allSatisfy({ ["--grok-bot", "--api-openai", "--api-anthropic"].contains($0) }),
      CommandLine.arguments.dropFirst().filter({ $0 == "--allow-ui" }).count <= 1 else { exit(1) }
let context = LAContext()
context.interactionNotAllowed = !CommandLine.arguments.contains("--allow-ui")
SecKeychainSetUserInteractionAllowed(!context.interactionNotAllowed)
let grok = CommandLine.arguments.contains("--grok-bot")
let api = modes.first?.hasPrefix("--api-") == true
var query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: api ? "com.meterusage.api-keys" : grok ? "Grok Bot Safe Storage" : "Claude Safe Storage",
    kSecAttrAccount as String: api ? modes.first == "--api-openai" ? "openAI" : "anthropic" : grok ? "Grok Bot Key" : "Claude Key",
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne,
    kSecUseAuthenticationContext as String: context
]
if api { query[kSecAttrSynchronizable as String] = false }
var result: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &result)
if api && status == errSecItemNotFound { exit(0) }
// Distinct exit for a background read that would need an access prompt ("Allow" was chosen, not "Always Allow").
if context.interactionNotAllowed && status == errSecInteractionNotAllowed { exit(2) }
guard status == errSecSuccess,
      let password = result as? Data, !password.isEmpty else { exit(1) }
// Only the owning main process receives stdout. Never run this helper for QA.
FileHandle.standardOutput.write(password)
