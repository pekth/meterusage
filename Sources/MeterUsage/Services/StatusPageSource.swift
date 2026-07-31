import Foundation

// MARK: - Anthropic service health
//
// Reads the public, unauthenticated Statuspage v2 JSON feed. No credentials are
// sent and nothing identifying leaves the machine beyond the User-Agent.
//
// WHY JSON AND NOT THE PAGE: an earlier implementation regex-scraped the status
// page's HTML. Statuspage ships markup changes continuously, so the scraper
// silently started matching nothing and reported "operational" forever — the
// worst possible failure mode for a health indicator. The documented
// `components.json` contract is stable, and anything we cannot parse degrades to
// `.unknown` (visibly not-a-claim) rather than to a false all-clear.

/// Fetches Anthropic component health from the public Statuspage API.
public struct StatusPageSource: StatusSource {

    public let provider: Provider

    private let endpoint: URL
    private let session: URLSession

    /// Components whose names contain any of these fragments are considered
    /// relevant. Statuspage exposes a long list (docs, console, individual
    /// models); a menu-bar dot should reflect the API surface a developer is
    /// actually blocked by, not the marketing site.
    private let interestingComponents = ["api", "claude", "code", "console"]

    public init(
        provider: Provider = .claude,
        endpoint: URL = URL(string: "https://status.claude.com/api/v2/components.json")!,
        session: URLSession = StatusPageSource.defaultSession()
    ) {
        self.provider = provider
        self.endpoint = endpoint
        self.session = session
    }

    /// Short timeouts: a hung status check must never delay a refresh cycle, and
    /// stale-but-fast is better than accurate-but-blocking for an ambient dot.
    public static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpAdditionalHeaders = ["User-Agent": "meterusage/\(AppInfo.version)"]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    public func fetchStatus() async throws -> ServiceStatus {
        var request = URLRequest(url: endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("meterusage/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let data: Data
        do {
            let (body, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return Self.unknown(provider: provider, reason: "Status unavailable")
            }
            data = body
        } catch {
            // Distinguish "no network" from "the endpoint misbehaved": the first
            // is the user's situation, the second is ours, and only the first is
            // worth telling them about.
            if (error as? URLError)?.isOffline == true {
                throw SourceUnavailable.offline
            }
            return Self.unknown(provider: provider, reason: "Status unavailable")
        }

        guard let payload = try? JSONDecoder().decode(ComponentsPayload.self, from: data) else {
            return Self.unknown(provider: provider, reason: "Status unavailable")
        }

        return summarise(payload.components)
    }

    // MARK: Mapping

    private func summarise(_ components: [Component]) -> ServiceStatus {
        let relevant = components.filter { component in
            guard component.group != true else { return false }  // groups duplicate their children
            let name = component.name.lowercased()
            return interestingComponents.contains { name.contains($0) }
        }

        // Fall back to every component rather than reporting `.unknown`: an
        // unrecognised naming scheme still gives a usable overall picture.
        let pool = relevant.isEmpty ? components.filter { $0.group != true } : relevant
        guard !pool.isEmpty else {
            return Self.unknown(provider: provider, reason: "Status unavailable")
        }

        let severities = pool.map { Self.severity(for: $0.status) }
        // `Severity` sorts `.unknown` highest, which would let one unparsed
        // component mask a real outage. Rank by real-world badness instead.
        let worst = severities.max(by: { Self.rank($0) < Self.rank($1) }) ?? .unknown

        let description: String
        if worst == .operational {
            description = "All systems operational"
        } else if let culprit = zip(pool, severities).first(where: { Self.rank($0.1) == Self.rank(worst) })?.0 {
            description = "\(culprit.name): \(worst.displayName.lowercased())"
        } else {
            description = worst.displayName
        }

        return ServiceStatus(
            provider: provider,
            severity: worst,
            description: description,
            checkedAt: Date()
        )
    }

    /// Statuspage's documented component status vocabulary.
    static func severity(for raw: String) -> Severity {
        switch raw.lowercased() {
        case "operational":          return .operational
        case "degraded_performance": return .degraded
        case "partial_outage":       return .partialOutage
        case "major_outage":         return .majorOutage
        case "under_maintenance":    return .degraded
        default:                     return .unknown
        }
    }

    /// Badness ordering, distinct from `Severity`'s raw value so `.unknown`
    /// never outranks a genuine outage.
    private static func rank(_ severity: Severity) -> Int {
        switch severity {
        case .operational:   return 0
        case .unknown:       return 1
        case .degraded:      return 2
        case .partialOutage: return 3
        case .majorOutage:   return 4
        }
    }

    private static func unknown(provider: Provider, reason: String) -> ServiceStatus {
        ServiceStatus(provider: provider, severity: .unknown, description: reason, checkedAt: Date())
    }

    // MARK: Wire format
    //
    // Only the three fields we use are decoded. Statuspage adds fields freely;
    // decoding the whole document would turn an additive change into a failure.

    private struct ComponentsPayload: Decodable {
        let components: [Component]
    }

    private struct Component: Decodable {
        let name: String
        let status: String
        let group: Bool?
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

// MARK: - Build metadata

public enum AppInfo {
    /// Read from the bundle so the User-Agent and the About row can never drift
    /// from the shipped version. Falls back for `swift run` (no Info.plist).
    public static let version: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }()

    public static let name = "MeterUsage"
}
