import XCTest
@testable import MeterUsage

final class AnthropicUsageSourceTests: XCTestCase {
    func testAnthropicAPIMonitorIsAvailableSeparatelyFromClaudeCode() {
        XCTAssertTrue(Composition.usageSources().contains { $0.provider.displayName == "Anthropic API" })
        XCTAssertTrue(Provider.allCases.contains { $0.displayName == "Claude" })
    }

    private let now = ISO8601DateFormatter().date(from: "2026-09-27T12:00:00Z")!

    private func source(_ handler: @escaping (URLRequest) throws -> (Int, String)) -> AnthropicUsageSource {
        AnthropicProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnthropicProtocol.self]
        let date = now
        return AnthropicUsageSource(adminKey: { "synthetic-admin" }, session: URLSession(configuration: config), now: { date })
    }

    override func tearDown() {
        AnthropicProtocol.handler = nil
        super.tearDown()
    }

    private func page(_ buckets: String, more: Bool = false, cursor: String = "null") -> String {
        "{\"data\":[\(buckets)],\"has_more\":\(more),\"next_page\":\(cursor)}"
    }

    private func usage(day: String, input: Int = 100) -> String {
        """
        {"starting_at":"\(day)","results":[{"uncached_input_tokens":\(input),"output_tokens":20,
        "cache_read_input_tokens":40,"cache_creation":{"ephemeral_1h_input_tokens":30,"ephemeral_5m_input_tokens":10},
        "server_tool_use":{"web_search_requests":9},"workspace_id":"private-workspace","api_key_id":"private-key"}]}
        """
    }

    private func cost(day: String, amount: String = "123.45", currency: String = "USD") -> String {
        """
        {"starting_at":"\(day)","results":[{"amount":"\(amount)","currency":"\(currency)","description":"private-description"}]}
        """
    }

    func testPaginationUTCBoundsCacheCategoriesAndCentsConversion() async throws {
        var calls = 0
        let reader = source { request in
            calls += 1
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "api.anthropic.com")
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "synthetic-admin")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertTrue(query.contains(URLQueryItem(name: "starting_at", value: "2026-08-29T00:00:00Z")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "ending_at", value: "2026-09-28T00:00:00Z")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "bucket_width", value: "1d")))
            XCTAssertFalse(query.contains { $0.name.contains("key") || $0.name.contains("workspace") || $0.name.contains("group") })
            let nextPage = query.contains { $0.name == "page" && $0.value == "next" }
            if url.path.hasSuffix("usage_report/messages") {
                return nextPage
                    ? (200, self.page(self.usage(day: "2026-09-27T00:00:00.000Z")))
                    : (200, self.page(self.usage(day: "2026-09-26T00:00:00Z"), more: true, cursor: "\"next\""))
            }
            XCTAssertEqual(url.path, "/v1/organizations/cost_report")
            return nextPage
                ? (200, self.page(self.cost(day: "2026-09-27T07:00:00+07:00") + "," + self.cost(day: "2026-09-27T00:00:00Z", amount: "-23.45")))
                : (200, self.page(self.cost(day: "2026-09-26T00:00:00Z", amount: "250"), more: true, cursor: "\"next\""))
        }
        let reading = try await reader.fetchUsage()
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(reading.provider, .anthropic)
        XCTAssertEqual(reading.tokens, TokenTotals(input: 200, output: 40, cacheRead: 80, cacheWrite: 80))
        XCTAssertEqual(reading.tokens?.total, 400)
        XCTAssertEqual(reading.todayTokens?.total, 200)
        XCTAssertEqual(try XCTUnwrap(reading.estimatedCostUSD), 3.5, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(reading.todayCostUSD), 1, accuracy: 0.000001)
        // Tool calls are not model requests or local sessions.
        XCTAssertEqual(reading.messageCount, 0)
        XCTAssertEqual(reading.sessionCount, 0)
        XCTAssertFalse(String(reflecting: reading).contains("private-"))
        XCTAssertFalse(String(reflecting: reading).contains("synthetic-admin"))
    }

    func testEmptySuccessfulPagesAreMeasuredZero() async throws {
        let reading = try await source { _ in (200, self.page("")) }.fetchUsage()
        XCTAssertEqual(reading.tokens, TokenTotals())
        XCTAssertEqual(reading.todayTokens, TokenTotals())
        XCTAssertEqual(reading.estimatedCostUSD, 0)
        XCTAssertEqual(reading.todayCostUSD, 0)
    }

    func testMissingCredentialsAndHTTPFailuresAreSanitized() async {
        do {
            _ = try await AnthropicUsageSource(adminKey: { nil }).fetchUsage()
            XCTFail("Expected missing key")
        } catch { XCTAssertEqual(error as? SourceUnavailable, .dataNotFound("Anthropic Admin API key")) }
        for status in [401, 403, 429, 500] {
            var calls = 0
            do {
                _ = try await source { _ in calls += 1; return (status, "sensitive-error") }.fetchUsage()
                XCTFail("Expected unavailable state")
            } catch {
                let expected: SourceUnavailable = status == 401 || status == 403
                    ? .dataNotFound("Anthropic Admin API key with usage access") : .failed(.anthropic)
                XCTAssertEqual(error as? SourceUnavailable, expected)
                XCTAssertFalse(String(describing: error).contains("sensitive-error"))
            }
            XCTAssertEqual(calls, 1)
        }
        do {
            _ = try await source { _ in throw URLError(.notConnectedToInternet) }.fetchUsage()
            XCTFail("Expected offline state")
        } catch { XCTAssertEqual(error as? SourceUnavailable, .offline) }
    }

    func testPartialMalformedAndNonUSDReadingsNeverBecomeZeroSpend() async {
        for badCost in ["{}", page(cost(day: "invalid")), page(cost(day: "2026-09-27T00:00:00Z", amount: "NaN")),
                        page(cost(day: "2026-09-27T00:00:00Z", currency: "EUR"))] {
            do {
                _ = try await source { request in
                    (200, request.url!.path.hasSuffix("cost_report") ? badCost : self.page(""))
                }.fetchUsage()
                XCTFail("Expected invalid cost failure")
            } catch { XCTAssertEqual(error as? SourceUnavailable, .failed(.anthropic)) }
        }
        do {
            _ = try await source { request in
                request.url!.path.hasSuffix("cost_report") ? (403, "private-error") : (200, self.page(""))
            }.fetchUsage()
            XCTFail("Expected unavailable reading, not zero spend")
        } catch { XCTAssertEqual(error as? SourceUnavailable, .dataNotFound("Anthropic Admin API key with usage access")) }
        for mode in 0..<3 {
            var calls = 0
            do {
                _ = try await source { _ in
                    calls += 1
                    return (200, self.page("", more: true, cursor: mode == 0 ? "null" : "\"\(mode == 1 ? 1 : calls)\""))
                }.fetchUsage()
                XCTFail("Expected incomplete pagination failure")
            } catch { XCTAssertEqual(error as? SourceUnavailable, .failed(.anthropic)) }
            XCTAssertEqual(calls, [1, 2, 5][mode])
        }
    }

    @MainActor
    func testOptInPersistsAndOrganizationUsageStaysOutOfLocalTotals() async throws {
        let name = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(Preferences(defaults: defaults).isEnabled(.anthropic))
        defaults.set(true, forKey: PrefKey.showAnthropic)
        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(Preferences(defaults: defaults).isEnabled(.anthropic))
        let coordinator = AppCoordinator(preferences: preferences, usageSources: [DemoAnthropicUsageSource()])
        XCTAssertTrue(coordinator.visibleUsageProviders.contains(.anthropic))
        XCTAssertFalse(coordinator.visibleQuotaSlots.contains(.primary(.anthropic)))
        XCTAssertFalse(coordinator.sideNotchSlots.contains(.primary(.anthropic)))
        XCTAssertFalse(coordinator.menuBarSlots.contains(.primary(.anthropic)))
        let reading = try await DemoAnthropicUsageSource().fetchUsage()
        let totals = StripTotals.calculate(activities: [], usages: [reading], now: now)
        XCTAssertEqual(totals.todayTokens, 0)
        XCTAssertEqual(totals.todayCost, 0)
        XCTAssertTrue(BurnAttributionCalculator.attributionSessions(
            activities: [:], usages: [.primary(.anthropic): .value(reading)], now: now
        ).isEmpty)
    }
}

private final class AnthropicProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
