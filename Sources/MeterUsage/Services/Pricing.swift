import Foundation

// MARK: - Pricing
//
// A single, clearly-marked table of per-model USD rates used to *estimate*
// cost from local token counts. This is NOT billing data — Anthropic's
// invoice is the source of truth. Treat every number here as a rough
// estimate for the user's own awareness, never as something to reconcile
// against a bill.
//
// Rates change over time and new model names appear constantly (including
// short aliases like "opus"/"sonnet"/"haiku" and forward-looking names we
// can't enumerate in advance). Update `Pricing.table` when Anthropic
// publishes new rates: https://www.anthropic.com/pricing
public enum Pricing {

    /// Month the rate table below was last verified against the provider's
    /// published prices, as "YYYY-MM". Machine-readable on purpose: views show
    /// it beside estimated costs so a stale table is visible instead of silent,
    /// and bumping the table without bumping this date is a review-visible
    /// inconsistency rather than an invisible drift.
    public static let snapshotYearMonth = "2026-07"

    /// Human rendering of `snapshotYearMonth` for captions, e.g. "Jul 2026".
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
    ///     all. Existing behaviour: Sonnet-tier rate used as a rough guess,
    ///     flagged so the UI can mark it uncertain.
    public enum CostAvailability: Equatable, Sendable {
        case priced
        case knownUnpriced
        case unrecognizedFallback
    }

    /// Result of a cost estimate, flagging whether the model was recognised.
    public struct Estimate: Equatable, Sendable {
        public let costUSD: Double
        /// `true` when the model string didn't match a known priced family
        /// and the Sonnet-tier fallback rate was used instead. `false` for
        /// both `.priced` and `.knownUnpriced` models — a known-but-unpriced
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

    // Snapshot as of 2026-07, list prices, USD per million tokens.
    // Keep this table in ONE place — nothing else in the app should hardcode
    // a rate. Prices as published at https://www.anthropic.com/pricing;
    // re-check that page when adding a new model family below.
    // Input and output are published list prices. Cache rates are DERIVED from
    // the documented multipliers rather than a published per-model table:
    // a cache read costs 0.1x the input rate, and a cache write costs 1.25x
    // (the default 5-minute TTL). The 1-hour TTL writes at 2x instead; we
    // assume 5-minute because that is the default and by far the common case,
    // which means heavy 1h-TTL use is under-counted here.
    private static let fable = Rate(inputPerMTok: 10, outputPerMTok: 50, cacheReadPerMTok: 1.0, cacheWritePerMTok: 12.50)
    private static let opus = Rate(inputPerMTok: 5, outputPerMTok: 25, cacheReadPerMTok: 0.5, cacheWritePerMTok: 6.25)
    private static let sonnet = Rate(inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.3, cacheWritePerMTok: 3.75)
    private static let haiku = Rate(inputPerMTok: 1, outputPerMTok: 5, cacheReadPerMTok: 0.1, cacheWritePerMTok: 1.25)

    /// Rate used when a model string is unrecognised. Sonnet is the
    /// middle-of-the-road family, so this under/over-estimates less badly
    /// than defaulting to either extreme. Callers must still surface
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

    private static func cost(tokens: TokenTotals, rate: Rate) -> Double {
        Double(tokens.input) / 1_000_000 * rate.inputPerMTok
            + Double(tokens.output) / 1_000_000 * rate.outputPerMTok
            + Double(tokens.cacheRead) / 1_000_000 * rate.cacheReadPerMTok
            + Double(tokens.cacheWrite) / 1_000_000 * rate.cacheWritePerMTok
    }
}
