import XCTest
@testable import MeterUsageCore

final class PricingTests: XCTestCase {

    func testKnownModelFamiliesAreNotFallback() {
        for model in ["claude-opus-4-8", "opus", "claude-sonnet-5", "sonnet", "claude-haiku-4-5-20251001", "haiku"] {
            let (_, isFallback) = Pricing.rate(forModel: model)
            XCTAssertFalse(isFallback, "\(model) should resolve to a known rate family")
        }
    }

    func testUnknownModelFallsBackWithoutCrashingOrZeroingCost() {
        let tokens = TokenTotals(input: 1_000_000, output: 1_000_000, cacheRead: 0, cacheWrite: 0)
        let estimate = Pricing.estimate(model: "<synthetic>", tokens: tokens)
        XCTAssertTrue(estimate.isFallback)
        XCTAssertGreaterThan(estimate.costUSD, 0, "unknown model must not silently price as zero")
    }

    func testEstimateIsProportionalToTokens() {
        let small = Pricing.estimate(model: "claude-sonnet-5", tokens: TokenTotals(input: 1_000_000))
        let big = Pricing.estimate(model: "claude-sonnet-5", tokens: TokenTotals(input: 2_000_000))
        XCTAssertEqual(big.costUSD, small.costUSD * 2, accuracy: 0.0001)
    }

    func testOpusIsMoreExpensiveThanHaikuForIdenticalTokens() {
        let tokens = TokenTotals(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000)
        let opus = Pricing.estimate(model: "claude-opus-4-8", tokens: tokens)
        let haiku = Pricing.estimate(model: "claude-haiku-4-5-20251001", tokens: tokens)
        XCTAssertGreaterThan(opus.costUSD, haiku.costUSD)
    }

    func testZeroTokensCostsNothing() {
        let estimate = Pricing.estimate(model: "claude-sonnet-5", tokens: TokenTotals())
        XCTAssertEqual(estimate.costUSD, 0, accuracy: 0.0001)
    }

    // MARK: - Fable: known model, published rate ($10/$50 per Mtok)

    func testFableDatedIDResolvesToPriced() {
        let tokens = TokenTotals(input: 1_000_000, output: 1_000_000, cacheRead: 500_000, cacheWrite: 500_000)
        let estimate = Pricing.estimate(model: "claude-fable-5", tokens: tokens)
        XCTAssertEqual(estimate.availability, .priced)
        XCTAssertFalse(estimate.isFallback, "Fable is a recognised priced family, not an unrecognised-model guess")
        // input 10 + output 50 + cacheRead (0.5*1.0) + cacheWrite (0.5*12.5) = 66.75
        XCTAssertEqual(estimate.costUSD, 66.75, accuracy: 0.0001)
        XCTAssertEqual(Pricing.availability(forModel: "claude-fable-5"), .priced)
    }

    func testBareFableAliasResolvesToPriced() {
        let tokens = TokenTotals(input: 1_000_000, output: 1_000_000)
        let estimate = Pricing.estimate(model: "fable", tokens: tokens)
        XCTAssertEqual(estimate.availability, .priced)
        XCTAssertFalse(estimate.isFallback)
        XCTAssertEqual(estimate.costUSD, 60, accuracy: 0.0001, "1M input @ $10 + 1M output @ $50")
    }

    func testFableTokensAreCountedNormallyByCaller() {
        // Pricing itself doesn't carry tokens in its result, but the token
        // totals a caller passed in are unaffected by pricing availability —
        // verify the input we fed in round-trips through to the caller's
        // own accounting, and that cost is computed normally now that Fable
        // is a priced family.
        let tokens = TokenTotals(input: 123_456, output: 7_890, cacheRead: 111, cacheWrite: 222)
        XCTAssertEqual(tokens.total, 123_456 + 7_890 + 111 + 222)
        let estimate = Pricing.estimate(model: "claude-fable-5", tokens: tokens)
        XCTAssertGreaterThan(estimate.costUSD, 0, "Fable has a published rate — cost must not be zeroed")
    }

    func testUnrecognisedModelStillHitsExistingFallbackBehaviour() {
        let tokens = TokenTotals(input: 1_000_000, output: 1_000_000)
        let estimate = Pricing.estimate(model: "claude-mystery-9", tokens: tokens)
        XCTAssertEqual(estimate.availability, .unrecognizedFallback)
        XCTAssertTrue(estimate.isFallback)
        XCTAssertGreaterThan(estimate.costUSD, 0, "unrecognised model must still price via fallback, not zero")
    }

