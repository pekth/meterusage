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


/// Burn rate pacing status: deficit (burning fast), surplus (well paced),
/// or on pace (within +/- 2%).
public enum QuotaPaceStatus: Equatable, Sendable {
    case deficit(Double)
    case surplus(Double)
    case onPace

    public var isDeficit: Bool {
        if case .deficit = self { return true }
        return false
    }

    public var isSurplus: Bool {
        if case .surplus = self { return true }
        return false
    }

    public var text: String {
        switch self {
        case .deficit: return "burning fast"
        case .surplus: return "well paced"
        case .onPace:   return "on pace"
        }
    }
}

/// Pacing metrics computed for a rate-limit window.
public struct QuotaPace: Equatable, Sendable {
    public let usedPercent: Double
    public let remainingPercent: Double
    public let elapsedPercent: Double
    public let deficitPercent: Double
    public let burnRate: Double
    public let projectedExhaustion: Date?
    public let status: QuotaPaceStatus

    public init(
        usedPercent: Double,
        remainingPercent: Double,
        elapsedPercent: Double,
        deficitPercent: Double,
        burnRate: Double,
        projectedExhaustion: Date? = nil,
        status: QuotaPaceStatus
    ) {
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.elapsedPercent = elapsedPercent
        self.deficitPercent = deficitPercent
        self.burnRate = burnRate
        self.projectedExhaustion = projectedExhaustion
        self.status = status
    }

    /// User-facing status string, handling early exhaustion clearly.
    public func statusText(usedPercent: Double) -> String {
        if usedPercent >= 100.0 {
            return "exhausted early"
        }
        return status.text
    }

    /// Effective time interval until exhaustion or reset (in seconds).
    public func etaInterval(resetsAt: Date?, now: Date = Date()) -> TimeInterval? {
        if let projectedExhaustion, projectedExhaustion > now {
            return projectedExhaustion.timeIntervalSince(now)
        }
        if let resetsAt, resetsAt > now, (burnRate <= 1.0 || status == .onPace || status.isSurplus) {
            return resetsAt.timeIntervalSince(now)
        }
        return nil
    }

    /// Whether this window should show an ambient ETA chip/subtitle.
    public func shouldShowAmbientETA(resetsAt: Date?, now: Date = Date()) -> Bool {
        if status.isDeficit { return true }
        if let eta = etaInterval(resetsAt: resetsAt, now: now), eta < 2 * 3600 {
            return true
        }
        return false
    }

    /// User-facing formatted ETA (e.g. "47m left" or "3h 12m left").
    public func etaText(resetsAt: Date?, now: Date = Date(), short: Bool = false) -> String? {
        guard let seconds = etaInterval(resetsAt: resetsAt, now: now) else { return nil }
        return Self.formatEta(seconds: seconds, short: short)
    }

    public static func formatEta(seconds: TimeInterval, short: Bool = false) -> String {
        let total = max(0, Int(seconds))
        if total < 60 {
            return short ? "< 1m" : "< 1m left"
        }
        let minutes = total / 60
        if minutes < 60 {
            return short ? "\(minutes)m" : "\(minutes)m left"
        }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        if hours < 24 {
            if short {
                return remMinutes == 0 ? "\(hours)h" : "\(hours)h \(remMinutes)m"
            } else {
                return remMinutes == 0 ? "\(hours)h left" : "\(hours)h \(remMinutes)m left"
            }
        }
        let days = hours / 24
        let remHours = hours % 24
        if short {
            return remHours == 0 ? "\(days)d" : "\(days)d \(remHours)h"
        } else {
            return remHours == 0 ? "\(days)d left" : "\(days)d \(remHours)h left"
        }
    }
}

/// A single rate-limit window reported by a provider.
public struct QuotaWindow: Equatable, Sendable {
    /// Human label for the window, e.g. "5-hour", "Weekly".
    public let label: String
    /// Percent of the window consumed, 0...100.
    public let usedPercent: Double
    /// When the window rolls over. `nil` when the provider does not say.
    public let resetsAt: Date?

    /// Window duration in minutes, if known (e.g. 300 for 5-hour, 10080 for weekly).
    public let windowDurationMins: Int?

