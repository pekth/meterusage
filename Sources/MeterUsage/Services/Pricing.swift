import Foundation

// MARK: - Pricing
//
// A single, clearly-marked table of per-model USD rates used to *estimate*
// cost from local token counts. This is NOT billing data — the provider's
// invoice is the source of truth. Treat every number here as a rough
// estimate for the user's own awareness, never as something to reconcile
// against a bill.
//
// Rates change over time and new model names appear constantly (including
// short aliases like "opus"/"sonnet"/"haiku", OpenAI ids like
// "gpt-6.1-sol", and forward-looking names we can't enumerate in advance).
// Update the tables below when a provider publishes new rates:
// Claude: https://www.anthropic.com/pricing
// OpenAI: https://developers.openai.com/api/docs/pricing
// Codex:  https://developers.openai.com/codex/pricing
public enum Pricing {

    /// Month the rate table below was last verified against the provider's
    /// published prices, as "YYYY-MM". Machine-readable on purpose: views show
    /// it beside estimated costs so a stale table is visible instead of silent,
    /// and bumping the table without bumping this date is a review-visible
    /// inconsistency rather than an invisible drift.
    public static let snapshotYearMonth = "2026-09"

    /// Human rendering of `snapshotYearMonth` for captions, e.g. "Sep 2026".
    /// Falls back to the raw value if parsing ever fails, so the label can
    /// never come out empty.
    public static var snapshotLabel: String {
        let parts = snapshotYearMonth.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]),
              let month = Int(parts[1]), (1...12).contains(month) else {
            return snapshotYearMonth
        }
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(names[month - 1]) \(year)"
    }

    /// USD per million tokens, by token kind, for one model family.
    public struct Rate: Equatable, Sendable {
        public let inputPerMTok: Double
        public let outputPerMTok: Double
        public let cacheReadPerMTok: Double
        public let cacheWritePerMTok: Double

        public init(inputPerMTok: Double, outputPerMTok: Double, cacheReadPerMTok: Double, cacheWritePerMTok: Double) {
            self.inputPerMTok = inputPerMTok
            self.outputPerMTok = outputPerMTok
            self.cacheReadPerMTok = cacheReadPerMTok
            self.cacheWritePerMTok = cacheWritePerMTok
        }
    }

    /// How confidently `Estimate.costUSD` should be trusted.
    ///
    /// Three distinct states, deliberately kept apart:
    ///   - `.priced`: a recognised model family with a published rate. Cost
    ///     is real.
    ///   - `.knownUnpriced`: a recognised model for which
    ///     we do not have a reliable published per-token rate. Tokens are
    ///     still counted correctly; cost is deliberately NOT estimated,
    ///     because a fabricated rate would be worse than an absent one.
    ///   - `.unrecognizedFallback`: a model string we don't recognise at
    ///     all. A provider-appropriate rate is used as a rough guess — the
    ///     Sonnet tier for Claude ids, the current Codex default (GPT-6.1
    ///     Sol) for OpenAI/Codex ids — flagged so the UI can mark it uncertain.
    public enum CostAvailability: Equatable, Sendable {
        case priced
        case knownUnpriced
        case unrecognizedFallback
    }

    /// Result of a cost estimate, flagging whether the model was recognised.
    public struct Estimate: Equatable, Sendable {
        public let costUSD: Double
        /// `true` when the model string didn't match a known priced family
        /// and a provider fallback rate was used instead. `false` for both
        /// `.priced` and `.knownUnpriced` models — a known-but-unpriced
        /// model (Fable) is not "using the fallback", it deliberately has no
        /// rate applied. Callers can use this to mark the number as
        /// extra-uncertain in the UI. Kept alongside `availability` for
        /// source compatibility; prefer `availability` for new code since it
        /// distinguishes "unrecognised, guessed" from "recognised, no rate".
        public let isFallback: Bool
        /// Full detail on why `costUSD` is what it is. See `CostAvailability`.
        public let availability: CostAvailability

        public init(costUSD: Double, isFallback: Bool, availability: CostAvailability) {
            self.costUSD = costUSD
            self.isFallback = isFallback
            self.availability = availability
        }
    }

    // Snapshot as of 2026-09, list prices, USD per million tokens.
    // Keep this table in ONE place — nothing else in the app should hardcode
    // a rate. Prices as published at https://www.anthropic.com/pricing;
    // re-check that page when adding a new model family below.
    // Input and output are published list prices for the current generation
    // (Opus 5.5, Sonnet 5.5). Cache rates are DERIVED from the documented
    // multipliers rather than a published per-model table: a cache read costs
    // 0.1x the input rate, and a cache write costs 1.25x (the default 5-minute
    // TTL). The 1-hour TTL writes at 2x instead; we assume 5-minute because
    // that is the default and by far the common case, which means heavy 1h-TTL
    // use is under-counted here.
    //
    // One rate covers a whole family, so an older generation is estimated at
    // the current generation's price (an Opus 4.x session prices at Opus 5.5
    // rates, a Sonnet 4.x session at Sonnet 5.5 rates). Version-specific rates
    // would need a per-version split the app does not model.
    private static let fable = Rate(inputPerMTok: 10, outputPerMTok: 50, cacheReadPerMTok: 1.00, cacheWritePerMTok: 12.50)
    private static let opus = Rate(inputPerMTok: 4, outputPerMTok: 20, cacheReadPerMTok: 0.40, cacheWritePerMTok: 5.00)
    private static let sonnet = Rate(inputPerMTok: 2, outputPerMTok: 10, cacheReadPerMTok: 0.20, cacheWritePerMTok: 2.50)
    private static let haiku = Rate(inputPerMTok: 1, outputPerMTok: 5, cacheReadPerMTok: 0.10, cacheWritePerMTok: 1.25)

    // OpenAI / Codex list prices (Standard, short context), USD per million
    // tokens, verified 2026-09 against:
    //   https://developers.openai.com/api/docs/pricing
    //   https://developers.openai.com/codex/pricing
    //
    // Two things differ from the Claude table above. First, OpenAI publishes
    // an explicit cached-input rate per model instead of a single multiplier:
    // GPT-6.1 Sol prices cached input at 5% of input ($0.10), the "new" cache
    // schedule, while GPT-6 Sol still uses the older 10% ($0.20). Second,
    // Codex credit billing has NO separate cache-write charge, so
    // `cacheWritePerMTok` is 0 for every row here. (The raw OpenAI API does
    // bill cache writes at 1.25x, but this app estimates Codex usage, so the
    // Codex basis is the honest one.)
    private static let gpt6Astra = Rate(inputPerMTok: 10, outputPerMTok: 50, cacheReadPerMTok: 1.00, cacheWritePerMTok: 0)
    private static let gpt61Sol = Rate(inputPerMTok: 2, outputPerMTok: 10, cacheReadPerMTok: 0.10, cacheWritePerMTok: 0)
    private static let gpt6Sol = Rate(inputPerMTok: 2, outputPerMTok: 10, cacheReadPerMTok: 0.20, cacheWritePerMTok: 0)
    private static let gpt6Luna = Rate(inputPerMTok: 0.10, outputPerMTok: 0.50, cacheReadPerMTok: 0.01, cacheWritePerMTok: 0)
    private static let gpt56Sol = Rate(inputPerMTok: 4, outputPerMTok: 20, cacheReadPerMTok: 0.40, cacheWritePerMTok: 0)
    private static let gpt56Terra = Rate(inputPerMTok: 2, outputPerMTok: 12, cacheReadPerMTok: 0.20, cacheWritePerMTok: 0)
    private static let gpt56Luna = Rate(inputPerMTok: 0.20, outputPerMTok: 1.20, cacheReadPerMTok: 0.02, cacheWritePerMTok: 0)
    private static let gpt53Codex = Rate(inputPerMTok: 1.75, outputPerMTok: 14, cacheReadPerMTok: 0.175, cacheWritePerMTok: 0)

    /// Rate used when a model string is unrecognised. Sonnet is the
    /// middle-of-the-road Claude family, so this under/over-estimates less
    /// badly than defaulting to either extreme. Callers must still surface
    /// `Estimate.isFallback` rather than silently trusting the number.
    private static let fallback = sonnet

    /// Internal classification, shared by `rate(forModel:)`, `availability(forModel:)`,
    /// and `estimate(model:tokens:)` so the three never drift out of sync.
    private enum Classification {
        case priced(Rate)
        /// Recognised model, no published rate. See `CostAvailability.knownUnpriced`.
        case knownUnpriced
        case unrecognizedFallback(Rate)
    }

    private static func classify(_ model: String) -> Classification {
        let lower = model.lowercased()
        if let openAI = classifyOpenAI(lower) {
            return openAI
        }
        // Fable is checked first: it is its own price tier, and matching it
        // before the family names avoids a future id like "claude-fable-opus"
        // silently falling through to the cheaper Opus rate.
        if lower.contains("fable") {
            return .priced(fable)
        }
        if lower.contains("opus") {
            return .priced(opus)
        }
        if lower.contains("haiku") {
            return .priced(haiku)
        }
        if lower.contains("sonnet") {
            return .priced(sonnet)
        }
        return .unrecognizedFallback(fallback)
    }

    /// OpenAI/Codex ids. Returns nil for anything that is not an OpenAI id, so
    /// the caller falls through to the Claude families (no Claude id contains
    /// "gpt", so the two never collide).
    ///
    /// Order matters: the `5.6-*` checks run before the bare `6-*` ones,
    /// because "gpt-5.6-sol" *does* contain the substring "6-sol" and would
    /// otherwise borrow the GPT-6 Sol rate. Each check pairs a version with a
    /// family token so a bump like "gpt-6.1-sol" can never match "gpt-6-sol".
    private static func classifyOpenAI(_ lower: String) -> Classification? {
        guard lower.contains("gpt") || lower.contains("codex") else { return nil }
        if lower.contains("6.1-sol") { return .priced(gpt61Sol) }
        if lower.contains("6-astra") { return .priced(gpt6Astra) }
        if lower.contains("5.6-sol") { return .priced(gpt56Sol) }
        if lower.contains("5.6-terra") { return .priced(gpt56Terra) }
        if lower.contains("5.6-luna") { return .priced(gpt56Luna) }
        if lower.contains("6-luna") { return .priced(gpt6Luna) }
        if lower.contains("6-sol") { return .priced(gpt6Sol) }
        if lower.contains("5.3-codex") { return .priced(gpt53Codex) }
        // A bare "codex" (or an unrecognised Codex id) carries no per-model
        // rate in the rollout; flag it and estimate at the current default
        // Sol 6.1 tier rather than silently pricing at zero.
        return .unrecognizedFallback(gpt61Sol)
    }

    /// Looks up a rate by matching well-known family substrings, so this
    /// tolerates the many spellings actually seen in transcripts: full
    /// dated ids ("claude-opus-4-8"), short aliases ("opus", "sonnet"),
    /// and synthetic/internal markers ("<synthetic>", "claude-fable-5").
    /// Falls back to Sonnet-tier pricing (flagged) rather than crashing or
    /// silently reporting zero cost for a model we don't recognise.
    ///
    /// For a known-but-unpriced model this still returns a `Rate`
    /// value for source compatibility, but `isFallback` is `false` — Fable
    /// is not "guessed via fallback", it deliberately has no rate applied.
    /// The returned `Rate` in that case is never used to compute cost; use
    /// `availability(forModel:)` or `estimate(model:tokens:)` if you need to
    /// know whether the rate is actually meaningful.
    public static func rate(forModel model: String) -> (rate: Rate, isFallback: Bool) {
        switch classify(model) {
        case .priced(let rate):
            return (rate, false)
        case .knownUnpriced:
            return (fallback, false)
        case .unrecognizedFallback(let rate):
            return (rate, true)
        }
    }

    /// Reports why a model's cost can or can't be trusted, without
    /// computing anything. See `CostAvailability`.
    public static func availability(forModel model: String) -> CostAvailability {
        switch classify(model) {
        case .priced: return .priced
        case .knownUnpriced: return .knownUnpriced
        case .unrecognizedFallback: return .unrecognizedFallback
        }
    }

    /// Estimates USD cost for a set of token counts against a model string.
    ///
    /// Design choice: a known-but-unpriced model contributes `0` to
    /// `costUSD` here, and therefore `0` to any total computed by summing
    /// `Estimate.costUSD` (e.g. `LocalActivity.totalCostUSD`) — the shared
    /// `SessionSummary.estimatedCostUSD` type is a plain `Double`, which has
    /// no way to represent "unknown"/"N/A", so `0` is the least-wrong
    /// numeric value it can hold. That silently *reads* like "the model is
    /// free" if you only look at the number, which is why `availability`
    /// (and `isFallback` for the unrecognised case) is returned alongside
    /// it — a caller summing costs must also check whether any session in
    /// the sum has `.knownUnpriced` availability and disclose that
    /// separately (e.g. "$12.40 + unpriced usage") rather than
    /// presenting the total as complete.
    public static func estimate(model: String, tokens: TokenTotals) -> Estimate {
        switch classify(model) {
        case .priced(let rate):
            return Estimate(costUSD: cost(tokens: tokens, rate: rate), isFallback: false, availability: .priced)
        case .knownUnpriced:
            return Estimate(costUSD: 0, isFallback: false, availability: .knownUnpriced)
        case .unrecognizedFallback(let rate):
            return Estimate(costUSD: cost(tokens: tokens, rate: rate), isFallback: true, availability: .unrecognizedFallback)
        }
    }

    /// Reasoning tokens are billed at the model's output rate by both
    /// providers (OpenAI counts them inside output, and Codex reports them in
    /// their own bucket), so they are charged here at `outputPerMTok` even
    /// though `TokenTotals` keeps them in a separate field. Codex/OpenAI rows
    /// carry a `cacheWritePerMTok` of 0, so their cache writes contribute
    /// nothing.
    private static func cost(tokens: TokenTotals, rate: Rate) -> Double {
        Double(tokens.input) / 1_000_000 * rate.inputPerMTok
            + Double(tokens.output) / 1_000_000 * rate.outputPerMTok
            + Double(tokens.reasoning) / 1_000_000 * rate.outputPerMTok
            + Double(tokens.cacheRead) / 1_000_000 * rate.cacheReadPerMTok
            + Double(tokens.cacheWrite) / 1_000_000 * rate.cacheWritePerMTok
    }
}
