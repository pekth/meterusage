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
    ///   - `.knownUnpriced`: a recognised model (currently: Fable) for which
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
    private static let opus = Rate(inputPerMTok: 15, outputPerMTok: 75, cacheReadPerMTok: 1.5, cacheWritePerMTok: 18.75)
    private static let sonnet = Rate(inputPerMTok: 3, outputPerMTok: 15, cacheReadPerMTok: 0.3, cacheWritePerMTok: 3.75)
    private static let haiku = Rate(inputPerMTok: 0.8, outputPerMTok: 4, cacheReadPerMTok: 0.08, cacheWritePerMTok: 1)

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

    /// Fable is real, heavily-used, and has no published per-token rate as
    /// of 2026-07 — it's neither Anthropic's own pricing page nor a model
    /// family we can substring-match to one of the table above. Matches
    /// both the dated id seen in transcripts ("claude-fable-5") and the
    /// bare alias ("fable"). If Anthropic ever publishes a rate, add a
    /// `fable` case to the table above and delete this branch — do NOT
    /// invent a number here in the meantime.
    private static func isFable(_ lowercasedModel: String) -> Bool {
        lowercasedModel.contains("fable")
    }

    private static func classify(_ model: String) -> Classification {
        let lower = model.lowercased()
        if lower.contains("opus") {
            return .priced(opus)
        }
        if lower.contains("haiku") {
            return .priced(haiku)
        }
        if lower.contains("sonnet") {
            return .priced(sonnet)
        }
        if isFable(lower) {
            return .knownUnpriced
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
    /// For a known-but-unpriced model (Fable) this still returns a `Rate`
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
    /// Design choice: a known-but-unpriced model (Fable) contributes `0` to
    /// `costUSD` here, and therefore `0` to any total computed by summing
    /// `Estimate.costUSD` (e.g. `LocalActivity.totalCostUSD`) — the shared
    /// `SessionSummary.estimatedCostUSD` type is a plain `Double`, which has
    /// no way to represent "unknown"/"N/A", so `0` is the least-wrong
    /// numeric value it can hold. That silently *reads* like "Fable is
    /// free" if you only look at the number, which is why `availability`
    /// (and `isFallback` for the unrecognised case) is returned alongside
    /// it — a caller summing costs must also check whether any session in
    /// the sum has `.knownUnpriced` availability and disclose that
    /// separately (e.g. "$12.40 + Fable usage not priced") rather than
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