    public init(label: String, usedPercent: Double, resetsAt: Date? = nil, windowDurationMins: Int? = nil) {
        self.label = label
        self.usedPercent = usedPercent.muClamped(to: 0...100)
        self.resetsAt = resetsAt
        self.windowDurationMins = windowDurationMins
    }

    /// Effective window duration in minutes, derived from `windowDurationMins`
    /// or inferred from the window label.
    public var effectiveDurationMins: Int? {
        if let windowDurationMins, windowDurationMins > 0 {
            return windowDurationMins
        }
        let lower = label.lowercased()
        if lower.contains("weekly") || lower.contains("7-day") || lower.contains("7 day") {
            return 10_080
        }
        if lower.contains("5-hour") || lower.contains("5 hour") || lower.contains("session") {
            return 300
        }
        if lower.contains("monthly") || lower.contains("30-day") || lower.contains("30 day") {
            return 43_200
        }
        if lower.contains("rolling") || lower.contains("daily") || lower.contains("24h") {
            return 1_440
        }
        return nil
    }

    /// Computes pacing and burn rate relative to the window's rollover time.
    public func pace(now: Date = Date()) -> QuotaPace? {
        guard let resetsAt, resetsAt > now,
              let durationMins = effectiveDurationMins, durationMins > 0 else {
            return nil
        }
        let durationSecs = Double(durationMins) * 60.0
        let windowStart = resetsAt.addingTimeInterval(-durationSecs)
        let elapsedSecs = now.timeIntervalSince(windowStart)
        guard elapsedSecs >= 0 else { return nil }

        let elapsedFraction = min(max(elapsedSecs / durationSecs, 0.0), 1.0)
        let elapsedPercent = elapsedFraction * 100.0
        let remainingPercent = max(0.0, 100.0 - usedPercent)
        let deficitPercent = usedPercent - elapsedPercent

        let burnRate: Double
        if elapsedFraction > 0.005 {
            burnRate = (usedPercent / 100.0) / elapsedFraction
        } else {
            burnRate = 1.0
        }

        var projectedExhaustion: Date? = nil
        if burnRate > 1.0 && usedPercent < 100.0 && usedPercent > 0.5 {
            let totalLifetimeSeconds = (100.0 / usedPercent) * elapsedSecs
            let projectedEnd = windowStart.addingTimeInterval(totalLifetimeSeconds)
            if projectedEnd < resetsAt {
                projectedExhaustion = projectedEnd
            }
        }

        let status: QuotaPaceStatus
        if abs(deficitPercent) <= 2.0 {
            status = .onPace
        } else if deficitPercent > 2.0 {
            status = .deficit(deficitPercent)
        } else {
            status = .surplus(abs(deficitPercent))
        }

        return QuotaPace(
            usedPercent: usedPercent,
            remainingPercent: remainingPercent,
            elapsedPercent: elapsedPercent,
            deficitPercent: deficitPercent,
            burnRate: burnRate,
            projectedExhaustion: projectedExhaustion,
            status: status
        )
    }

    public func paceETA(now: Date = Date(), short: Bool = false) -> String? {
        guard let p = pace(now: now) else { return nil }
        return p.etaText(resetsAt: resetsAt, now: now, short: short)
    }

    public func shouldShowAmbientETA(now: Date = Date()) -> Bool {
        guard let p = pace(now: now) else { return false }
        return p.shouldShowAmbientETA(resetsAt: resetsAt, now: now)
    }

    /// Fraction 0...1, convenient for progress bars.
    public var fraction: Double { usedPercent / 100 }

    /// Whether this window is the provider's current-session window: the
    /// "5-hour" label every session-shaped source uses, or a label carrying
    /// the word "session". Matches `SideNotchPanelView.windowDisplayTitle`,
    /// which renders these as "Current session".
    public var isSessionWindow: Bool {
        let label = label.lowercased()
        return label == "5-hour" || label.contains("session")
    }
}

/// A named group of quota windows, such as the general account allowance or a
/// model-specific allowance.
public struct QuotaGroup: Equatable, Sendable {
    public let id: String
    public let title: String
    public let windows: [QuotaWindow]

