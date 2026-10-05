import Foundation

/// In-memory keys backed by the app's Keychain store in normal app launches.
final class APIKeySession: @unchecked Sendable {
    private let lock = NSLock()
    private let store: APIKeyStore?
    private let environment: [String: String]
    private var keys: [Provider: String] = [:]
    private var revisions: [Provider: Int] = [:]
    private(set) var restoreErrors: [Provider: String] = [:]

    init(environment: [String: String] = ProcessInfo.processInfo.environment, store: APIKeyStore? = nil) {
        self.environment = environment
        self.store = store
        for provider in [Provider.openAI, .anthropic] {
            do { try restore(provider) }
            catch { restoreErrors[provider] = Self.message(for: error) }
        }
    }

    func key(for provider: Provider) -> String? {
        lock.withLock { keys[provider] }
    }

    func revision(for provider: Provider) -> Int {
        lock.withLock { revisions[provider, default: 0] }
    }

    func set(_ key: String?, for provider: Provider) throws {
        try lock.withLock {
            let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed?.isEmpty == false ? trimmed : nil
            // Save/delete first. A denied write must not forget the current key.
            try store?.write(value, for: provider)
            keys[provider] = value
            revisions[provider, default: 0] += 1
        }
    }

    func restore(_ provider: Provider) throws {
        try lock.withLock {
            let variable = provider == .openAI ? "OPENAI_ADMIN_KEY" : "ANTHROPIC_ADMIN_KEY"
            let value = try store?.read(provider) ?? environment[variable]
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            keys[provider] = trimmed?.isEmpty == false ? trimmed : nil
            revisions[provider, default: 0] += 1
        }
    }

    static func message(for error: Error) -> String {
        (error as? APIKeyStoreError)?.errorDescription ?? "Could not access the API key in macOS Keychain. Try again."
    }
}
