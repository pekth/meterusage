import Foundation

// MARK: - Shared domain model
//
// These types are the contract between every data source and every view.
// Sources produce them; views consume them. Nothing else crosses the boundary.
//
// PRIVACY CONTRACT (enforced by tests):
// No type in this file may carry a credential, token, account id, email,
// hostname, installation id, or absolute filesystem path. Project identity is
// a display name only, already stripped of its path by the source that made it.

/// A single rate-limit window reported by a provider.
public struct QuotaWindow: Equatable, Sendable {
    /// Human label for the window, e.g. "5-hour", "Weekly".
    public let label: String
    /// Percent of the window consumed, 0...100.
    public let usedPercent: Double
    /// When the window rolls over. `nil` when the provider does not say.
    public let resetsAt: Date?

    public init(label: String, usedPercent: Double, resetsAt: Date?) {
        self.label = label
        self.usedPercent = usedPercent.clamped(to: 0...100)
        self.resetsAt = resetsAt
    }

    /// Fraction 0...1, convenient for progress bars.
    public var fraction: Double { usedPercent / 100 }
}

/// Prepaid credit balance, where a provider exposes one.
public struct CreditBalance: Equatable, Sendable {
    public let balance: Double
    public let hasCredits: Bool
    public let unlimited: Bool
    /// Dollars consumed so far this cycle, where the provider reports a
    /// used/limit pair rather than (or in addition to) a remaining
    /// `balance`. `nil` when the source only knows a remaining balance
    /// (e.g. Codex today) — views must not assume this is ever populated.
    public let usedDollars: Double?
    /// The monthly cap in dollars, paired with `usedDollars`. `nil` under
    /// the same conditions as `usedDollars`.
    public let limitDollars: Double?

    public init(
        balance: Double,
        hasCredits: Bool,
        unlimited: Bool,
        usedDollars: Double? = nil,
        limitDollars: Double? = nil
    ) {
        self.balance = balance
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.usedDollars = usedDollars
        self.limitDollars = limitDollars
    }
}

/// Live quota for one provider. Absent windows simply aren't shown.
public struct ProviderQuota: Equatable, Sendable {
    public let provider: Provider
    public let windows: [QuotaWindow]
    public let credits: CreditBalance?
    /// Plan name if the provider reports one, e.g. "plus". Never an account id.
    public let planType: String?
    public let capturedAt: Date

    public init(
        provider: Provider,
        windows: [QuotaWindow],
        credits: CreditBalance? = nil,
        planType: String? = nil,
        capturedAt: Date
    ) {
        self.provider = provider
        self.windows = windows
        self.credits = credits
        self.planType = planType
        self.capturedAt = capturedAt
    }
}

public enum Provider: String, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

// MARK: - Local activity (computed from the user's own transcripts)

/// Token counts for a slice of local activity.
public struct TokenTotals: Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Int { input + output + cacheRead + cacheWrite }

    public static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }
}

/// One local session, summarised. Contains no path and no session id.
public struct SessionSummary: Equatable, Sendable, Identifiable {
    /// Stable, non-reversible identifier for list diffing. Derived by hashing the
    /// source id — never the raw session id, which can appear in shared output.
    public let id: String
    /// Last path component of the project directory only, e.g. "meterusage".
    public let projectName: String
    public let model: String
    public let tokens: TokenTotals
    public let estimatedCostUSD: Double
    public let startedAt: Date
    public let messageCount: Int

    public init(
        id: String,
        projectName: String,
        model: String,
        tokens: TokenTotals,
        estimatedCostUSD: Double,
        startedAt: Date,
        messageCount: Int
    ) {
        self.id = id
        self.projectName = projectName
        self.model = model
        self.tokens = tokens
        self.estimatedCostUSD = estimatedCostUSD
        self.startedAt = startedAt
        self.messageCount = messageCount
    }
}

/// A day's worth of local activity, for the heatmap.
public struct DailyActivity: Equatable, Sendable {
    public let day: Date
    public let tokens: TokenTotals
    public let estimatedCostUSD: Double
    public let sessionCount: Int

    public init(day: Date, tokens: TokenTotals, estimatedCostUSD: Double, sessionCount: Int) {
        self.day = day
        self.tokens = tokens
        self.estimatedCostUSD = estimatedCostUSD
        self.sessionCount = sessionCount
    }
}

/// Everything computed locally for one provider.
public struct LocalActivity: Equatable, Sendable {
    public let provider: Provider
    public let sessions: [SessionSummary]
    public let daily: [DailyActivity]
    public let scannedAt: Date

