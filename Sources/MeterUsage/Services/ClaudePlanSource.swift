import Foundation

// MARK: - ClaudePlanSource
//
// Reports which Claude Code plan the user is signed in under (Pro, Max 5x,
// Max 20x, ...) by reading `~/.claude.json`, key path
// `oauthAccount.organizationRateLimitTier` (verified on a real account:
// `"default_claude_max_20x"` alongside `organizationType: "claude_max"`).
// `seatTier` and `userRateLimitTier` are both `null` on that account, so
// they are consulted only as a fallback when `organizationRateLimitTier` is
// absent — never as the primary source.
//
// *** PRIVACY — READ THIS BEFORE TOUCHING THE DECODE TYPES BELOW ***
//
// `~/.claude.json`'s `oauthAccount` object ALSO carries `emailAddress`,
// `displayName`, `accountUuid`, `organizationUuid`, `organizationName`, and
// `subscriptionCreatedAt` — real identifying data, in a repo that is public.
// `OAuthAccountTierFields` below is a `Decodable` struct that declares ONLY
// the tier keys this source needs. `Decodable` silently ignores any JSON key
// it wasn't told to decode, so those identifying fields are never
// materialized into any Swift value anywhere in this process — that is the
// entire privacy defense, and it is structural (a decode shape), not a
// convention someone has to remember to uphold.
//
// DO NOT:
//   - decode `oauthAccount` (or the whole file) via `JSONSerialization` or
//     into `[String: Any]` / any dictionary — that would hold the
//     identifying fields in memory even if nothing reads them back out.
//   - widen `OAuthAccountTierFields` to add `emailAddress`, `displayName`,
//     `accountUuid`, `organizationUuid`, `organizationName`, or
//     `subscriptionCreatedAt`.
//   - log, cache, persist, or return anything from this file except the
//     resulting `PlanTier`.
//
// If a future feature genuinely needs one of those fields, it needs its own
// explicit privacy review — do not casually add a key here to unblock
// something else.
public struct ClaudePlanSource: PlanSource {
    public let provider: Provider = .claude

    /// Path to `~/.claude.json`. Injectable so tests never read the real
    /// file — they point this at a fixture instead.
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? HomeDirectory.real.appendingPathComponent(".claude.json")
    }

    public func fetchPlan() async throws -> PlanTier {
        // Missing file, missing key, or unparseable JSON are all a normal
        // "nothing to report" state (e.g. the user has never used Claude
        // Code) — never surfaced as an error.
        guard let data = try? Data(contentsOf: fileURL) else {
            throw SourceUnavailable.noData
        }
        guard let root = try? JSONDecoder().decode(RootTierFields.self, from: data) else {
            throw SourceUnavailable.noData
        }
        guard let raw = root.oauthAccount?.primaryTierString else {
            throw SourceUnavailable.noData
        }
        return PlanTier.fromRateLimitTier(raw)
    }

    // MARK: - Narrow decode shape (see privacy note above)

    /// Top-level shape of `~/.claude.json` we care about. Every other
    /// top-level key in that file (there are many — project state, MCP
    /// config, etc.) is simply ignored by `Decodable`.
    struct RootTierFields: Decodable {
        let oauthAccount: OAuthAccountTierFields?
    }

    /// ONLY the tier-related keys from `oauthAccount`. Do not add fields
    /// here — see the file-level privacy note.
    struct OAuthAccountTierFields: Decodable {
        let organizationRateLimitTier: String?
        let seatTier: String?
        let userRateLimitTier: String?

        /// `organizationRateLimitTier` is the verified primary source.
        /// `seatTier` and `userRateLimitTier` are consulted only as
        /// fallbacks when it's absent, per the observed account where both
        /// are `null` alongside a populated `organizationRateLimitTier`.
        var primaryTierString: String? {
            if let tier = organizationRateLimitTier, !tier.isEmpty {
                return tier
            }
            if let tier = seatTier, !tier.isEmpty {
                return tier
            }
            if let tier = userRateLimitTier, !tier.isEmpty {
                return tier
            }
            return nil
        }
    }
}
