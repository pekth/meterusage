import Foundation

/// Fetches daily token usage and activity metrics from OpenRouter's `/api/v1/activity` endpoint.
///
/// OpenRouter's activity endpoint returns 30 UTC days of prompt/completion/reasoning tokens,
/// requests, and USD spend. OpenRouter restricts this endpoint to Management API Keys.
/// When available, this source produces a `ProviderUsage` with full `ProviderTelemetry`,
/// powering the 30-day activity histogram and token breakdown in the side notch and popover.
public struct OpenRouterUsageSource: UsageSource {
    public let provider: Provider = .openRouter

    private let managementKey: String?
    private let endpoint: URL
    private let session: URLSession

    public init(
        managementKey: String? = nil,
        endpoint: URL? = nil,
        session: URLSession = OpenRouterUsageSource.defaultSession()
    ) {
        self.managementKey = managementKey ?? Self.discoverManagementKey()
        self.endpoint = endpoint ?? URL(string: "https://openrouter.ai/api/v1/activity")!
        self.session = session
    }

    public func fetchUsage() async throws -> ProviderUsage {
        guard let key = Self.normalized(managementKey) else {
            throw SourceUnavailable.dataNotFound("OpenRouter Management Key")
        }

        let data: Data
        do {
            data = try await authenticatedData(at: endpoint, key: key)
        } catch let unavailable as SourceUnavailable {
            throw unavailable
        } catch let error as URLError where error.isOffline {
            throw SourceUnavailable.offline
        } catch {
            throw SourceUnavailable.failed(.openRouter)
        }

        return try Self.parse(data: data, now: Date())
    }

    private func authenticatedData(at url: URL, key: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("meterusage/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceUnavailable.failed(.openRouter)
        }
        switch http.statusCode {
        case 401:
            throw SourceUnavailable.notSignedIn(.openRouter)
        case 403:
            // 403 occurs when a standard inference key is supplied instead of a management key.
            throw SourceUnavailable.dataNotFound("OpenRouter Management Key")
        case 200..<300:
            return data
        default:
            throw SourceUnavailable.failed(.openRouter)
        }
    }

