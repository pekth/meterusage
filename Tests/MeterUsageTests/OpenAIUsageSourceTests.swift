import XCTest
@testable import MeterUsage

final class OpenAIUsageSourceTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-27T12:00:00Z")!

    private func source(_ handler: @escaping (URLRequest) throws -> (Int, String)) -> OpenAIUsageSource {
        OpenAIProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenAIProtocol.self]
        let date = now
        return OpenAIUsageSource(adminKey: { "synthetic-admin" }, session: URLSession(configuration: config), now: { date })
    }

    override func tearDown() {
        OpenAIProtocol.handler = nil
        super.tearDown()
    }

    private func page(_ buckets: String, more: Bool = false, cursor: String = "null") -> String {
        "{\"data\":[\(buckets)],\"has_more\":\(more),\"next_page\":\(cursor)}"
    }

    private func completion(day: Int, input: Int = 100, cached: Int = 40, output: Int = 20) -> String {
        """
        {"start_time":\(day),"results":[{"input_tokens":\(input),"input_cached_tokens":\(cached),
        "output_tokens":\(output),"num_model_requests":2,"project_id":"private-project","api_key_id":"private-key-id"}]}
        """
    }

    private func cost(day: Int, currency: String = "usd", value: Double = 1.25) -> String {
        """
        {"start_time":\(day),"results":[{"amount":{"value":\(value),"currency":"\(currency)"},
        "organization_id":"private-org","line_item":"private-label"}]}
        """
    }

    func testPaginatedUTCTotalsSeparateCachedTokensAndProviderCosts() async throws {
        let today = Int(OpenAIUsageSource.utcCalendar.startOfDay(for: now).timeIntervalSince1970)
        var calls = 0
        let reader = source { request in
            calls += 1
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, "api.openai.com")
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-admin")
            XCTAssertNil(request.httpBody)
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertTrue(query.contains(URLQueryItem(name: "start_time", value: String(today - 29 * 86400))))
            XCTAssertTrue(query.contains(URLQueryItem(name: "end_time", value: String(today + 12 * 3600))))
            XCTAssertTrue(query.contains(URLQueryItem(name: "bucket_width", value: "1d")))
            XCTAssertFalse(query.contains { $0.name == "group_by" })
            let nextPage = query.contains { $0.name == "page" && $0.value == "next" }
            if url.path.hasSuffix("completions") {
                return nextPage
                    ? (200, self.page(self.completion(day: today)))
                    : (200, self.page(self.completion(day: today - 86400), more: true, cursor: "\"next\""))
            }
            XCTAssertEqual(url.path, "/v1/organization/costs")
            return nextPage
                ? (200, self.page(self.cost(day: today, value: -0.25)))
                : (200, self.page(self.cost(day: today - 86400), more: true, cursor: "\"next\""))
        }
        let usage = try await reader.fetchUsage()
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(usage.provider, .openAI)
        XCTAssertEqual(usage.sessionCount, 0)
        XCTAssertEqual(usage.messageCount, 4)
        XCTAssertEqual(usage.tokens, TokenTotals(input: 120, output: 40, cacheRead: 80))
        XCTAssertEqual(usage.tokens?.total, 240)
        XCTAssertEqual(usage.todayTokens?.total, 120)
        XCTAssertEqual(usage.weekTokens?.total, 240)
        XCTAssertEqual(usage.todayCostUSD, -0.25)
        XCTAssertEqual(usage.estimatedCostUSD, 1)
        XCTAssertEqual(usage.usageWindows?.map(\.label), ["Today (UTC)", "last 30d"])
        XCTAssertNil(usage.telemetry?.lifetimeTokens)
        XCTAssertFalse(String(reflecting: usage).contains("private-"))
        XCTAssertFalse(String(reflecting: usage).contains("synthetic-admin"))
    }

    func testEmptySuccessfulPagesAreMeasuredZero() async throws {
        let usage = try await source { _ in (200, self.page("")) }.fetchUsage()
        XCTAssertEqual(usage.tokens, TokenTotals())
        XCTAssertEqual(usage.todayTokens, TokenTotals())
        XCTAssertEqual(usage.estimatedCostUSD, 0)
        XCTAssertEqual(usage.todayCostUSD, 0)
    }

    func testMissingKeyDoesNotSendRequest() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenAIProtocol.self]
        OpenAIProtocol.handler = { _ in XCTFail("No request without opt-in credentials"); return (200, "") }
        do {
            _ = try await OpenAIUsageSource(adminKey: { " \n " }, session: URLSession(configuration: config)).fetchUsage()
            XCTFail("Expected missing-key state")
        } catch {
            XCTAssertEqual(error as? SourceUnavailable, .dataNotFound("OpenAI Admin API key"))
        }
    }

    func testHTTPFailuresAndOfflineAreSanitizedWithoutRetry() async {
        for status in [401, 403, 429, 500] {
            var calls = 0
            let reader = source { _ in calls += 1; return (status, "sensitive-provider-error") }
            do {
                _ = try await reader.fetchUsage()
                XCTFail("Expected unavailable state")
            } catch {
                let expected: SourceUnavailable = status == 401 || status == 403
                    ? .dataNotFound("OpenAI Admin API key with usage access") : .failed(.openAI)
                XCTAssertEqual(error as? SourceUnavailable, expected)
                XCTAssertFalse(String(describing: error).contains("sensitive-provider-error"))
            }
            XCTAssertEqual(calls, 1)
        }
        do {
            _ = try await source { _ in throw URLError(.notConnectedToInternet) }.fetchUsage()
            XCTFail("Expected offline state")
        } catch { XCTAssertEqual(error as? SourceUnavailable, .offline) }
    }

    func testCostsFailureNeverBecomesZeroSpend() async {
        let reader = source { request in
            request.url!.path.hasSuffix("costs") ? (403, "private-error") : (200, self.page(""))
        }
        do {
            _ = try await reader.fetchUsage()
            XCTFail("Incomplete readings must not appear as zero spend")
        } catch { XCTAssertEqual(error as? SourceUnavailable, .dataNotFound("OpenAI Admin API key with usage access")) }
    }

    func testDefaultSessionKeepsCredentialsOffDiskAndRejectsRedirects() throws {
        let session = OpenAIUsageSource.defaultSession()
        defer { session.invalidateAndCancel() }
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        let url = URL(string: "https://api.openai.com/v1/organization/costs")!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let redirected = URLRequest(url: URL(string: "https://example.com/collect")!)
        let delegate = try XCTUnwrap(session.delegate as? URLSessionTaskDelegate)
        let rejected = expectation(description: "Redirect rejected")
        delegate.urlSession?(session, task: session.dataTask(with: url), willPerformHTTPRedirection: response,
                             newRequest: redirected) { request in
            XCTAssertNil(request)
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 1)
    }

    func testMalformedRepeatedAndUnboundedPaginationFails() async {
        for mode in 0..<3 {
            var calls = 0
            let reader = source { _ in
                calls += 1
                let cursor = mode == 0 ? "null" : "\"\(mode == 1 ? 1 : calls)\""
                return (200, self.page("", more: true, cursor: cursor))
            }
            do {
                _ = try await reader.fetchUsage()
                XCTFail("Expected incomplete-page failure")
            } catch { XCTAssertEqual(error as? SourceUnavailable, .failed(.openAI)) }
            XCTAssertEqual(calls, [1, 2, 5][mode])
        }
    }

    func testMalformedResponsesAndNonUSDCostsFail() async {
        let day = Int(OpenAIUsageSource.utcCalendar.startOfDay(for: now).timeIntervalSince1970)
        for invalid in ["{}", page(completion(day: day, cached: 101)), page(completion(day: day, input: -1))] {
            do {
                _ = try await source { request in
                    (200, request.url!.path.hasSuffix("completions") ? invalid : self.page(""))
                }.fetchUsage()
                XCTFail("Expected malformed reading failure")
            } catch { XCTAssertEqual(error as? SourceUnavailable, .failed(.openAI)) }
        }
        do {
            _ = try await source { request in
                (200, request.url!.path.hasSuffix("costs") ? self.page(self.cost(day: day, currency: "eur")) : self.page(""))
            }.fetchUsage()
            XCTFail("Must not label another currency as USD")
        } catch { XCTAssertEqual(error as? SourceUnavailable, .failed(.openAI)) }
    }

    @MainActor
    func testOptInPersistsSeparatelyFromCodexWithoutQuotaOrTray() throws {
        let name = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(Preferences(defaults: defaults).isEnabled(.openAI))
        defaults.set(true, forKey: PrefKey.showOpenAI)
        defaults.set(false, forKey: PrefKey.showCodex)
        let preferences = Preferences(defaults: defaults)
        let coordinator = AppCoordinator(preferences: preferences, usageSources: [DemoOpenAIUsageSource()])
        XCTAssertTrue(coordinator.visibleUsageProviders.contains(.openAI))
        XCTAssertFalse(preferences.isEnabled(.codex))
        XCTAssertFalse(coordinator.visibleQuotaSlots.contains(.primary(.openAI)))
        XCTAssertFalse(coordinator.menuBarSlots.contains(.primary(.openAI)))
        XCTAssertFalse(coordinator.sideNotchSlots.contains(.primary(.openAI)))
        XCTAssertTrue(Composition.usageSources().contains { $0.provider == .openAI })
    }

    func testOrganizationUsageDoesNotDoubleCountLocalCodingTotals() async throws {
        let usage = try await DemoOpenAIUsageSource().fetchUsage()
        let totals = StripTotals.calculate(activities: [], usages: [usage], now: now)
        XCTAssertEqual(totals.todayTokens, 0)
        XCTAssertEqual(totals.weekTokens, 0)
        XCTAssertEqual(totals.todayCost, 0)
        XCTAssertTrue(BurnAttributionCalculator.attributionSessions(
            activities: [:], usages: [.primary(.openAI): .value(usage)], now: now
        ).isEmpty)
    }
}

private final class OpenAIProtocol: URLProtocol {
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
