import Foundation

/// Reads Grok's live usage allowance from the same billing service the grok
/// CLI talks to.
///
/// Grok Build bills against a subscription allowance (a weekly window for the
/// X Premium tier) rather than an open balance. The billing endpoint reports
/// the current period type, the share of the allowance used, and when the
/// period rolls over. This source reads only those numeric and timestamp
/// fields. It never sends prompts, model requests, or the token anywhere
/// except the endpoint's Authorization header.
///
/// The token comes from the OIDC credentials the grok CLI stores at
/// `~/.grok/auth.json` after `grok login`. This source never invokes the grok
/// binary and never reads the token's value into anything but the request
/// header.
public struct GrokQuotaSource: QuotaSource {
    public let provider: Provider = .grok

    private let apiToken: String?
    private let endpoint: URL
    private let session: URLSession

    public init(
        apiToken: String? = nil,
        endpoint: URL? = nil,
        session: URLSession = GrokQuotaSource.defaultSession()
    ) {
        // `nil` is kept meaning "discover per fetch", never resolved once here:
        // the grok CLI rotates the OIDC token in `~/.grok/auth.json` on a
        // regular basis, and an app that caches the token from launch shows a
        // stale account until it is relaunched.
        self.apiToken = apiToken
        self.endpoint = endpoint ?? URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        self.session = session
    }

    public func fetchQuota() async throws -> ProviderQuota {
        let token = Self.normalized(apiToken) ?? Self.normalized(Self.discoverToken())
        guard let token else {
            throw SourceUnavailable.dataNotFound("Grok credentials")
        }

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("meterusage/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch let error as URLError where error.isOffline {
            throw SourceUnavailable.offline
        } catch {
            throw SourceUnavailable.failed(.grok)
        }

        do {
            return try Self.parse(data: data, now: Date())
        } catch let unavailable as SourceUnavailable {
            throw unavailable
        } catch {
            throw SourceUnavailable.failed(.grok)
        }
    }

    /// Parses the billing payload into the current allowance window.
    ///
    /// ```json
    /// {"config":{
    ///   "currentPeriod":{
    ///     "type":"USAGE_PERIOD_TYPE_WEEKLY",
    ///     "start":"2026-08-11T04:06:19.522482+00:00",
    ///     "end":"2026-08-18T04:06:19.522482+00:00"},
    ///   "creditUsagePercent":31.0,
    ///   "billingPeriodStart":"2026-08-11T04:06:19.522482+00:00",
    ///   "billingPeriodEnd":"2026-08-18T04:06:19.522482+00:00"}}
    /// ```
    ///
    /// `currentPeriod.type` is the authority for the window label: the period
    /// is weekly on the X Premium tier, monthly on some other tiers, and
    /// either way the "Weekly" or "Monthly" label is what the reset countdown
    /// hangs off. The reset time comes from `billingPeriodEnd`, with
    /// `currentPeriod.end` as a fallback.
    static func parse(data: Data, now: Date) throws -> ProviderQuota {
        // An auth-shaped error body means "not signed in" (grok login has not
        // been run, or the cached token expired), never a generic failure —
        // the user needs to know to sign in with the Grok CLI. Checked first
        // because the success envelope is fully optional and would otherwise
        // swallow the error shape into an empty config.
        if let errorBody = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            switch errorBody.error.type.lowercased() {
            case "autherror", "invalid_api_key", "invalid_token", "unauthorized":
                throw SourceUnavailable.notSignedIn(.grok)
            default:
                throw SourceUnavailable.failed(.grok)
            }
        }
        // The auth failure can also arrive as `{"error":"<message>"}` (the
        // live service returns this string form on a stale bearer token).
        if let message = try? JSONDecoder().decode(StringErrorResponse.self, from: data) {
            let lowered = message.error.lowercased()
            if lowered.contains("invalid") || lowered.contains("expired")
                || lowered.contains("unauth") || lowered.contains("not signed") {
                throw SourceUnavailable.notSignedIn(.grok)
            }
            throw SourceUnavailable.failed(.grok)
        }
        guard let response = try? JSONDecoder().decode(BillingResponse.self, from: data) else {
            throw SourceUnavailable.failed(.grok)
        }
        guard let config = response.config else {
            throw SourceUnavailable.noData
        }
        let periodEnd = config.billingPeriodEnd.flatMap(Self.parseTimestamp)
            ?? config.currentPeriod?.end.flatMap(Self.parseTimestamp)
        guard let periodEnd else {
            throw SourceUnavailable.noData
        }

