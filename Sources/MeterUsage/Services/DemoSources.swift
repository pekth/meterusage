import Foundation

// MARK: - Demo mode
//
// Demo mode swaps the *data sources* and nothing else. The real views, the real
// coordinator, the real formatters and the real colour thresholds all run
// exactly as they do in production — only the numbers they are handed are
// synthetic. That is deliberate: a screenshot taken in demo mode is a truthful
// picture of the app, just not of anybody's account.
//
// WHY THIS EXISTS: the README needs screenshots, and a maintainer's real
// popover shows actual spend, actual session counts, and an actual plan tier.
// Publishing that is a privacy leak. Demo mode lets anyone — maintainer or
// contributor — produce those screenshots, and lets a contributor exercise the
// full UI without owning either CLI or being signed in to anything.
//
// HARD RULES for everything in this file:
//   - No network. No filesystem. No environment beyond the single opt-in flag.
//   - Every value is invented. Nothing here was copied from a real account,
//     a real transcript, or a real project directory.
//   - Every project name is generic ("web-app", "api-server"). No path
//     separators, no usernames, nothing resembling a real machine.
//   - Reset timestamps are computed relative to `now`, never hardcoded, so a
//     screenshot retaken a year from today still reads sensibly.

/// The opt-in switch for demo mode.
///
/// Deliberately an environment variable rather than a preference: a preference
/// can be toggled by accident and then forgotten, and a user staring at fake
/// quota bars would have no way to tell. An env var has to be set on the launch
/// that wants it, so demo mode cannot outlive the session that asked for it.
enum DemoMode {

    /// Set this to exactly `1` to launch in demo mode.
    static let environmentKey = "METERUSAGE_DEMO"

    /// Whether demo mode is on for a given environment.
    ///
    /// The comparison is against the literal `"1"` and nothing else. "true",
    /// "yes", "0" and an empty value all mean off. A loose truthiness test here
    /// would let an unrelated variable of the same name flip the app into
    /// showing invented numbers, which is the one failure mode this feature
    /// must not have.
    static func isEnabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey] == "1"
    }
}

// MARK: - Quota

/// Synthetic Claude quota: a Max 5× plan with comfortable headroom.
///
/// The percentages are chosen to make a screenshot *legible*, not dramatic.
/// Everything near 100% would read as an emergency and would render the whole
/// colour scale in one alarming tint, so the user could not tell that the app
/// distinguishes healthy from tight at all.
struct DemoClaudeQuotaSource: QuotaSource {
    let provider: Provider = .claude

    func fetchQuota() async throws -> ProviderQuota {
        let now = Date()
        return ProviderQuota(
            provider: .claude,
            windows: [
                // Comfortable. Renders green.
                QuotaWindow(label: "5-hour", usedPercent: 34, resetsAt: now.addingTimeInterval(3.25 * 3600)),
                // Over half gone but not tight. Still green, and far enough
                // out that the absolute label shows a weekday rather than a
                // bare clock time — which is the branch worth screenshotting.
                QuotaWindow(label: "7-day", usedPercent: 61, resetsAt: now.addingTimeInterval(2.25 * 86_400))
            ],
            planType: nil,
            capturedAt: now
        )
    }
}

/// Synthetic Codex quota: a Plus plan, one amber window, and a modest credit
/// balance.
///
/// The 5-hour window sits at 82% on purpose. Without one window in the amber
/// band the popover shows a single colour everywhere and the headroom scale
/// looks broken rather than calm. 82% is tight enough to tint and low enough
/// not to read as a crisis.
struct DemoCodexQuotaSource: QuotaSource {
    let provider: Provider = .codex