    func testMixedSessionsIncludeFableAsARealPricedContribution() {
        // Simulates LocalActivity.totalCostUSD summing several sessions:
        // one priced (Sonnet), one priced (Fable — now a real rate, not a
        // known-unpriced placeholder), one genuinely unrecognised
        // (fallback-priced). Fable's real cost must be included in the sum
        // like any other priced model, and only the genuinely unrecognised
        // session should be flagged as uncertain.
        let sonnetTokens = TokenTotals(input: 1_000_000, output: 1_000_000)
        let fableTokens = TokenTotals(input: 1_000_000, output: 1_000_000)
        let mysteryTokens = TokenTotals(input: 1_000_000, output: 1_000_000)

        let sonnet = Pricing.estimate(model: "claude-sonnet-5", tokens: sonnetTokens)
        let fable = Pricing.estimate(model: "claude-fable-5", tokens: fableTokens)
        let mystery = Pricing.estimate(model: "claude-mystery-9", tokens: mysteryTokens)

        let estimates = [sonnet, fable, mystery]
        let total = estimates.reduce(0) { $0 + $1.costUSD }

        // Fable's real cost is now part of the total — no session silently
        // drops out of the sum anymore.
        XCTAssertEqual(total, sonnet.costUSD + fable.costUSD + mystery.costUSD, accuracy: 0.0001)
        XCTAssertGreaterThan(fable.costUSD, 0, "Fable must contribute a real, nonzero cost")
        XCTAssertFalse(estimates.contains { $0.availability == .knownUnpriced }, "nothing in this mix is known-unpriced anymore")
        let fallbackCount = estimates.filter { $0.availability == .unrecognizedFallback }.count
        XCTAssertEqual(fallbackCount, 1, "exactly the mystery session must be flagged as an unrecognised-model guess")
    }

    // MARK: - Exact rates, pinned per tier
    //
    // The stale-rate bug (Opus at the Claude 3 Opus era $15/$75, Haiku at
    // $0.8/$4) existed for a long time undetected because nothing here
    // pinned the actual numbers — only relative ordering ("Opus costs more
    // than Haiku"), which stays true even while every absolute rate is
    // wrong. These assert the exact computed dollar figure for a known
    // token count, so a future stale-rate edit fails loudly instead of
    // silently passing a same-shaped test.

    func testExactCostForFableTier() {
        // input $10/Mtok, output $50/Mtok.
        let tokens = TokenTotals(input: 2_000_000, output: 500_000)
        let estimate = Pricing.estimate(model: "claude-fable-5", tokens: tokens)
        XCTAssertEqual(estimate.costUSD, 2 * 10 + 0.5 * 50, accuracy: 0.0001) // 45.0
    }

    func testExactCostForOpusTier() {
        // input $5/Mtok, output $25/Mtok.
        let tokens = TokenTotals(input: 2_000_000, output: 500_000)
        let estimate = Pricing.estimate(model: "claude-opus-4-8", tokens: tokens)
        XCTAssertEqual(estimate.costUSD, 2 * 5 + 0.5 * 25, accuracy: 0.0001) // 22.5
    }

    func testExactCostForSonnetTier() {
        // input $3/Mtok, output $15/Mtok.
        let tokens = TokenTotals(input: 2_000_000, output: 500_000)
        let estimate = Pricing.estimate(model: "claude-sonnet-5", tokens: tokens)
        XCTAssertEqual(estimate.costUSD, 2 * 3 + 0.5 * 15, accuracy: 0.0001) // 13.5
    }

    func testExactCostForHaikuTier() {
        // input $1/Mtok, output $5/Mtok.
        let tokens = TokenTotals(input: 2_000_000, output: 500_000)
        let estimate = Pricing.estimate(model: "claude-haiku-4-5", tokens: tokens)
        XCTAssertEqual(estimate.costUSD, 2 * 1 + 0.5 * 5, accuracy: 0.0001) // 4.5
    }

    /// Cache rates are derived from documented multipliers rather than a
    /// published per-model table: read = 0.1x input, write = 1.25x input
    /// (default 5-minute TTL). Pin the relationship for one tier (Sonnet)
    /// so a future edit that changes the multiplier — or that hardcodes a
    /// wrong absolute cache rate — fails loudly.
    func testCacheRatesAreDerivedFromInputMultiplierForSonnet() {
        let (rate, _) = Pricing.rate(forModel: "claude-sonnet-5")
        XCTAssertEqual(rate.cacheReadPerMTok, rate.inputPerMTok * 0.1, accuracy: 0.0001)
        XCTAssertEqual(rate.cacheWritePerMTok, rate.inputPerMTok * 1.25, accuracy: 0.0001)
        // And pinned to the exact published input rate, so this test can't
        // pass by drifting alongside a stale input number too.
        XCTAssertEqual(rate.inputPerMTok, 3, accuracy: 0.0001)
        XCTAssertEqual(rate.cacheReadPerMTok, 0.3, accuracy: 0.0001)
        XCTAssertEqual(rate.cacheWritePerMTok, 3.75, accuracy: 0.0001)
    }
}
