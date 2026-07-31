import XCTest
@testable import MeterUsage

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

    // MARK: - Fable: known model, no published rate

    func testFableDatedIDResolvesToKnownUnpriced() {
        let tokens = TokenTotals(input: 1_000_000, output: 1_000_000, cacheRead: 500_000, cacheWrite: 500_000)
        let estimate = Pricing.estimate(model: "claude-fable-5", tokens: tokens)
        XCTAssertEqual(estimate.availability, .knownUnpriced)
        XCTAssertFalse(estimate.isFallback, "Fable is recognised, not an unrecognised-model guess")
        XCTAssertEqual(estimate.costUSD, 0, accuracy: 0.0001, "no published rate — must not fabricate a cost")
        XCTAssertEqual(Pricing.availability(forModel: "claude-fable-5"), .knownUnpriced)
    }

    func testBareFableAliasResolvesToKnownUnpriced() {
        let tokens = TokenTotals(input: 42, output: 7)
        let estimate = Pricing.estimate(model: "fable", tokens: tokens)
        XCTAssertEqual(estimate.availability, .knownUnpriced)
        XCTAssertFalse(estimate.isFallback)
        XCTAssertEqual(estimate.costUSD, 0, accuracy: 0.0001)
    }

    func testFableTokensAreStillCountedByCaller() {
        // Pricing itself doesn't carry tokens in its result, but the token
        // totals a caller passed in are unaffected by pricing availability —
        // verify the input we fed in round-trips through to the caller's
        // own accounting rather than being dropped because cost is unknown.
        let tokens = TokenTotals(input: 123_456, output: 7_890, cacheRead: 111, cacheWrite: 222)
        XCTAssertEqual(tokens.total, 123_456 + 7_890 + 111 + 222)
        let estimate = Pricing.estimate(model: "claude-fable-5", tokens: tokens)
        XCTAssertEqual(estimate.costUSD, 0, accuracy: 0.0001)
    }

    func testUnrecognisedModelStillHitsExistingFallbackBehaviour() {
        let tokens = TokenTotals(input: 1_000_000, output: 1_000_000)
        let estimate = Pricing.estimate(model: "claude-mystery-9", tokens: tokens)
        XCTAssertEqual(estimate.availability, .unrecognizedFallback)
        XCTAssertTrue(estimate.isFallback)
        XCTAssertGreaterThan(estimate.costUSD, 0, "unrecognised model must still price via fallback, not zero")
    }

    func testMixedSessionsDoNotSilentlyAbsorbFableAsZero() {
        // Simulates LocalActivity.totalCostUSD summing several sessions:
        // one priced (Sonnet), one Fable (known, unpriced), one genuinely
        // unrecognised (fallback-priced). The raw dollar total must not
        // read as "everything accounted for" — a caller has to check
        // availability per session to know part of the total is missing.
        let sonnetTokens = TokenTotals(input: 1_000_000, output: 1_000_000)
        let fableTokens = TokenTotals(input: 1_000_000, output: 1_000_000)
        let mysteryTokens = TokenTotals(input: 1_000_000, output: 1_000_000)

        let sonnet = Pricing.estimate(model: "claude-sonnet-5", tokens: sonnetTokens)
        let fable = Pricing.estimate(model: "claude-fable-5", tokens: fableTokens)
        let mystery = Pricing.estimate(model: "claude-mystery-9", tokens: mysteryTokens)

        let estimates = [sonnet, fable, mystery]
        let total = estimates.reduce(0) { $0 + $1.costUSD }

        // The total silently omits Fable's real (unknown) cost — that's the
        // expected numeric behaviour given `estimatedCostUSD: Double` can't
        // represent "N/A" — but it must remain *detectable*: at least one
        // estimate in the set has to be flagged so a caller summing blindly
        // can't claim the total is complete.
        XCTAssertEqual(total, sonnet.costUSD + mystery.costUSD, accuracy: 0.0001)
        XCTAssertTrue(estimates.contains { $0.availability == .knownUnpriced })
        let unpricedCount = estimates.filter { $0.availability == .knownUnpriced }.count
        XCTAssertEqual(unpricedCount, 1, "exactly the Fable session must be flagged as cost-unavailable")
    }
}