    func fetchQuota() async throws -> ProviderQuota {
        let now = Date()
        return ProviderQuota(
            provider: .codex,
            windows: [
                QuotaWindow(label: "5-hour", usedPercent: 82, resetsAt: now.addingTimeInterval(1.75 * 3600)),
                QuotaWindow(label: "Weekly", usedPercent: 72, resetsAt: now.addingTimeInterval(4.5 * 86_400))
            ],
            groups: [
                QuotaGroup(
                    id: "codex",
                    title: "General usage limits",
                    windows: [
                        QuotaWindow(label: "5-hour", usedPercent: 82, resetsAt: now.addingTimeInterval(1.75 * 3600)),
                        QuotaWindow(label: "Weekly", usedPercent: 72, resetsAt: now.addingTimeInterval(4.5 * 86_400))
                    ]
                ),
                QuotaGroup(
                    id: "codex_bengalfox",
                    title: "GPT-5.3-Codex-Spark usage limits",
                    windows: [
                        QuotaWindow(label: "Weekly", usedPercent: 0, resetsAt: now.addingTimeInterval(4.5 * 86_400))
                    ]
                )
            ],
            credits: CreditBalance(
                balance: 41.60,
                hasCredits: true,
                unlimited: false,
                unit: .credits,
                dollarBalance: CodexCreditConversion.dollars(for: 41.60)
            ),
            resetCreditCount: 2,
            resetCredits: [
                QuotaResetCredit(
                    id: "demo-reset-1",
                    title: "Full reset",
                    status: "available",
                    expiresAt: now.addingTimeInterval(8 * 86_400)
                ),
                QuotaResetCredit(
                    id: "demo-reset-2",
                    title: "Full reset",
                    status: "available",
                    expiresAt: now.addingTimeInterval(9 * 86_400)
                )
            ],
            planType: "plus",
            capturedAt: now
        )
    }
}

/// Synthetic OpenRouter spend with a monthly key limit. The values are
/// deliberately modest and entirely invented, so demo mode never exposes a
/// real account balance while still exercising the dollar meter.
struct DemoOpenRouterQuotaSource: QuotaSource {
    let provider: Provider = .openRouter

    func fetchQuota() async throws -> ProviderQuota {
        let now = Date()
        return ProviderQuota(
            provider: .openRouter,
            windows: [
                QuotaWindow(label: "Monthly", usedPercent: 25.5, resetsAt: nil)
            ],
            credits: CreditBalance(
                balance: 74.50,
                hasCredits: true,
                unlimited: false,
                usedDollars: 25.50,
                limitDollars: 100.00
            ),
            capturedAt: now
        )
    }
}

/// Synthetic OpenCode Go allowance. Real values exercise three windows with
/// different headrooms — the rolling window tight (a real "I'm almost out")
/// signal) and the weekly/monthly comfortable — so a screenshot shows the
/// full headroom colour scale.
struct DemoOpenCodeGoQuotaSource: QuotaSource {
    let provider: Provider = .openCodeGo

    func fetchQuota() async throws -> ProviderQuota {
        let now = Date()
        return ProviderQuota(
            provider: .openCodeGo,
            windows: [
                QuotaWindow(label: "Rolling", usedPercent: 87, resetsAt: now.addingTimeInterval(1.9 * 3600)),
                QuotaWindow(label: "Weekly", usedPercent: 77, resetsAt: now.addingTimeInterval(26 * 3600)),
                QuotaWindow(label: "Monthly", usedPercent: 44, resetsAt: now.addingTimeInterval(22.4 * 86_400))
            ],
            planType: "go",
            capturedAt: now
        )
    }
}

// MARK: - Plan

/// Synthetic subscription tier. `.max5x` rather than `.max20x` so the badge
/// shows a mid-tier plan — the common case, and the one where the percentages
/// beside it most need the context.
struct DemoPlanSource: PlanSource {
    let provider: Provider = .claude

    func fetchPlan() async throws -> PlanTier { .max5x }
}

// MARK: - Status

/// Synthetic service health. Operational, because a demo screenshot should not
/// imply the provider is currently down.
struct DemoStatusSource: StatusSource {
    let provider: Provider

    init(provider: Provider = .codex) {
        self.provider = provider
    }

    func fetchStatus() async throws -> ServiceStatus {
        ServiceStatus(
            provider: provider,
            severity: .operational,
            description: "All systems operational",
            checkedAt: Date().addingTimeInterval(-90)
        )
    }
}

// MARK: - Supplemental usage

/// Synthetic Antigravity activity. It intentionally reports sessions/messages
/// only because that is all Antigravity's local history can prove.
struct DemoAntigravityUsageSource: UsageSource {
    let provider: Provider = .antigravity