    public init(id: String, title: String, windows: [QuotaWindow]) {
        self.id = id
        self.title = title
        self.windows = windows
    }
}

/// An earned usage-limit reset returned by Codex. The app displays it and only
/// redeems it after the user explicitly confirms the action.
public struct QuotaResetCredit: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let status: String?
    public let expiresAt: Date?

    public init(id: String, title: String, status: String? = nil, expiresAt: Date? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.expiresAt = expiresAt
    }
}

/// Unit used by a provider's balance display.
public enum CreditUnit: Equatable, Sendable {
    case credits
    case dollars
}

/// Codex's current display conversion: 2,500 credits equals $100.
public enum CodexCreditConversion {
    public static let creditsPerDollar = 25.0

    public static func dollars(for credits: Double) -> Double {
        credits / creditsPerDollar
    }
}

/// Prepaid credit balance, where a provider exposes one.
public struct CreditBalance: Equatable, Sendable {
    public let balance: Double
    public let hasCredits: Bool
    public let unlimited: Bool
    public let unit: CreditUnit
    /// Dollars consumed so far this cycle, where the provider reports a
    /// used/limit pair rather than (or in addition to) a remaining
    /// `balance`. `nil` when the source only knows a remaining balance
    /// (e.g. Codex today) — views must not assume this is ever populated.
    public let usedDollars: Double?
    /// The monthly cap in dollars, paired with `usedDollars`. `nil` under
    /// the same conditions as `usedDollars`.
    public let limitDollars: Double?
    /// A USD equivalent for a balance whose native unit is credits. For Codex,
    /// this uses the configured 2,500-credits/$100 display conversion.
    public let dollarBalance: Double?

    public init(
        balance: Double,
        hasCredits: Bool,
        unlimited: Bool,
        unit: CreditUnit = .dollars,
        usedDollars: Double? = nil,
        limitDollars: Double? = nil,
        dollarBalance: Double? = nil
    ) {
        self.balance = balance
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.unit = unit
        self.usedDollars = usedDollars
        self.limitDollars = limitDollars
        self.dollarBalance = dollarBalance
    }
}

/// Live quota for one provider. Absent windows simply aren't shown.
public struct ProviderQuota: Equatable, Sendable {
    public let provider: Provider
    public let windows: [QuotaWindow]
    public let groups: [QuotaGroup]
    public let credits: CreditBalance?
    public let resetCreditCount: Int?
    public let resetCredits: [QuotaResetCredit]
    /// Plan name if the provider reports one, e.g. "plus". Never an account id.
    public let planType: String?
    public let capturedAt: Date

    public init(
        provider: Provider,
        windows: [QuotaWindow],
        groups: [QuotaGroup] = [],
        credits: CreditBalance? = nil,
        resetCreditCount: Int? = nil,
        resetCredits: [QuotaResetCredit] = [],
        planType: String? = nil,
        capturedAt: Date
    ) {
        self.provider = provider
        self.windows = windows
        self.groups = groups
        self.credits = credits
        self.resetCreditCount = resetCreditCount
        self.resetCredits = resetCredits
        self.planType = planType
        self.capturedAt = capturedAt
    }
}

