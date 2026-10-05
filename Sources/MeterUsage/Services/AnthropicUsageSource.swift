import Foundation

/// Organization totals from Anthropic's documented Usage and Cost Admin APIs.
/// Only an explicitly supplied Admin key is used; Claude Code credentials are never read.
public struct AnthropicUsageSource: UsageSource {
    public let provider: Provider = .anthropic
    private let adminKey: @Sendable () -> String?
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        adminKey: @escaping @Sendable () -> String? = { ProcessInfo.processInfo.environment["ANTHROPIC_ADMIN_KEY"] },
        session: URLSession = OpenAIUsageSource.defaultSession(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.adminKey = adminKey
        self.session = session
        self.now = now
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    public func fetchUsage() async throws -> ProviderUsage {
        guard let key = adminKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, !key.contains("\r"), !key.contains("\n") else {
            throw SourceUnavailable.dataNotFound("Anthropic Admin API key")
        }
        let date = now()
        let today = Self.utcCalendar.startOfDay(for: date)
        let start = Self.utcCalendar.date(byAdding: .day, value: -29, to: today)!
        let end = Self.utcCalendar.date(byAdding: .day, value: 1, to: today)!
        do {
            let usage: [Bucket<MessageUsage>] = try await buckets(path: "usage_report/messages", key: key, start: start, end: end)
            let costs: [Bucket<Cost>] = try await buckets(path: "cost_report", key: key, start: start, end: end)
            return try Self.summarize(usage: usage, costs: costs, start: start, now: date)
        } catch let reason as SourceUnavailable {
            throw reason
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dataNotAllowed].contains(error.code) {
            throw SourceUnavailable.offline
        } catch {
            // Provider responses and transport errors can contain secrets or identifiers.
            throw SourceUnavailable.failed(.anthropic)
        }
    }

    private func buckets<Result: Decodable>(path: String, key: String, start: Date, end: Date) async throws -> [Bucket<Result>] {
        var buckets: [Bucket<Result>] = []
        var cursor: String?
        var seen = Set<String>()
        // Thirty daily buckets normally fit one page. Bound unexpected pagination.
        for _ in 0..<5 {
            try Task.checkCancellation()
            var url = URLComponents(string: "https://api.anthropic.com/v1/organizations/\(path)")!
            url.queryItems = [
                URLQueryItem(name: "starting_at", value: ISO8601DateFormatter().string(from: start)),
                URLQueryItem(name: "ending_at", value: ISO8601DateFormatter().string(from: end)),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "30")
            ]
            if let cursor { url.queryItems?.append(URLQueryItem(name: "page", value: cursor)) }
            var request = URLRequest(url: url.url!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("meterusage/\(AppInfo.version) (https://github.com/pekth/meterusage)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw SourceUnavailable.failed(.anthropic) }
            switch response.statusCode {
            case 401, 403: throw SourceUnavailable.dataNotFound("Anthropic Admin API key with usage access")
            case 200: break
            default: throw SourceUnavailable.failed(.anthropic)
            }
            let page = try JSONDecoder().decode(Page<Result>.self, from: data)
            buckets.append(contentsOf: page.data)
            if !page.has_more { return buckets }
            guard let next = page.next_page, !next.isEmpty, seen.insert(next).inserted else {
                throw SourceUnavailable.failed(.anthropic)
            }
            cursor = next
        }
        throw SourceUnavailable.failed(.anthropic)
    }

    private static func summarize(usage: [Bucket<MessageUsage>], costs: [Bucket<Cost>], start: Date, now: Date) throws -> ProviderUsage {
        let today = utcCalendar.startOfDay(for: now)
        let formatter = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        func day(_ timestamp: String) throws -> Date {
            guard let date = formatter.date(from: timestamp) ?? fractional.date(from: timestamp) else {
                throw SourceUnavailable.failed(.anthropic)
            }
            return utcCalendar.startOfDay(for: date)
        }
        var tokens: [Date: TokenTotals] = [:]
        var spend: [Date: Double] = [:]
        for bucket in usage {
            let date = try day(bucket.starting_at)
            guard date >= start, date <= today else { continue }
            for result in bucket.results {
                let creation = result.cache_creation
                guard [result.uncached_input_tokens, result.output_tokens, result.cache_read_input_tokens,
                       creation.ephemeral_1h_input_tokens, creation.ephemeral_5m_input_tokens].allSatisfy({ $0 >= 0 }) else {
                    throw SourceUnavailable.failed(.anthropic)
                }
                tokens[date, default: TokenTotals()] = tokens[date, default: TokenTotals()] + TokenTotals(
                    input: result.uncached_input_tokens, output: result.output_tokens,
                    cacheRead: result.cache_read_input_tokens,
                    cacheWrite: creation.ephemeral_1h_input_tokens + creation.ephemeral_5m_input_tokens
                )
            }
        }
        for bucket in costs {
            let date = try day(bucket.starting_at)
            guard date >= start, date <= today else { continue }
            for result in bucket.results {
                guard result.currency.lowercased() == "usd", let cents = Double(result.amount), cents.isFinite else {
                    throw SourceUnavailable.failed(.anthropic)
                }
                // The report uses decimal cents, not dollars. Preserve adjustments.
                spend[date, default: 0] += cents / 100
            }
        }
        let total = tokens.values.reduce(TokenTotals(), +)
        let todayTokens = tokens[today] ?? TokenTotals()
        let totalCost = spend.values.reduce(0, +)
        // Anthropic reports token totals and tool-use counts, not a total request count.
        return ProviderUsage(
            provider: .anthropic, sessionCount: 0, messageCount: 0,
            tokens: total, estimatedCostUSD: totalCost, todayTokens: todayTokens,
            todayCostUSD: spend[today] ?? 0,
            usageWindows: [
                UsageWindow(label: "Today (UTC)", sessionCount: 0, messageCount: 0,
                            tokens: todayTokens, estimatedCostUSD: spend[today] ?? 0),
                UsageWindow(label: "last 30d", sessionCount: 0, messageCount: 0,
                            tokens: total, estimatedCostUSD: totalCost)
            ], capturedAt: now
        )
    }

    private struct Page<Result: Decodable>: Decodable {
        let data: [Bucket<Result>]
        let has_more: Bool
        let next_page: String?
    }
    private struct Bucket<Result: Decodable>: Decodable {
        let starting_at: String
        let results: [Result]
    }
    private struct MessageUsage: Decodable {
        let uncached_input_tokens: Int
        let output_tokens: Int
        let cache_read_input_tokens: Int
        let cache_creation: CacheCreation
        struct CacheCreation: Decodable {
            let ephemeral_1h_input_tokens: Int
            let ephemeral_5m_input_tokens: Int
        }
    }
    private struct Cost: Decodable {
        let amount: String
        let currency: String
    }
}