    func fetchUsage() async throws -> ProviderUsage {
        ProviderUsage(
            provider: .antigravity,
            sessionCount: 18,
            messageCount: 246,
            todaySessionCount: 2,
            todayMessageCount: 31,
            capturedAt: Date().addingTimeInterval(-75)
        )
    }
}

/// Synthetic Grok activity, using the same count-only contract as its local
/// session summaries.
struct DemoGrokUsageSource: UsageSource {
    let provider: Provider = .grok

    func fetchUsage() async throws -> ProviderUsage {
        ProviderUsage(
            provider: .grok,
            sessionCount: 12,
            messageCount: 184,
            todaySessionCount: 1,
            todayMessageCount: 22,
            capturedAt: Date().addingTimeInterval(-65)
        )
    }
}

/// Synthetic OpenCode Go activity with measured token/cost fields, so the demo
/// exercises both count-only and token-aware usage rows.
struct DemoOpenCodeGoUsageSource: UsageSource {
    let provider: Provider = .openCodeGo

    func fetchUsage() async throws -> ProviderUsage {
        let now = Date().addingTimeInterval(-55)
        return ProviderUsage(
            provider: .openCodeGo,
            sessionCount: 26,
            messageCount: 492,
            tokens: TokenTotals(input: 1_420_000, output: 386_000, reasoning: 118_000, cacheRead: 9_840_000),
            estimatedCostUSD: 16.33,
            todaySessionCount: 3,
            todayMessageCount: 71,
            usageWindows: [
                // 30d is the reference, so 24h/7d shares render meaningful bars.
                UsageWindow(
                    label: "last 24h",
                    sessionCount: 3,
                    messageCount: 71,
                    tokens: TokenTotals(input: 260_000, output: 74_000, reasoning: 18_000, cacheRead: 1_420_000),
                    estimatedCostUSD: 2.10
                ),
                UsageWindow(
                    label: "last 7d",
                    sessionCount: 21,
                    messageCount: 390,
                    tokens: TokenTotals(input: 980_000, output: 240_000, reasoning: 74_000, cacheRead: 6_100_000),
                    estimatedCostUSD: 12.00
                ),
                UsageWindow(
                    label: "last 30d",
                    sessionCount: 26,
                    messageCount: 492,
                    tokens: TokenTotals(input: 1_420_000, output: 386_000, reasoning: 118_000, cacheRead: 9_840_000),
                    estimatedCostUSD: 16.33
                )
            ],
            capturedAt: now
        )
    }
}

// MARK: - Local activity

/// Synthetic local activity at an indie-developer scale.
///
/// Sizing is chosen so the screenshot is representative rather than
/// impressive: tens of millions of tokens across a couple of months, a cost in
/// the low hundreds. Billions of tokens and a four-figure bill would make the
/// tool look like it is for somebody else.
///
/// One detail is load-bearing for the screenshot rather than decorative:
///   - Roughly twenty of the last twenty-six weeks carry activity, at varied
///     intensity, so the heatmap renders as a heatmap. Three lonely squares
///     would show the grid without showing what it is for.
///
/// Every model in the mix (including Fable) has a published per-token rate,
/// so the total below is a straightforward priced sum — no "+" qualifier, no
/// em-dash cost cell, no footnote. Those "cost unavailable" renderings stay
/// in the app for a future model with no published rate; the demo simply
/// doesn't need to exercise them right now.
struct DemoLocalActivitySource: LocalActivitySource {
    let provider: Provider = .claude

    func scan() async throws -> LocalActivity {
        let now = Date()
        return LocalActivity(
            provider: .claude,
            sessions: DemoActivityData.sessions(now: now),
            daily: DemoActivityData.daily(now: now),
            scannedAt: now
        )
    }
}

/// The generator behind `DemoLocalActivitySource`, split out so it can be
/// exercised directly by tests without going through the async protocol.
///
/// Everything is derived from a fixed seed, so two runs on the same day produce
/// the same figures. That matters for screenshots: a retake should differ only
/// where time has genuinely moved on.
enum DemoActivityData {

    // MARK: Vocabulary

    /// Invented project names. Generic on purpose — a demo screenshot must
    /// never carry a real repository name, and these are also the strings the
    /// privacy tests assert contain no path separator.
    static let projectNames = [
        "web-app",
        "api-server",
        "notes-cli",
        "design-tokens",
        "docs-site",
        "data-pipeline"
    ]