        let window = QuotaWindow(
            label: Self.label(for: config.currentPeriod?.type),
            usedPercent: config.creditUsagePercent ?? 0,
            resetsAt: periodEnd
        )
        return ProviderQuota(
            provider: .grok,
            windows: [window],
            planType: Self.nonEmpty(response.subscriptionTier ?? response.subscription_tier),
            capturedAt: now
        )
    }

    /// Classify by the period type the provider reports, never by assumption.
    /// An unknown type keeps the word "Usage" so it reads truthfully rather
    /// than pretending to be a window it is not.
    private static func label(for raw: String?) -> String {
        switch raw?.uppercased() {
        case "USAGE_PERIOD_TYPE_WEEKLY": return "Weekly"
        case "USAGE_PERIOD_TYPE_MONTHLY": return "Monthly"
        default: return "Usage"
        }
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// NOTE (2026-08-16): Grok is rolling out a "redeem usage limit reset"
    /// feature on the account/web side. The CLI's billing endpoint does not
    /// expose it yet — no redeemable-reset field in the `/v1/billing` payload
    /// and no redeem endpoint. When the CLI ships it, surface the reset here
    /// the way Codex's reset credits are surfaced (see `QuotaSection` /
    /// `QuotaResetConsumer`).
    ///
    /// Re-verified 2026-08-23 against the live endpoint (both with and
    /// without `format=credits`): the payload carries `creditUsagePercent`,
    /// period windows, `productUsage`, `prepaidBalance`, and `onDemandCap` —
    /// still no reset field, still no redeem endpoint.
    ///
    /// The billing service emits fractional-second ISO8601 timestamps with a
    /// UTC offset (e.g. `2026-08-18T04:06:19.522482+00:00`), which the default
    /// whole-second formatter rejects. Parse fractional first, then fall back.
    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: raw)
    }

    // MARK: Token discovery

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Reads the grok OIDC token from `auth.json`, the file `grok login`
    /// writes. The file is an object keyed by provider scope; the grok.com
    /// OAuth entry is keyed by the auth.x.ai issuer.
    private static func discoverToken() -> String? {
        discoverToken(from: HomeDirectory.real
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("auth.json"))
    }

    /// The test seam: discovery logic, parameterised by the auth file URL.
    static func discoverToken(from authURL: URL) -> String? {
        guard let data = try? Data(contentsOf: authURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for (scope, rawEntry) in object {
            guard scope.hasPrefix("https://auth.x.ai") || scope.contains("auth.x.ai"),
                  let entry = rawEntry as? [String: Any] else { continue }
            return normalized(entry["key"] as? String)
        }
        return nil
    }

    public static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }

    // MARK: Decodable

    private struct BillingResponse: Decodable {
        let config: BillingConfig?
        let subscription_tier: String?
        let subscriptionTier: String?
    }

    private struct BillingConfig: Decodable {
        let creditUsagePercent: Double?
        let currentPeriod: UsagePeriod?
        let billingPeriodEnd: String?
    }

    private struct UsagePeriod: Decodable {
        let type: String?
        let end: String?
    }

    private struct ErrorResponse: Decodable {
        let error: ErrorBody
    }

    private struct ErrorBody: Decodable {
        let type: String
    }

    private struct StringErrorResponse: Decodable {
        let error: String
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