    public init(provider: Provider, sessions: [SessionSummary], daily: [DailyActivity], scannedAt: Date) {
        self.provider = provider
        self.sessions = sessions
        self.daily = daily
        self.scannedAt = scannedAt
    }

    public static func empty(_ provider: Provider) -> LocalActivity {
        LocalActivity(provider: provider, sessions: [], daily: [], scannedAt: .distantPast)
    }

    public var totalTokens: TokenTotals {
        sessions.reduce(TokenTotals()) { $0 + $1.tokens }
    }

    public var totalCostUSD: Double {
        sessions.reduce(0) { $0 + $1.estimatedCostUSD }
    }
}

// MARK: - Plan

/// Which subscription tier the local CLI is signed in under.
///
/// Displayed so a user can tell at a glance whether the quota bars they're
/// looking at belong to a Pro, Max 5x, or Max 20x allowance — the same
/// percentage means very different headroom on different plans.
public enum PlanTier: Equatable, Sendable {
    case free
    case pro
    case max5x
    case max20x
    case team
    case enterprise
    /// A tier string we don't recognise. Carried verbatim so a new plan shows
    /// something truthful rather than being silently mislabelled as a known one.
    case other(String)

    public var displayName: String {
        switch self {
        case .free:       return "Free"
        case .pro:        return "Pro"
        case .max5x:      return "Max 5\u{00D7}"
        case .max20x:     return "Max 20\u{00D7}"
        case .team:       return "Team"
        case .enterprise: return "Enterprise"
        case .other(let raw): return raw
        }
    }

    /// Maps the rate-limit tier identifier used by Claude's local account
    /// metadata onto a display tier.
    ///
    /// Matching is substring-based and deliberately ordered so `max_20x` is
    /// tested before `max_5x` — a prefix test would let "max" swallow both.
    /// Unknown values fall through to `.other`, never to a guessed plan.
    public static func fromRateLimitTier(_ raw: String) -> PlanTier {
        let v = raw.lowercased()
        if v.contains("max_20x") || v.contains("max20x") { return .max20x }
        if v.contains("max_5x") || v.contains("max5x")   { return .max5x }
        if v.contains("enterprise")                       { return .enterprise }
        if v.contains("team")                             { return .team }
        if v.contains("pro")                              { return .pro }
        if v.contains("free")                             { return .free }
        return .other(raw)
    }
}

/// Reads which plan the local Claude CLI is signed in under.
public protocol PlanSource: Sendable {
    var provider: Provider { get }
    func fetchPlan() async throws -> PlanTier
}

// MARK: - Service health

public enum Severity: Int, Comparable, Sendable {
    case operational = 0
    case degraded = 1
    case partialOutage = 2
    case majorOutage = 3
    case unknown = 4

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .operational:   return "Operational"
        case .degraded:      return "Degraded"
        case .partialOutage: return "Partial Outage"
        case .majorOutage:   return "Major Outage"
        case .unknown:       return "Unknown"
        }
    }
}

public struct ServiceStatus: Equatable, Sendable {
    public let provider: Provider
    public let severity: Severity
    public let description: String
    public let checkedAt: Date

    public init(provider: Provider, severity: Severity, description: String, checkedAt: Date) {
        self.provider = provider
        self.severity = severity
        self.description = description
        self.checkedAt = checkedAt
    }
}

// MARK: - Errors

/// Why a source produced nothing. Rendered to the user verbatim, so these
/// strings must never interpolate a provider error body (those can echo URLs,
/// headers, or request detail we don't control).
public enum SourceUnavailable: Error, Equatable, Sendable {
    /// The provider CLI isn't installed.
    case cliNotFound(String)
    /// The CLI is installed but the user isn't signed in.
    case notSignedIn(Provider)
    /// The call ran but couldn't reach the network.
    case offline
    /// The call ran and failed for a reason we deliberately don't surface raw.
    case failed(Provider)
    /// Nothing to read yet, which is normal on a fresh machine.
    case noData

    public var userFacingMessage: String {
        switch self {
        case .cliNotFound(let name):  return "\(name) CLI not found"
        case .notSignedIn(let p):     return "Not signed in to \(p.displayName)"
        case .offline:                return "Offline"
        case .failed(let p):          return "Couldn't read \(p.displayName) usage"
        case .noData:                 return "No usage yet"
        }
    }
}

// MARK: - Utilities

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