public enum Provider: String, CaseIterable, Codable, Sendable {
    case codex
    case antigravity
    case grok
    case openCodeGo
    case openRouter
    case claude
    case cursor
    case copilot
    case gemini

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .grok: return "Grok"
        case .openCodeGo: return "OpenCode Go"
        case .openRouter: return "OpenRouter"
        case .claude: return "Claude"
        case .cursor: return "Cursor"
        case .copilot: return "Copilot CLI"
        case .gemini: return "Gemini CLI"
        }
    }

    /// The window the ring, tray cluster, and tooltip headline mean for this
    /// provider — declared by name, never positional and never "whichever is
    /// biggest".
    ///
    /// A positional (`windows.first`) or most-constrained (`max usedPercent`)
    /// rule lets the subject move: right after the session window resets to
    /// ~0%, the weekly window quietly slides into its place, and the ring
    /// keeps its shape while changing what it measures — at exactly the
    /// moment someone is most likely looking at it. Naming the window stops
    /// that drift: a fresh session reads 0%, which is the truth, and a
    /// genuinely absent headline yields `nil` (dash/skip) rather than
    /// promoting another window into its place.
    ///
    /// Rules per provider:
    /// - Codex: the "5-hour" current session; a lone single window (plans
    ///   that report only one allowance, e.g. `secondary == null`) is that
    ///   plan's allowance and is returned as-is.
    /// - Claude: the "5-hour" session, falling back to the bare legacy
    ///   "7-day" key for writers that never emit a session window. A
    ///   `limits[]`-shaped weekly ("Weekly · …") is never a fallback: the
    ///   upstream array transiently drops the session right after it resets,
    ///   and promoting the weekly there is the exact drift this exists to stop.
    /// - OpenCode Go: the "Rolling" current allowance.
    /// - Grok / OpenRouter: single-window providers; the lone window is the
    ///   headline. (More than one would be a new provider shape with no
    ///   declared concept, so the max is kept as a visible fallback.)
    /// - Antigravity: dynamic per-group labels with no session concept, so
    ///   the most-constrained window stays the honest "about to get cut off"
    ///   figure.
    public func headlineWindow(from windows: [QuotaWindow]) -> QuotaWindow? {
        switch self {
        case .codex:
            if let session = windows.first(where: { $0.isSessionWindow }) {
                return session
            }
            return windows.count == 1 ? windows[0] : nil
        case .claude:
            if let session = windows.first(where: { $0.isSessionWindow }) {
                return session
            }
            return windows.first(where: { $0.label == "7-day" })
        case .openCodeGo:
            return windows.first(where: { $0.label.lowercased() == "rolling" })
        case .grok, .openRouter:
            if windows.count == 1 { return windows[0] }
            return windows.max(by: { $0.usedPercent < $1.usedPercent })
        case .antigravity:
            return windows.max(by: { $0.usedPercent < $1.usedPercent })
        case .cursor, .copilot, .gemini:
            if windows.count == 1 { return windows[0] }
            return windows.first(where: { $0.isSessionWindow }) ?? windows.max(by: { $0.usedPercent < $1.usedPercent })
        }
    }

    /// The tool holding the credential these readings are borrowed from.
    /// Display-only: this app runs no sign-in flow of its own.
    public var sourceLabel: String {
        switch self {
        case .codex: return "Codex CLI"
        case .claude: return "Claude Code"
        case .antigravity: return "agy CLI"
        case .grok: return "Grok CLI"
        case .openCodeGo: return "OpenCode"
        case .openRouter: return "API key"
        case .cursor: return "Cursor"
        case .copilot: return "Copilot CLI"
        case .gemini: return "Gemini CLI"
        }
    }

    /// Public provider status page for the providers whose machine-readable
    /// feed is shown in the dashboard. Other providers remain linkless rather
    /// than sending the user to a guessed or unrelated page.
    public var statusPageURL: URL? {
        switch self {
        case .codex:
            return URL(string: "https://status.openai.com/")
        case .claude:
            return URL(string: "https://status.claude.com/")
        case .cursor:
            return URL(string: "https://status.cursor.com/")
        case .copilot:
            return URL(string: "https://www.githubstatus.com/")
        case .antigravity, .grok, .openCodeGo, .openRouter, .gemini:
            return nil
        }
    }
}

/// Top contributor to current window burn.
public struct BurnContributor: Equatable, Sendable, Identifiable {
    public var id: String { projectName + "-" + model }
    public let projectName: String
    public let model: String
    public let turns: Int
    public let tokens: TokenTotals
    public let totalTokens: Int
    public let shareOfWindow: Double
    public let isLongChat: Bool

    public init(
        projectName: String,
        model: String,
        turns: Int,
        tokens: TokenTotals,
        totalTokens: Int,
        shareOfWindow: Double,
        isLongChat: Bool
    ) {
        self.projectName = projectName
        self.model = model
        self.turns = turns
        self.tokens = tokens
        self.totalTokens = totalTokens
        self.shareOfWindow = shareOfWindow
        self.isLongChat = isLongChat
    }
}

