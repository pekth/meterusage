import XCTest
@testable import MeterUsageCore

/// Fake `JSONRPCClient` that hands back canned bytes instead of spawning
/// `codex app-server`. Every test in this file runs offline and needs no
/// `codex` binary on the machine — that's the whole point of the injectable
/// client in JSONRPCClient.swift.
private final class FakeJSONRPCClient: JSONRPCClient {
    enum Outcome {
        case success(Data)
        case transportError(JSONRPCTransportError)
    }

    private let outcome: Outcome

    init(_ outcome: Outcome) { self.outcome = outcome }

    static func json(_ string: String) -> FakeJSONRPCClient {
        FakeJSONRPCClient(.success(Data(string.utf8)))
    }

    func requestCodexRateLimits() async throws -> Data {
        switch outcome {
        case .success(let data): return data
        case .transportError(let error): throw error
        }
    }

    func consumeCodexRateLimitReset(creditID: String) async throws -> Data {
        switch outcome {
        case .success(let data): return data
        case .transportError(let error): throw error
        }
    }
}

final class CodexQuotaSourceTests: XCTestCase {

    func testRemainingPercent_liveNinetyTwoPercentUsedShowsEightPercentLeft() {
        XCTAssertEqual(Fmt.remainingPercent(92), "8% left")
    }

    // MARK: - Fixtures