    /// OpenRouter's activity endpoint reports UTC calendar days, and the app's
    /// other session sources bucket telemetry by UTC day. Normalizing those
    /// dates with the user's local calendar shifts every day by one for
    /// timezones behind UTC, which zeroed the "today" reading and misaligned
    /// the histogram, so this source buckets in UTC end to end.
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static func parse(
        data: Data,
        now: Date,
        calendar: Calendar = OpenRouterUsageSource.utcCalendar
    ) throws -> ProviderUsage {
        let response: ActivityResponse
        do {
            response = try JSONDecoder().decode(ActivityResponse.self, from: data)
        } catch {
            throw SourceUnavailable.failed(.openRouter)
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        struct DayStats {
            var promptTokens: Int = 0
            var completionTokens: Int = 0
            var reasoningTokens: Int = 0
            var requests: Int = 0
            var usageDollars: Double = 0
        }

        var dayMap: [Date: DayStats] = [:]

        for item in response.data {
            guard let date = dateFormatter.date(from: item.date) else { continue }
            let dayKey = calendar.startOfDay(for: date)
            var stats = dayMap[dayKey] ?? DayStats()
            stats.promptTokens += max(item.promptTokens ?? 0, 0)
            stats.completionTokens += max(item.completionTokens ?? 0, 0)
            stats.reasoningTokens += max(item.reasoningTokens ?? 0, 0)
            stats.requests += max(item.requests ?? 0, 0)
            stats.usageDollars += max(item.usage ?? 0, 0)
            dayMap[dayKey] = stats
        }

        let dailyActivities = dayMap.map { dayDate, stats in
            DailyActivity(
                day: dayDate,
                tokens: TokenTotals(
                    input: stats.promptTokens,
                    output: stats.completionTokens,
                    reasoning: stats.reasoningTokens
                ),
                estimatedCostUSD: stats.usageDollars,
                sessionCount: stats.requests
            )
        }.sorted(by: { $0.day < $1.day })

        var telemetry = TelemetryCalculator.calculate(
            daily: dailyActivities,
            calendar: calendar,
            now: now
        )

        // Ensure token telemetry fields are populated even if trailing 30 days had 0 activity
        if telemetry.lifetimeTokens == nil {
            telemetry = ProviderTelemetry(
                lifetimeTokens: 0,
                peakDailyTokens: 0,
                currentStreakDays: 0,
                longestStreakDays: 0,
                todayTokens: 0,
                last30DaysTokens: 0,
                dailyHistory: telemetry.dailyHistory
            )
        }

        let totalPrompt = dayMap.values.reduce(0) { $0 + $1.promptTokens }
        let totalCompletion = dayMap.values.reduce(0) { $0 + $1.completionTokens }
        let totalReasoning = dayMap.values.reduce(0) { $0 + $1.reasoningTokens }
        let totalTokens = TokenTotals(input: totalPrompt, output: totalCompletion, reasoning: totalReasoning)
        let totalRequests = dayMap.values.reduce(0) { $0 + $1.requests }
        let totalCost = dayMap.values.reduce(0.0) { $0 + $1.usageDollars }

        let startOfToday = calendar.startOfDay(for: now)
        let todayStats = dayMap[startOfToday]
        let todayRequests = todayStats?.requests ?? 0
        let todayTokens = todayStats.map {
            TokenTotals(input: $0.promptTokens, output: $0.completionTokens, reasoning: $0.reasoningTokens)
        } ?? TokenTotals()

        let windows = [
            UsageWindow(
                label: "last 24h",
                sessionCount: todayRequests,
                messageCount: todayRequests,
                tokens: todayTokens,
                estimatedCostUSD: todayStats?.usageDollars ?? 0
            ),
            UsageWindow(
                label: "last 30d",
                sessionCount: totalRequests,
                messageCount: totalRequests,
                tokens: totalTokens,
                estimatedCostUSD: totalCost
            )
        ]

        return ProviderUsage(
            provider: .openRouter,
            sessionCount: totalRequests,
            messageCount: totalRequests,
            tokens: totalTokens,
            estimatedCostUSD: totalCost > 0 ? totalCost : nil,
            todaySessionCount: todayRequests,
            todayMessageCount: todayRequests,
            usageWindows: windows,
            telemetry: telemetry,
            capturedAt: now
        )
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Discovers an OpenRouter Management Key from environment or standard config paths.
    /// Falls back to the general OpenRouter API key in case the user configured a management key directly.
    static func discoverManagementKey() -> String? {
        if let envKey = normalized(ProcessInfo.processInfo.environment["OPENROUTER_MANAGEMENT_KEY"]) {
            return envKey
        }

        let candidates = [
            HomeDirectory.real.appendingPathComponent(".cli-proxy-api/openrouter-management-key"),
            HomeDirectory.real.appendingPathComponent(".openrouter/management-key"),
            HomeDirectory.real.appendingPathComponent(".config/openrouter/management-key")
        ]
        for candidate in candidates {
            if let contents = try? String(contentsOf: candidate, encoding: .utf8),
               let key = normalized(contents) {
                return key
            }
        }
        return OpenRouterQuotaSource.discoverAPIKey()
    }

    public static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }

    private struct ActivityResponse: Decodable {
        let data: [ActivityItem]
    }

    private struct ActivityItem: Decodable {
        let date: String
        let promptTokens: Int?
        let completionTokens: Int?
        let reasoningTokens: Int?
        let requests: Int?
        let usage: Double?

        private enum CodingKeys: String, CodingKey {
            case date
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case reasoningTokens = "reasoning_tokens"
            case requests
            case usage
        }
    }
}

private extension URLError {
    var isOffline: Bool {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}
