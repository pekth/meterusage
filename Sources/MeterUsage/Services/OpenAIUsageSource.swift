import Foundation

/// Organization totals from OpenAI's documented Usage and Costs APIs.
/// Only an explicitly supplied Admin key is used; Codex credentials are never read.
public struct OpenAIUsageSource: UsageSource {
    public let provider: Provider = .openAI
    private let adminKey: @Sendable () -> String?
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(
        adminKey: @escaping @Sendable () -> String? = { ProcessInfo.processInfo.environment["OPENAI_ADMIN_KEY"] },
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
            throw SourceUnavailable.dataNotFound("OpenAI Admin API key")
        }
        let date = now()
        let today = Self.utcCalendar.startOfDay(for: date)
        let start = Self.utcCalendar.date(byAdding: .day, value: -29, to: today)!
        do {
            let usage: [Bucket<Completion>] = try await buckets(path: "usage/completions", key: key, start: start, end: date)
            let costs: [Bucket<Cost>] = try await buckets(path: "costs", key: key, start: start, end: date)
            return try Self.summarize(usage: usage, costs: costs, start: start, now: date)
        } catch let reason as SourceUnavailable {
            throw reason
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dataNotAllowed].contains(error.code) {
            throw SourceUnavailable.offline
        } catch {
            // Provider responses and transport errors can contain secrets or identifiers.
            throw SourceUnavailable.failed(.openAI)
        }
    }

    private func buckets<Result: Decodable>(path: String, key: String, start: Date, end: Date) async throws -> [Bucket<Result>] {
        var buckets: [Bucket<Result>] = []
        var cursor: String?
        var seen = Set<String>()
        // Thirty daily buckets normally fit one page. Bound unexpected pagination.
        for _ in 0..<5 {
            try Task.checkCancellation()
            var url = URLComponents(string: "https://api.openai.com/v1/organization/\(path)")!
            url.queryItems = [
                URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                URLQueryItem(name: "end_time", value: String(Int(end.timeIntervalSince1970))),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "30")
            ]
            if let cursor { url.queryItems?.append(URLQueryItem(name: "page", value: cursor)) }
            var request = URLRequest(url: url.url!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw SourceUnavailable.failed(.openAI) }
            switch response.statusCode {
            case 401, 403: throw SourceUnavailable.dataNotFound("OpenAI Admin API key with usage access")
            case 200: break
            default: throw SourceUnavailable.failed(.openAI)
            }
            let page = try JSONDecoder().decode(Page<Result>.self, from: data)
            buckets.append(contentsOf: page.data)
            if !page.has_more { return buckets }
            guard let next = page.next_page, !next.isEmpty, seen.insert(next).inserted else {
                throw SourceUnavailable.failed(.openAI)
            }
            cursor = next
        }
        throw SourceUnavailable.failed(.openAI)
    }

    private static func summarize(usage: [Bucket<Completion>], costs: [Bucket<Cost>], start: Date, now: Date) throws -> ProviderUsage {
        let today = utcCalendar.startOfDay(for: now)
        let weekStart = utcCalendar.date(byAdding: .day, value: -6, to: today)!
        var tokens: [Date: TokenTotals] = [:]
        var requests: [Date: Int] = [:]
        var spend: [Date: Double] = [:]
        for bucket in usage {
            let day = utcCalendar.startOfDay(for: Date(timeIntervalSince1970: bucket.start_time))
            guard day >= start, day <= today else { continue }
            for result in bucket.results {
                let cached = result.input_cached_tokens ?? 0
                guard result.input_tokens >= 0, result.output_tokens >= 0,
                      result.num_model_requests >= 0, cached >= 0, cached <= result.input_tokens else {
                    throw SourceUnavailable.failed(.openAI)
                }
                // OpenAI includes cached input in input_tokens; TokenTotals adds it separately.
                tokens[day, default: TokenTotals()] = tokens[day, default: TokenTotals()] + TokenTotals(
                    input: result.input_tokens - cached, output: result.output_tokens, cacheRead: cached
                )
                requests[day, default: 0] += result.num_model_requests
            }
        }
        for bucket in costs {
            let day = utcCalendar.startOfDay(for: Date(timeIntervalSince1970: bucket.start_time))
            guard day >= start, day <= today else { continue }
            for result in bucket.results {
                guard result.amount.currency.lowercased() == "usd", result.amount.value.isFinite else {
                    throw SourceUnavailable.failed(.openAI)
                }
                // Preserve provider adjustments, including negative amounts.
                spend[day, default: 0] += result.amount.value
            }
        }
        let total = tokens.values.reduce(TokenTotals(), +)
        let todayTokens = tokens[today] ?? TokenTotals()
        let totalRequests = requests.values.reduce(0, +)
        let totalCost = spend.values.reduce(0, +)
        let windows = [
            UsageWindow(label: "Today (UTC)", sessionCount: 0, messageCount: requests[today] ?? 0,
                        tokens: todayTokens, estimatedCostUSD: spend[today] ?? 0),
            UsageWindow(label: "last 30d", sessionCount: 0, messageCount: totalRequests,
                        tokens: total, estimatedCostUSD: totalCost)
        ]
        return ProviderUsage(
            provider: .openAI, sessionCount: 0, messageCount: totalRequests,
            tokens: total, estimatedCostUSD: totalCost,
            todayMessageCount: requests[today] ?? 0, todayTokens: todayTokens,
            weekTokens: tokens.filter { $0.key >= weekStart }.values.reduce(TokenTotals(), +),
            todayCostUSD: spend[today] ?? 0, usageWindows: windows, capturedAt: now
        )
    }

    public static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    private struct Page<Result: Decodable>: Decodable {
        let data: [Bucket<Result>]
        let has_more: Bool
        let next_page: String?
    }
    private struct Bucket<Result: Decodable>: Decodable {
        let start_time: TimeInterval
        let results: [Result]
    }
    private struct Completion: Decodable {
        let input_tokens: Int
        let output_tokens: Int
        let input_cached_tokens: Int?
        let num_model_requests: Int
    }
    private struct Cost: Decodable {
        let amount: Amount
        struct Amount: Decodable {
            let value: Double
            let currency: String
        }
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
