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
