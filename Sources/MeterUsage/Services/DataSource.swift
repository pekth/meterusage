import Foundation

// MARK: - Source contracts
//
// Every data source implements one of these. Sources are plain async functions
// with no shared state, which keeps them trivially testable against fixtures.

/// A source of live, provider-reported quota.
public protocol QuotaSource: Sendable {
    var provider: Provider { get }
    /// Returns current quota, or throws `SourceUnavailable`.
    func fetchQuota() async throws -> ProviderQuota
}

/// Optional account action exposed by a quota source. Keeping redemption out
/// of `QuotaSource` means every read-only provider remains read-only, while
/// Codex can expose its explicit, user-confirmed reset action.
public protocol QuotaResetConsumer: Sendable {
    func consumeReset(creditID: String) async throws -> Bool
}

/// A source of locally-computed activity, derived from the user's own files.
public protocol LocalActivitySource: Sendable {
    var provider: Provider { get }
    /// Scans local transcripts. Never performs network I/O.
    func scan() async throws -> LocalActivity
}

/// A local usage source for providers whose native history is not Claude's
/// token transcript format. Sources may report sessions/messages only when
/// token or cost data is unavailable.
public protocol UsageSource: Sendable {
    var provider: Provider { get }
    func fetchUsage() async throws -> ProviderUsage
}

/// A source of provider service health.
public protocol StatusSource: Sendable {
    var provider: Provider { get }
    func fetchStatus() async throws -> ServiceStatus
}

// MARK: - Filesystem helpers

public enum HomeDirectory {
    /// The user's real home directory.
    ///
    /// `NSHomeDirectory()` returns the container path when an app is sandboxed,
    /// which would silently point every source at an empty tree. Resolving via
    /// the password database gives the real home in both cases, so behaviour
    /// doesn't change if sandboxing is toggled later.
    public static var real: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty { return URL(fileURLWithPath: path) }
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }
}

// MARK: - Alternate-account slots
//
// People who hold two accounts with the same tool get a second meter row per
// tool slot (`.codexAlt`, `.claudeAlt`) rather than a merge, because two
// accounts' windows are two different budgets. What makes a slot real is a
// separately-configured CLI home directory on this Mac; `AccountSlots` is the
// one place that resolution lives.
//
// Pure data — no source construction happens here — and injectable in tests.

public enum AccountSlots {

    /// UserDefaults key holding the absolute path of the alternate Codex home.
    /// An environment variable of the same name is consulted first so a
    /// launch wrapper can override the stored value.
    public static let codexAltHomeKey = "meterusage.codexAltHome"
    /// UserDefaults key holding the absolute path of the alternate Claude
    /// config directory.
    public static let claudeAltConfigKey = "meterusage.claudeAltConfig"

    /// Where the alternate-account home paths come from. Injectable so tests
    /// never depend on the process environment.
    public protocol Environment: Sendable {
        func string(forKey key: String) -> String?
    }

    /// The process environment: the app's own launch environment is inherited
    /// by `make-app.sh` invocations and by the headless CLI.
    public struct ProcessEnvironment: Environment {
        public init() {}
        public func string(forKey key: String) -> String? {
            ProcessInfo.processInfo.environment[key]
        }
    }

    /// UserDefaults-backed overlay. Injectable for tests. `UserDefaults` is
    /// documented thread-safe; the unchecked conformance bridges the SDK's
    /// missing `Sendable` annotation rather than implying any real risk.
    public struct DefaultsEnvironment: @unchecked Sendable, Environment {
        private let defaults: UserDefaults
        public init(defaults: UserDefaults) { self.defaults = defaults }
        public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    }

    /// The concrete alternate-account home directories this machine has.
    public struct Resolved: Equatable, Sendable {
        /// Alternate Codex home (`CODEX_HOME`-equivalent). `nil` when no
        /// alternate Codex account is configured.
        public let codexAltHome: URL?
        /// Alternate Claude config directory (`CLAUDE_CONFIG_DIR`-equivalent).
        /// `nil` when no alternate Claude account is configured.
        public let claudeAltConfig: URL?

        /// Convenience for tests/composition: both slots absent.
        public static let none = Self(codexAltHome: nil, claudeAltConfig: nil)
    }

    /// Reads the raw string from the overlays and interprets it as a
    /// directory path. Empty or whitespace-only strings, "~" as configured,
    /// and missing values all resolve to nil — a stored-but-blank key is
    /// "not configured", never a broken path.
    static func resolve(
        key: String,
        overlays: [Environment],
        home: URL
    ) -> URL? {
        for overlay in overlays {
            guard let raw = overlay.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            if raw == "~" || raw.hasPrefix("~/") {
                return home.appendingPathComponent(String(raw.dropFirst(2)))
            }
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return nil
    }

    /// The resolved slot homes. Ordering matters: the process environment
    /// wins over stored defaults, so `launchctl setenv` or a shell-launched
    /// CLI run can override the persisted value without editing defaults.
    public static func resolve(
        codexKey: String = codexAltHomeKey,
        claudeKey: String = claudeAltConfigKey,
        overlays: [Environment] = [ProcessEnvironment(), DefaultsEnvironment(defaults: .standard)],
        home: URL = HomeDirectory.real
    ) -> Resolved {
        Resolved(
            codexAltHome: resolve(key: codexKey, overlays: overlays, home: home),
            claudeAltConfig: resolve(key: claudeKey, overlays: overlays, home: home)
        )
    }

    /// Whether the named slot has a home directory on this machine. Primary
    /// slots are always present — their sources handle a missing default
    /// installation by reporting "not signed in", which is information.
    /// An alternate slot without its directory is not an account at all: it
    /// must not poll, render, or alert.
    public static func isPresent(
        _ provider: Provider,
        homes: Resolved,
        fileManager: FileManager = .default
    ) -> Bool {
        func dirExists(_ url: URL?) -> Bool {
            guard let url else { return false }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        switch provider {
        case .codexAlt: return dirExists(homes.codexAltHome)
        case .claudeAlt: return dirExists(homes.claudeAltConfig)
        default: return true
        }
    }
}

// MARK: - Privacy

/// Helpers that keep identifying data out of anything we display, cache, or log.
///
/// Rationale: provider payloads and local transcripts both carry material we
/// must not surface — absolute paths (which contain the OS username), machine
/// hostnames, installation UUIDs, account ids, and tokens. Every source funnels
/// through here so the rule is enforced in one place rather than remembered in
/// twenty.
public enum Privacy {

    /// Reduces a project path to its final component.
    ///
    /// Claude encodes project directories as flattened absolute paths (a leading
    /// `-Users-<name>-...`), so the raw value leaks the OS username. Only the
    /// last segment is ever meaningful to the user anyway.
    public static func projectName(fromEncodedPath encoded: String) -> String {
        let cleaned = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        // Claude replaces path separators with "-", so the last "-" segment is
        // the directory name. Fall back to the whole string if there isn't one.
        if let last = cleaned.split(separator: "-").last, !last.isEmpty {
            return String(last)
        }
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    /// Reduces an absolute working directory to its final component.
    public static func projectName(fromPath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "unknown" : name
    }

    /// A stable, non-reversible id for list diffing.
    ///
    /// Session ids can end up in screenshots and exported output, so we never
    /// carry the raw value into the model layer. This is a display-stability
    /// aid, not a security boundary.
    public static func opaqueID(_ raw: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