    private func loadFixture() throws -> Data {
        guard let url = Bundle.module.url(forResource: "codex_ratelimits", withExtension: "json", subdirectory: "Fixtures") else {
            XCTFail("missing codex_ratelimits.json fixture")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Window labelling (the pinned regression)

    func testFixture_labelsWindowsByDuration_primaryIsWeekly() async throws {
        let data = try loadFixture()
        let source = CodexQuotaSource(client: FakeJSONRPCClient(.success(data)))

        let quota = try await source.fetchQuota()

        // Fixture mirrors the REAL API shape confirmed 2026-07-31: primary =
        // 10080 min (7 days) -> Weekly, secondary is `null` (not present at
        // all on this account/plan) -> exactly one window.
        XCTAssertEqual(quota.windows.count, 1)
        let weekly = try XCTUnwrap(quota.windows.first { $0.label == "Weekly" })
        XCTAssertEqual(weekly.usedPercent, 42.0)
    }

    func testNullSecondary_yieldsExactlyOneWindow() async throws {
        // Pins the real shape: `secondary` arrives as JSON `null`, not an
        // absent key and not an object. `RateLimitWindow?` must decode that
        // as nil rather than throwing, and buildQuota must not synthesize a
        // phantom second window for it.
        let json = """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{
            "primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":null},
            "secondary":null,
            "planType":"plus"
        }}}
        """
        let source = CodexQuotaSource(client: FakeJSONRPCClient.json(json))

        let quota = try await source.fetchQuota()

        XCTAssertEqual(quota.windows.count, 1)
        XCTAssertEqual(quota.windows.first?.label, "5-hour")
    }

    func testUnknownExtraKeys_areIgnored_decodeSucceeds() async throws {
        // The real payload carries limitName, individualLimit,
        // spendControlReached, rateLimitReachedType — only the fields needed
        // for the display are modeled. Decodable drops the rest by default;
        // pin that so a future field addition cannot silently start throwing.
        let json = """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{
            "limitId":"synthetic-id",
            "limitName":null,
            "primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":null},
            "secondary":null,
            "individualLimit":null,
            "spendControlReached":false,
            "planType":"plus",
            "rateLimitReachedType":null
        }}}
        """
        let source = CodexQuotaSource(client: FakeJSONRPCClient.json(json))

        let quota = try await source.fetchQuota()

        XCTAssertEqual(quota.windows.count, 1)
        XCTAssertEqual(quota.planType, "plus")
    }

    func testExperimentalDetails_parseModelSpecificWindowAndResetCredits() async throws {
        // `experimentalApi` adds these fields to the authenticated app-server
        // response. They are the data shown by the Codex account screen below
        // the general weekly allowance.
        let json = """
        {"jsonrpc":"2.0","id":2,"result":{
            "rateLimits":{
                "limitId":"codex",
                "primary":{"usedPercent":32,"windowDurationMins":10080,"resetsAt":1893456000},
                "secondary":null,
                "credits":{"hasCredits":true,"unlimited":false,"balance":"1843.3106385000"},
                "planType":"prolite"
            },
            "rateLimitsByLimitId":{
                "codex":{
                    "limitId":"codex",
                    "primary":{"usedPercent":32,"windowDurationMins":10080,"resetsAt":1893456000},
                    "secondary":null
                },
                "codex_bengalfox":{
                    "limitId":"codex_bengalfox",
                    "limitName":"GPT-5.3-Codex-Spark",
                    "primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1893456000},
                    "secondary":null
                }
            },
            "rateLimitResetCredits":{
                "availableCount":2,
                "credits":[
                    {"id":"reset-1","resetType":"codexRateLimits","status":"available","expiresAt":1893456000,"title":"Full reset"},
                    {"id":"reset-2","resetType":"codexRateLimits","status":"available","expiresAt":1893459600,"title":"Full reset"}
                ]
            }
        }}
        """
        let source = CodexQuotaSource(client: FakeJSONRPCClient.json(json))

        let quota = try await source.fetchQuota()

        XCTAssertEqual(quota.groups.map(\.title), [
            "General usage limits",
            "GPT-5.3-Codex-Spark"
        ])
        XCTAssertEqual(quota.groups[1].windows.first?.usedPercent, 0)
        XCTAssertEqual(quota.resetCreditCount, 2)
        XCTAssertEqual(quota.resetCredits.count, 2)
        XCTAssertEqual(quota.resetCredits.first?.title, "Full reset")
        XCTAssertEqual(quota.resetCredits.first?.status, "available")
        XCTAssertEqual(quota.credits?.unit, .credits)
    }

    func testConsumeReset_parsesSuccessfulOutcome() async throws {
        let json = """
        {"jsonrpc":"2.0","id":2,"result":{"outcome":"reset"}}
        """
        let source = CodexQuotaSource(client: FakeJSONRPCClient.json(json))

        let didReset = try await source.consumeReset(creditID: "reset-1")
        XCTAssertTrue(didReset)
    }

    func testConsumeReset_nonResetOutcomeIsFalse() async throws {
        let json = """
        {"jsonrpc":"2.0","id":2,"result":{"outcome":"alreadyRedeemed"}}
        """
        let source = CodexQuotaSource(client: FakeJSONRPCClient.json(json))

        let didReset = try await source.consumeReset(creditID: "reset-1")
        XCTAssertFalse(didReset)
    }

    func testFlippedOrdering_labelsByDuration_notByPosition() async throws {
        // Same data as the fixture but with primary/secondary swapped. If
        // classification ever regresses to "primary == 5-hour" (the bug this
        // rule was written to prevent), this test flips to catch it: here
        // primary is the SHORT window and secondary is the WEEKLY one.
        let json = """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{
            "primary":{"usedPercent":12.0,"windowDurationMins":300,"resetsAt":1893456000},
            "secondary":{"usedPercent":42.5,"windowDurationMins":10080,"resetsAt":1893456000},
            "planType":"plus"
        }}}
        """
        let source = CodexQuotaSource(client: FakeJSONRPCClient.json(json))

        let quota = try await source.fetchQuota()

        let weekly = try XCTUnwrap(quota.windows.first { $0.label == "Weekly" })
        let short = try XCTUnwrap(quota.windows.first { $0.label == "5-hour" })
        XCTAssertEqual(weekly.usedPercent, 42.5, "the long-duration window must be Weekly regardless of which slot it's in")
        XCTAssertEqual(short.usedPercent, 12.0, "the short-duration window must be 5-hour regardless of which slot it's in")
    }

    func testDurationExactlyOneDay_isWeekly() async throws {
        // Boundary check on the >= 1440 cutoff.
        let json = """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{
            "primary":{"usedPercent":5.0,"windowDurationMins":1440,"resetsAt":null}
        }}}
        """
        let source = CodexQuotaSource(client: FakeJSONRPCClient.json(json))

        let quota = try await source.fetchQuota()

        XCTAssertEqual(quota.windows.first?.label, "Weekly")
    }

    // MARK: - Credits

    func testCreditDisplayConversion_matchesCodexRate() {
        XCTAssertEqual(CodexCreditConversion.dollars(for: 2_500), 100, accuracy: 0.0001)
        XCTAssertEqual(CodexCreditConversion.dollars(for: 1_843.3106385), 73.73242554, accuracy: 0.0001)
    }

    func testCreditsParsed_stringBalance() async throws {
        // This is the actual live bug: the real API sends `balance` as a
        // JSON string ("25.50"), not a number. The fixture mirrors that.
        let data = try loadFixture()
        let source = CodexQuotaSource(client: FakeJSONRPCClient(.success(data)))

        let quota = try await source.fetchQuota()

        let credits = try XCTUnwrap(quota.credits)
        XCTAssertEqual(credits.balance, 25.5)
        XCTAssertTrue(credits.hasCredits)
        XCTAssertFalse(credits.unlimited)
        XCTAssertEqual(try XCTUnwrap(credits.dollarBalance), 1.02, accuracy: 0.0001)
    }

    func testCreditsIgnoreUnrecognizedDollarLikeFields() async throws {
        let json = """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{
            "primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":null},
            "credits":{"hasCredits":true,"unlimited":false,"balance":"1843.31","dollarBalance":"1843.31"}
        }}}
        """
        let source = CodexQuotaSource(client: FakeJSONRPCClient.json(json))

        let quota = try await source.fetchQuota()

        let credits = try XCTUnwrap(quota.credits)
        XCTAssertEqual(credits.balance, 1843.31, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(credits.dollarBalance), 73.7324, accuracy: 0.0001)
    }

    func testCreditsParsed_numericBalance_forwardCompat() async throws {
        // If the provider ever reverts to sending a number, that must keep
        // working too — don't overfit the fix to today's string shape.
        let json = """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{
            "primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":null},
            "credits":{"hasCredits":true,"unlimited":false,"balance":25.5}
        }}}
        """
        let source = CodexQuotaSource(client: FakeJSONRPCClient.json(json))

        let quota = try await source.fetchQuota()

        XCTAssertEqual(quota.credits?.balance, 25.5)
    }

    func testCreditsParsed_unparseableBalance_yieldsNilCreditsWithoutThrowing() async throws {
        // A balance string that isn't numeric at all must degrade `credits`
        // to nil, not fail the whole fetch — the windows are still the
        // primary value of this call.
        let json = """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{
            "primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":null},
            "credits":{"hasCredits":true,"unlimited":false,"balance":"not-a-number"}
        }}}
        """
        let source = CodexQuotaSource(client: FakeJSONRPCClient.json(json))

        let quota = try await source.fetchQuota()

        XCTAssertNil(quota.credits)
        XCTAssertEqual(quota.windows.count, 1, "a malformed credits field must not take the windows down with it")
    }

    func testMissingCreditsIsNil() async throws {
        let json = """
        {"jsonrpc":"2.0","id":2,"result":{"rateLimits":{
            "primary":{"usedPercent":5.0,"windowDurationMins":300,"resetsAt":null}
        }}}
        """
        let source = CodexQuotaSource(client: FakeJSONRPCClient.json(json))

        let quota = try await source.fetchQuota()

        XCTAssertNil(quota.credits)
    }

    // MARK: - Plan type

    func testPlanTypePassthrough() async throws {
        let data = try loadFixture()
        let source = CodexQuotaSource(client: FakeJSONRPCClient(.success(data)))

        let quota = try await source.fetchQuota()

        XCTAssertEqual(quota.planType, "plus")
    }

    // MARK: - Error mapping

    func testCliNotFound_mapsToCliNotFound() async {
        let source = CodexQuotaSource(client: FakeJSONRPCClient(.transportError(.processNotFound(path: "codex"))))

        await assertThrows(source) { error in
            XCTAssertEqual(error, .cliNotFound("codex"))
        }
    }

    func testTimeout_mapsToFailed() async {
        let source = CodexQuotaSource(client: FakeJSONRPCClient(.transportError(.timeout)))

        await assertThrows(source) { error in
            XCTAssertEqual(error, .failed(.codex))
        }
    }

    func testProcessExited_mapsToFailed() async {
        let source = CodexQuotaSource(client: FakeJSONRPCClient(.transportError(.processExited(status: 1, stderrTail: "boom"))))

        await assertThrows(source) { error in
            XCTAssertEqual(error, .failed(.codex))
        }
    }

    func testRpcError_backendUnreachable_mapsToOffline() async {
        let json = """
        {"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"failed to reach backend service"}}
        """
        let source = CodexQuotaSource(client: FakeJSONRPCClient.json(json))

        await assertThrows(source) { error in
            XCTAssertEqual(error, .offline)
        }
    }

    func testRpcError_notLoggedIn_mapsToNotSignedIn() async {
        let json = """
        {"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Not logged in. Please run `codex login`."}}
        """
        let source = CodexQuotaSource(client: FakeJSONRPCClient.json(json))

        await assertThrows(source) { error in
            XCTAssertEqual(error, .notSignedIn(.codex))
        }
    }

    func testRpcError_generic_mapsToFailed() async {
        let json = """
        {"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"method not found"}}
        """
        let source = CodexQuotaSource(client: FakeJSONRPCClient.json(json))

        await assertThrows(source) { error in
            XCTAssertEqual(error, .failed(.codex))
        }
    }

    // MARK: - Privacy

    func testParsedQuota_carriesNoHostnameInstallationIdOrUserAgent() async throws {
        // Adversarial: even if a response line smuggled these fields in
        // (they never legitimately appear on the id-2 rateLimits response —
        // they belong to the id-1 initialize response and the
        // remoteControl/status/changed notification, which the transport
        // never returns to us — see JSONRPCClient.swift), the decode target
        // has no property that could carry them, so they can't survive into
        // ProviderQuota even if present in the bytes.
        let json = """
        {"jsonrpc":"2.0","id":2,"result":{
            "rateLimits":{
                "primary":{"usedPercent":5.0,"windowDurationMins":300,"resetsAt":null},
                "planType":"plus"
            },
            "installationId":"11111111-2222-3333-4444-555555555555",
            "serverName":"someones-macbook.local",
            "userAgent":"meterusage/1.0 codex-cli/0.146.0"
        }}
        """
        let source = CodexQuotaSource(client: FakeJSONRPCClient.json(json))

        let quota = try await source.fetchQuota()

        let dump = String(describing: quota)
        XCTAssertFalse(dump.contains("someones-macbook"))
        XCTAssertFalse(dump.contains("11111111-2222-3333-4444-555555555555"))
        XCTAssertFalse(dump.contains("codex-cli/0.146.0"))
    }

    // MARK: - Helper

    private func assertThrows(
        _ source: CodexQuotaSource,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ check: (SourceUnavailable) -> Void
    ) async {
        do {
            _ = try await source.fetchQuota()
            XCTFail("expected fetchQuota to throw", file: file, line: line)
        } catch let error as SourceUnavailable {
            check(error)
        } catch {
            XCTFail("expected SourceUnavailable, got \(error)", file: file, line: line)
        }
    }
}
