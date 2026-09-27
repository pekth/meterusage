import Foundation

/// Keys belong to this process only. No defaults, files, or Keychain writes.
final class APIKeySession: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [Provider: String] = [:]
    private var revisions: [Provider: Int] = [:]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        set(environment["OPENAI_ADMIN_KEY"], for: .openAI)
        set(environment["ANTHROPIC_ADMIN_KEY"], for: .anthropic)
    }

    func key(for provider: Provider) -> String? {
        lock.withLock { keys[provider] }
    }

    func revision(for provider: Provider) -> Int {
        lock.withLock { revisions[provider, default: 0] }
    }

    func set(_ key: String?, for provider: Provider) {
        lock.withLock {
            let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
            keys[provider] = trimmed?.isEmpty == false ? trimmed : nil
            revisions[provider, default: 0] += 1
        }
    }
}