/// Window burn breakdown and context waste hints.
public struct WindowBurnBreakdown: Equatable, Sendable {
    public let windowLabel: String
    public let contributors: [BurnContributor]
    public let totalTokens: Int
    public let cacheHitRate: Double?
    public let avgTokensPerTurn: Int?
    public let longChatCount: Int

    public init(
        windowLabel: String,
        contributors: [BurnContributor],
        totalTokens: Int,
        cacheHitRate: Double?,
        avgTokensPerTurn: Int?,
        longChatCount: Int
    ) {
        self.windowLabel = windowLabel
        self.contributors = contributors
        self.totalTokens = totalTokens
        self.cacheHitRate = cacheHitRate
        self.avgTokensPerTurn = avgTokensPerTurn
        self.longChatCount = longChatCount
    }
}

// MARK: - Local activity (computed from the user's own transcripts)

/// Token counts for a slice of local activity.
public struct TokenTotals: Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var reasoning: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(
        input: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0
    ) {
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Int { input + output + reasoning + cacheRead + cacheWrite }

    public static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            reasoning: lhs.reasoning + rhs.reasoning,
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


public struct DailyVolumePoint: Equatable, Sendable {
    public let day: Date
    public let tokens: Int
    public let sessionCount: Int

    public init(day: Date, tokens: Int = 0, sessionCount: Int = 0) {
        self.day = day
        self.tokens = max(tokens, 0)
        self.sessionCount = max(sessionCount, 0)
    }
}

public struct ProviderTelemetry: Equatable, Sendable {
    public let lifetimeTokens: Int?
    public let peakDailyTokens: Int?
    public let longestChatSeconds: TimeInterval?
    public let currentStreakDays: Int
    public let longestStreakDays: Int
    public let todayTokens: Int?
    public let last30DaysTokens: Int?
    public let totalSessions: Int?
    public let totalMessages: Int?
    public let todaySessions: Int?
    public let todayMessages: Int?
    public let dailyHistory: [DailyVolumePoint]

    public init(
        lifetimeTokens: Int? = nil,
        peakDailyTokens: Int? = nil,
        longestChatSeconds: TimeInterval? = nil,
        currentStreakDays: Int = 0,
        longestStreakDays: Int = 0,
        todayTokens: Int? = nil,
        last30DaysTokens: Int? = nil,
        totalSessions: Int? = nil,
        totalMessages: Int? = nil,
        todaySessions: Int? = nil,
        todayMessages: Int? = nil,
        dailyHistory: [DailyVolumePoint] = []
    ) {
        self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens
        self.longestChatSeconds = longestChatSeconds
        self.currentStreakDays = max(currentStreakDays, 0)
        self.longestStreakDays = max(longestStreakDays, 0)
        self.todayTokens = todayTokens
        self.last30DaysTokens = last30DaysTokens
        self.totalSessions = totalSessions
        self.totalMessages = totalMessages
        self.todaySessions = todaySessions
        self.todayMessages = todayMessages
        self.dailyHistory = dailyHistory
    }
}

/// Everything computed locally for one provider.
public struct LocalActivity: Equatable, Sendable {
    public let provider: Provider
    public let sessions: [SessionSummary]
    public let daily: [DailyActivity]
    public let scannedAt: Date
    private let customTelemetry: ProviderTelemetry?

    public init(provider: Provider, sessions: [SessionSummary], daily: [DailyActivity], scannedAt: Date, telemetry: ProviderTelemetry? = nil) {
        self.provider = provider
        self.sessions = sessions
        self.daily = daily
        self.scannedAt = scannedAt
        self.customTelemetry = telemetry
    }

    /// Computed activity telemetry from sessions and daily data.
    public var telemetry: ProviderTelemetry? {
        if let custom = customTelemetry {
            return custom
        }
        if !daily.isEmpty || !sessions.isEmpty {
            let items = sessions.map {
                TelemetrySessionItem(
                    startedAt: $0.startedAt,
                    tokens: $0.tokens.total,
                    messageCount: $0.messageCount
                )
            }
            return TelemetryCalculator.calculate(sessions: items, daily: daily, now: scannedAt)
        }
        return nil
    }

    public func burnBreakdown(for window: QuotaWindow?, now: Date = Date()) -> WindowBurnBreakdown? {
        BurnAttributionCalculator.calculate(sessions: sessions, window: window, now: now)
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

    public var totalMessages: Int {
        sessions.reduce(0) { $0 + $1.messageCount }
    }
}

/// One usage slice over a named window (e.g. "last 24h"), aggregated from the
/// same local history a source already reads. Sources without timestamps leave
/// `ProviderUsage.usageWindows` nil.
public struct UsageWindow: Equatable, Sendable {
    public let label: String
    public let sessionCount: Int
    public let messageCount: Int
    public let tokens: TokenTotals
    public let estimatedCostUSD: Double

    public init(
        label: String,
        sessionCount: Int,
        messageCount: Int,
        tokens: TokenTotals,
        estimatedCostUSD: Double
    ) {
        self.label = label
        self.sessionCount = max(sessionCount, 0)
        self.messageCount = max(messageCount, 0)
        self.tokens = tokens
        self.estimatedCostUSD = estimatedCostUSD
    }

    /// Share (0...1) of the reference 30-day cost this window represents.
    ///
    /// OpenCode exposes no quota limit, so a bar cannot mean "percent of your
    /// allowance". Instead each window's bar is its fraction of the last-30-day
    /// window — the reference — so "last 24h at 0.45" reads as "45% of this
    /// month's spend happened in the last day". The 30d window is always 1.0.
    /// A missing or zero reference yields 0, never NaN.
    public func shareOf30Days(referenceCost: Double) -> Double {
        referenceCost > 0 ? estimatedCostUSD / referenceCost : 0
    }

    /// Share (0...1) of the reference 30-day tokens this window represents.
    ///
    /// For providers without monetary spend, rolling window bars represent their
    /// fraction of the last-30-day token volume.
    public func shareOf30Days(referenceTokens: Int) -> Double {
        referenceTokens > 0 ? Double(tokens.total) / Double(referenceTokens) : 0
    }
}

/// Provider usage whose source does not necessarily expose token economics.
///
/// Grok persists sessions/messages but not billable token counts, while
/// Antigravity and OpenCode Go do expose token totals. Keeping those fields
/// optional prevents a zero from being mistaken for measured zero usage.
public struct ProviderUsage: Equatable, Sendable {
    public let provider: Provider
    public let sessionCount: Int
    public let messageCount: Int
    public let tokens: TokenTotals?
    public let estimatedCostUSD: Double?
    public let todaySessionCount: Int
    public let todayMessageCount: Int
    /// Rolling windows (e.g. "last 24h", "last 7d", "last 30d") computed from
    /// the source's own records. Nil when the source has no timestamps.
    public let usageWindows: [UsageWindow]?
    public let telemetry: ProviderTelemetry?
    public let capturedAt: Date

    public init(
        provider: Provider,
        sessionCount: Int,
        messageCount: Int,
        tokens: TokenTotals? = nil,
        estimatedCostUSD: Double? = nil,
        todaySessionCount: Int = 0,
        todayMessageCount: Int = 0,
        usageWindows: [UsageWindow]? = nil,
        telemetry: ProviderTelemetry? = nil,
        capturedAt: Date
    ) {
        self.provider = provider
        self.sessionCount = max(sessionCount, 0)
        self.messageCount = max(messageCount, 0)
        self.tokens = tokens
        self.estimatedCostUSD = estimatedCostUSD
        self.todaySessionCount = max(todaySessionCount, 0)
        self.todayMessageCount = max(todayMessageCount, 0)
        self.usageWindows = usageWindows
        self.telemetry = telemetry
        self.capturedAt = capturedAt
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
    /// A provider-specific local history/cache is not present.
    case dataNotFound(String)

    public var userFacingMessage: String {
        switch self {
        case .cliNotFound(let name):  return "\(name) CLI not found"
        case .notSignedIn(let p):     return "Not signed in to \(p.displayName)"
        case .offline:                return "Offline"
        case .failed(let p):          return "Couldn't read \(p.displayName) usage"
        case .noData:                 return "No usage yet"
        case .dataNotFound(let name): return "\(name) not found"
        }
    }
}

// MARK: - Utilities

extension Comparable {
    func muClamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
