import Foundation

/// Reads OpenRouter's authenticated API-key usage and account-credit summaries.
///
/// OpenRouter reports spend in USD, along with an optional key limit and reset
/// cadence. Its credits endpoint reports the account's total purchased credits
/// and total spend, which lets the UI show the remaining account balance too.
/// The source only keeps those aggregate numeric fields; it never sends
/// prompts, model requests, or the key itself anywhere except the provider
/// endpoint's Authorization header.
public struct OpenRouterQuotaSource: QuotaSource {
    public let provider: Provider = .openRouter

    private let apiKey: String?
    private let endpoint: URL
    private let creditsEndpoint: URL
    private let session: URLSession

    public init(
        apiKey: String? = nil,
        endpoint: URL? = nil,
        creditsEndpoint: URL? = nil,
        session: URLSession = OpenRouterQuotaSource.defaultSession()
    ) {
        self.apiKey = apiKey ?? Self.discoverAPIKey()
        self.endpoint = endpoint ?? URL(string: "https://openrouter.ai/api/v1/key")!
        self.creditsEndpoint = creditsEndpoint ?? URL(string: "https://openrouter.ai/api/v1/credits")!
        self.session = session
    }

    public func fetchQuota() async throws -> ProviderQuota {
        guard let key = Self.normalized(apiKey) else {
            throw SourceUnavailable.dataNotFound("OpenRouter API key")
        }

        do {
            let keyData = try await authenticatedData(at: endpoint, key: key)
            // `/key` is the required usage source. `/credits` is an optional
            // account-balance supplement, so a temporary failure there must
            // not hide otherwise valid key usage.
            let creditsData = endpoint == creditsEndpoint
                ? nil
                : try? await authenticatedData(at: creditsEndpoint, key: key)
            return try Self.parse(data: keyData, creditsData: creditsData, now: Date())
        } catch let unavailable as SourceUnavailable {
            throw unavailable
        } catch let error as URLError where error.isOffline {
            throw SourceUnavailable.offline
        } catch {
            throw SourceUnavailable.failed(.openRouter)
        }
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
        case 200..<300:
            return data
        default:
            throw SourceUnavailable.failed(.openRouter)
        }
    }

    static func parse(data: Data, now: Date) throws -> ProviderQuota {
        try parse(data: data, creditsData: nil, now: now)
    }

    static func parse(data: Data, creditsData: Data?, now: Date) throws -> ProviderQuota {
        let response: KeyResponse
        do {
            response = try JSONDecoder().decode(KeyResponse.self, from: data)
        } catch {
            throw SourceUnavailable.failed(.openRouter)
        }

        let usage = response.data.usage.map { max($0, 0) }
        let limit = response.data.limit
        let remaining = response.data.limitRemaining.map { max($0, 0) }
            ?? limit.map { max($0 - (usage ?? 0), 0) }

        guard usage != nil || limit != nil || remaining != nil else {
            throw SourceUnavailable.noData
        }

        let windows: [QuotaWindow]
        if let usage, let limit, limit > 0 {
            windows = [
                QuotaWindow(
                    label: Self.windowLabel(for: response.data.limitReset),
                    usedPercent: (usage / limit) * 100,
                    resetsAt: nil
                )
            ]
        } else {
            windows = []
        }

        let credits = Self.accountCredits(from: creditsData)
            ?? CreditBalance(
                balance: remaining ?? 0,
                hasCredits: remaining.map { $0 > 0 } ?? ((usage ?? 0) > 0),
                unlimited: limit == nil,
                unit: .dollars,
                usedDollars: usage,
                limitDollars: limit
            )

        return ProviderQuota(
            provider: .openRouter,
            windows: windows,
            credits: credits,
            capturedAt: now
        )
    }

    private static func accountCredits(from data: Data?) -> CreditBalance? {
        guard let data,
              let response = try? JSONDecoder().decode(CreditsResponse.self, from: data),
              let total = response.data.totalCredits else {
            return nil
        }

        let totalCredits = max(total, 0)
        let usage = response.data.totalUsage.map { max($0, 0) }
        let balance = max(totalCredits - (usage ?? 0), 0)
        return CreditBalance(
            balance: balance,
            hasCredits: balance > 0,
            unlimited: false,
            unit: .dollars,
            usedDollars: usage,
            limitDollars: totalCredits
        )
    }

    private struct CreditsResponse: Decodable {
        let data: CreditsData
    }

    private struct CreditsData: Decodable {
        let totalCredits: Double?
        let totalUsage: Double?

        private enum CodingKeys: String, CodingKey {
            case totalCredits = "total_credits"
            case totalUsage = "total_usage"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            totalCredits = Self.decodeOptionalDouble(forKey: .totalCredits, from: container)
            totalUsage = Self.decodeOptionalDouble(forKey: .totalUsage, from: container)
        }

        private static func decodeOptionalDouble(
            forKey key: CodingKeys,
            from container: KeyedDecodingContainer<CodingKeys>
        ) -> Double? {
            if let number = try? container.decode(Double.self, forKey: key) {
                return number
            }
            if let string = try? container.decode(String.self, forKey: key),
               let number = Double(string) {
                return number
            }
            return nil
        }
    }

    public static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    private static func windowLabel(for raw: String?) -> String {
        switch raw?.lowercased() {
        case "daily": return "Daily"
        case "weekly": return "Weekly"
        case "monthly": return "Monthly"
        default: return "Spending limit"
        }
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Environment first keeps shell/container setups working. The file
    /// fallback supports the local OpenRouter integrations already configured
    /// on this Mac without adding a second credential-entry UI.
    private static func discoverAPIKey() -> String? {
        if let environmentKey = normalized(ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]) {
            return environmentKey
        }

        let candidates = [
            HomeDirectory.real.appendingPathComponent(".cli-proxy-api/openrouter-api-key"),
            HomeDirectory.real.appendingPathComponent(".openrouter/api-key"),
            HomeDirectory.real.appendingPathComponent(".config/openrouter/api-key")
        ]
        for candidate in candidates {
            if let contents = try? String(contentsOf: candidate, encoding: .utf8),
               let key = normalized(contents) {
                return key
            }
        }
        return nil
    }

    private struct KeyResponse: Decodable {
        let data: KeyData
    }

    private struct KeyData: Decodable {
        let usage: Double?
        let limit: Double?
        let limitRemaining: Double?
        let limitReset: String?

        private enum CodingKeys: String, CodingKey {
            case usage
            case limit
            case limitRemaining = "limit_remaining"
            case limitReset = "limit_reset"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usage = Self.decodeOptionalDouble(forKey: .usage, from: container)
            limit = Self.decodeOptionalDouble(forKey: .limit, from: container)
            limitRemaining = Self.decodeOptionalDouble(forKey: .limitRemaining, from: container)
            limitReset = try container.decodeIfPresent(String.self, forKey: .limitReset)
        }

        private static func decodeOptionalDouble(
            forKey key: CodingKeys,
            from container: KeyedDecodingContainer<CodingKeys>
        ) -> Double? {
            if let number = try? container.decode(Double.self, forKey: key) {
                return number
            }
            if let string = try? container.decode(String.self, forKey: key),
               let number = Double(string) {
                return number
            }
            return nil
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