    /// Model ids spelled the way transcripts actually spell them.
    ///
    /// The mix is intentional: a spread of families keeps the cost column
    /// from looking like one repeated number. Every family here (including
    /// Fable) has a published rate, so every session in the demo prices
    /// normally.
    private static func model(forIndex index: Int) -> String {
        switch index % 12 {
        case 0, 2, 6:  return "claude-opus-4-8"
        case 4:        return "claude-haiku-4-5"
        case 9:        return "claude-fable-5"
        default:       return "claude-sonnet-4-5"
        }
    }

    /// How a session's total tokens divide across the four kinds.
    ///
    /// Cache reads dominate real agentic sessions by an order of magnitude, and
    /// a demo that split tokens evenly would make the "in / out" caption under
    /// the total look nothing like a real one.
    static func split(total: Int) -> TokenTotals {
        TokenTotals(
            input: Int(Double(total) * 0.06),
            output: Int(Double(total) * 0.04),
            cacheRead: Int(Double(total) * 0.78),
            cacheWrite: Int(Double(total) * 0.12)
        )
    }

    // MARK: Sessions

    static let sessionCount = 58

    static func sessions(now: Date) -> [SessionSummary] {
        var rng = DemoRandom(seed: 0x5EED_1234)
        return (0..<sessionCount).map { index in
            let model = model(forIndex: index)
            let tokens = split(total: rng.int(in: 250_000...1_800_000))
            // Cost comes from the app's own pricing table rather than a
            // hardcoded figure, so the demo can never show a cost the real
            // code would not have computed from those tokens.
            let estimate = Pricing.estimate(model: model, tokens: tokens)
            // Newest first, walking backwards at a plausible working cadence.
            let hoursAgo = Double(index) * 5.5 + Double(rng.int(in: 0...3))
            return SessionSummary(
                id: Privacy.opaqueID("demo-session-\(index)"),
                projectName: projectNames[index % projectNames.count],
                model: model,
                tokens: tokens,
                estimatedCostUSD: estimate.costUSD,
                startedAt: now.addingTimeInterval(-hoursAgo * 3600),
                messageCount: rng.int(in: 12...180)
            )
        }
    }

    // MARK: Daily

    /// Weeks left deliberately empty, counted from the oldest column.
    ///
    /// A heatmap with no gaps looks generated. Real usage has holidays, weeks
    /// on another project, and weeks where nothing shipped.
    private static let quietWeeks: Set<Int> = [2, 5, 11, 16, 21, 24]

    static let heatmapWeeks = 26

    static func daily(now: Date) -> [DailyActivity] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)

        // Mirrors HeatmapView's own window arithmetic so the generated days
        // land inside the grid rather than half off the left edge.
        let weekdayIndex = calendar.component(.weekday, from: today) - 1
        let daysBack = (heatmapWeeks - 1) * 7 + weekdayIndex

        var rng = DemoRandom(seed: 0xC0FFEE_42)
        var result: [DailyActivity] = []

        for offset in stride(from: daysBack, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let week = (daysBack - offset) / 7
            guard !quietWeeks.contains(week) else { continue }

            // Roughly four to five active days a week, so weekends read as
            // lighter without being mechanically blank.
            guard rng.int(in: 0...9) < 6 else { continue }

            // Spread across the full intensity range: the heatmap buckets
            // relative to its own peak, so values clustered together would
            // render every cell the same shade.
            let magnitude = rng.int(in: 1...100)
            let total = 120_000 + magnitude * 38_000
            let tokens = split(total: total)
            result.append(DailyActivity(
                day: day,
                tokens: tokens,
                estimatedCostUSD: Pricing.estimate(model: "claude-sonnet-4-5", tokens: tokens).costUSD,
                sessionCount: rng.int(in: 1...4)
            ))
        }
        return result
    }
}

// MARK: - Determinism

/// A tiny fixed-seed generator.
///
/// `SystemRandomNumberGenerator` would make every launch produce different
/// figures, which is wrong for a screenshot source: a retake should differ only
/// because time has passed, not because the data reshuffled. This is a plain
/// LCG — it is a source of *variety*, never of anything security-relevant.
struct DemoRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    private mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 17
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }
}
